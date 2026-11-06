import Foundation
import Combine

/// 业务数据层：订阅 ChatConnection 帧事件，维护会话消息、历史、未读、已读回执。
/// 与服务器 v1.3 一致：内存态存储（不落盘），退出 App 即消失。
@MainActor
final class ChatModel: ObservableObject {

    /// peer → 消息列表（按 id 升序）
    @Published var conversations: [String: [Message]] = [:]
    /// 图片内存缓存（fileId → 已解码图片）
    @Published var imageCache: [String: PlatformImage] = [:]
    /// 正在输入提示
    @Published var typingPeers: Set<String> = []
    /// 未读角标
    @Published var unreadCounts: [String: Int] = [:]
    /// 对方已读我方消息的水位（peer → last_read_id）
    @Published var readMarks: [String: Int] = [:]

    private var conn: ChatConnection?
    private var nextLocalId = -1                 // 本地临时 id（负数，不与服务器 id 冲突）
    private var typingTimers: [String: Timer] = [:]
    private var historyRequested: Set<String> = []
    private var currentChatPeer: String?

    /// cid → 待确认消息
    private var pendingAcks: [Int: Message] = [:]

    func bind(conn: ChatConnection) {
        self.conn = conn
        conn.onEvent = { [weak self] obj in
            Task { @MainActor in self?.handle(obj) }
        }
    }

    // MARK: - 帧分发

    private func handle(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }

        switch type {
        case "message":
            if let msg = Message(json: obj) {
                insert(msg)
                if !msg.isMine {
                    markRead(peer: msg.sender)
                }
            }

        case "history_resp":
            let peer = obj["peer"] as? String ?? ""
            guard !peer.isEmpty, let arr = obj["messages"] as? [[String: Any]] else { return }
            let msgs = arr.compactMap { Message(json: $0) }
            conversations[peer] = msgs
            historyRequested.insert(peer)
            if let last = msgs.last {
                markRead(peer: peer, lastReadId: last.id)
            }

        case "send_ack":
            let cid = obj["cid"]  as? Int ?? 0
            let realId = obj["id"] as? Int ?? 0
            let ts = obj["ts"] as? TimeInterval
                ?? (obj["ts"] as? Int).map { TimeInterval($0) }
                ?? Date().timeIntervalSince1970
            applyAck(cid: cid, realId: realId, ts: ts)

        case "typing":
            if let from = obj["from"] as? String {
                setTyping(peer: from, on: obj["state"] as? Bool ?? false)
            }

        case "read_ack":
            // peer = 已读了我消息的人
            if let peer = obj["peer"] as? String {
                readMarks[peer] = obj["last_read_id"] as? Int ?? 0
            }

        case "clear_ack", "cleared":
            let peer = obj["peer"] as? String ?? ""
            conversations[peer] = []
            unreadCounts[peer] = 0
            typingTimers[peer]?.invalidate()
            typingTimers.removeValue(forKey: peer)

        case "login_ok":
            resetAfterRelogin(obj)

        default:
            break
        }
    }

    // MARK: - 消息插入 / 更新

    private func insert(_ msg: Message) {
        let peer = msg.peer
        var list = conversations[peer] ?? []
        guard !list.contains(where: { $0.id == msg.id }) else { return }
        list.append(msg)
        list.sort { $0.id < $1.id }
        conversations[peer] = list

        if !msg.isMine && currentChatPeer != peer {
            unreadCounts[peer, default: 0] += 1
        }
    }

    /// 本地先上屏（负数临时 id），等 send_ack 回填真实 id
    func appendLocal(peer: String, content: String, file: Message.FileMeta? = nil, type: Message.MsgType) {
        nextLocalId -= 1
        let cid = nextLocalId
        let me = Session.shared.username
        var m = Message(id: cid, sender: me, receiver: peer, content: content,
                        ts: Date().timeIntervalSince1970)
        m.msgType = type
        m.file = file

        var list = conversations[peer] ?? []
        list.append(m)
        conversations[peer] = list
        pendingAcks[cid] = m

        if let file {
            conn?.send(["type": "send", "to": peer, "content": content, "cid": cid,
                        "file": ["id": file.id, "name": file.name,
                                 "size": file.size, "mime": file.mime]])
        } else {
            conn?.sendMessage(to: peer, content: content, cid: cid)
        }
    }

    /// 发送失败时撤下本地消息（上传失败/连接不可用）
    func removeLocal(cid: Int, peer: String) {
        var list = conversations[peer] ?? []
        list.removeAll { $0.id == cid }
        conversations[peer] = list
        pendingAcks.removeValue(forKey: cid)
    }

    /// send_ack 回填：负数 cid → 服务器真实 id
    private func applyAck(cid: Int, realId: Int, ts: TimeInterval) {
        guard realId > 0 else { return }
        for (peer, list) in conversations {
            if let idx = list.firstIndex(where: { $0.id == cid }) {
                var m = list[idx]
                m.id = realId
                m.ts = ts
                conversations[peer]?[idx] = m
            }
            break   // 一次 ack 只对应一条消息
        }
    }

    // MARK: - 已读

    /// 进入/离开聊天页时调用
    func setCurrentPeer(_ peer: String?) {
        currentChatPeer = peer
        if let peer {
            unreadCounts[peer] = 0
        }
    }

    func markRead(peer: String, lastReadId: Int? = nil) {
        let lastId = lastReadId ?? (conversations[peer]?.last?.id ?? 0)
        guard lastId > 0 else { return }
        conn?.markRead(peer: peer, lastReadId: lastId)
        if currentChatPeer == peer {
            unreadCounts[peer] = 0
        }
    }

    // MARK: - 正在输入

    private func setTyping(peer: String, on: Bool) {
        if on {
            typingPeers.insert(peer)
            typingTimers[peer]?.invalidate()
            let t = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.typingPeers.remove(peer)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            typingTimers[peer] = t
        } else {
            typingPeers.remove(peer)
            typingTimers[peer]?.invalidate()
            typingTimers.removeValue(forKey: peer)
        }
    }

    // MARK: - 历史 / 图片 / 附件

    func loadHistory(peer: String) {
        guard !historyRequested.contains(peer) else { return }
        historyRequested.insert(peer)
        conn?.requestHistory(peer: peer)
    }

    /// 下载图片到内存缓存（后台线程，回调主线程）
    func loadImage(fileId: String, done: @escaping (PlatformImage?) -> Void) {
        if let img = imageCache[fileId] {
            done(img)
            return
        }
        guard let conn, let url = URL(string: conn.fileURL(fileId: fileId)) else {
            done(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? HttpFileTransfer.downloadData(url: url)
            let img = data.flatMap { PlatformImage(data: $0) }
            DispatchQueue.main.async {
                if let img {
                    self?.imageCache[fileId] = img
                }
                done(img)
            }
        }
    }

    /// 下载附件到临时目录（后台线程，回调主线程）
    func downloadAttachment(fileId: String, name: String, done: @escaping (URL?) -> Void) {
        guard let conn, let url = URL(string: conn.fileURL(fileId: fileId)) else {
            done(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let safeName = name.replacingOccurrences(of: "/", with: "_")
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
            do {
                try HttpFileTransfer.downloadToFile(url: url, destination: dest)
                DispatchQueue.main.async { done(dest) }
            } catch {
                DispatchQueue.main.async { done(nil) }
            }
        }
    }

    // MARK: - 清空历史（v1.3 清空按钮）

    /// 确认弹窗通过后调用：本地先清，再发 clear 指令，等 clear_ack/cleared 同步
    func clearHistory(peer: String) {
        conversations[peer] = []
        unreadCounts[peer] = 0
        conn?.clearHistory(peer: peer)
    }

    private func resetAfterRelogin(obj: [String: Any]) {
        typingPeers.removeAll()
        pendingAcks.removeAll()
        historyRequested.removeAll()
        if let u = obj["unread"] as? [String: Int] {
            for (k, v) in u {
                unreadCounts[k] = (currentChatPeer == k) ? 0 : v
            }
        }
    }
}
