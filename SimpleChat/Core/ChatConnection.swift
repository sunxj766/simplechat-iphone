import Foundation
import CryptoKit

/// 企信通 iOS 客户端连接层。
///
/// 协议与 server.py 严格一致：
/// - WebSocket 端点 ws://host:port/ws，JSON 文本帧
/// - 服务器带 --secret 时，所有帧为 base64(12B nonce ‖ GCM密文 ‖ 16B tag)
/// - 密钥错误时服务器发一帧【明文】 handshake_fail 后断开（客户端不自动重连）
/// - 上传下载见 HttpFileTransfer.swift
final class ChatConnection: NSObject, ObservableObject {

    // MARK: - 默认配置
    // 通信密钥内置（与服务器一致）；服务器地址/端口不预填，由登录页填写并记忆

    static let defaultSecret = "JNng77qg!"

    // MARK: - 协议常量

    private let connectTimeout: TimeInterval = 10
    private let pingInterval: TimeInterval = 20
    private let reconnectMaxDelay: TimeInterval = 60

    // MARK: - 发布给 UI 的状态

    /// 当前界面阶段
    enum Stage: Equatable {
        case login, connecting, contacts
    }

    @Published var stage: Stage = .login
    @Published var loginError: String?
    @Published var banner: String?                       // 顶部提示条（断线重连中）
    @Published var onlineUsers: Set<String> = []
    @Published var unread: [String: Int] = [:]
    @Published var isReachable = false                   // ws 已连且已登录

    // MARK: - 连接内部状态

    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var key: SymmetricKey?
    private var secret: String = ""

    private(set) var username = ""
    private(set) var password = ""
    private(set) var host = ""
    private(set) var port = 0
    private(set) var fileToken = ""

    private var pendingOut: [[String: Any]] = []        // 断线期间排队的指令
    private var reconnectDelay: TimeInterval = 1.0
    private var generation = 0                          // 防止旧连接回调污染新连接
    private var wantConnection = false
    private var pingTimer: Timer?
    private var userRequestedClose = false

    /// 全部业务帧（message/history_resp/clear_ack/...）回调，由 ChatModel 订阅
    var onEvent: (([String: Any]) -> Void)?

    // MARK: - 生命周期

    override init() {
        super.init()
        let d = UserDefaults.standard
        username = d.string(forKey: "username") ?? ""
        host = d.string(forKey: "host") ?? ""
        let p = d.integer(forKey: "port")
        port = p
        secret = d.string(forKey: "secret") ?? ChatConnection.defaultSecret
    }

    /// 登录页更新服务器地址/端口（持久化，下次启动自动填充）
    func updateServer(host newHost: String, port newPort: Int) {
        host = newHost
        port = newPort
        let d = UserDefaults.standard
        d.set(newHost, forKey: "host")
        d.set(newPort, forKey: "port")
    }

    /// 登录入口（由登录页调用）
    func login(username: String, password: String) {
        self.username = username.trimmingCharacters(in: .whitespaces)
        self.password = password
        userRequestedClose = false
        stage = .connecting
        loginError = nil

        // 只记住用户名（不落盘密码与聊天记录）
        UserDefaults.standard.set(self.username, forKey: "username")

        openSocket()
    }

    /// 主动退出
    func logout() {
        sendImmediatelyBestEffort(["type": "logout"])
        closeAndReset()
        DispatchQueue.main.async { self.stage = .login }
    }

    /// 被踢 / 密钥错误 / 登出后的收尾
    private func closeAndReset() {
        wantConnection = false
        userRequestedClose = true
        pingTimer?.invalidate()
        pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        key = nil
        fileToken = ""
        pendingOut.removeAll()
        isReachable = false
    }

    // MARK: - WebSocket 建立

    private func openSocket() {
        generation += 1
        let gen = generation
        wantConnection = true
        reconnectDelay = 1.0

        let urlString = "ws://\(host):\(port)/ws"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.stage = .login
                self.loginError = "服务器地址无效"
            }
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = connectTimeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        urlSession = session
        let task = session.webSocketTask(with: url)
        socket = task

        // 登录帧先备好：onOpen 即发
        lastLoginFrame = ["type": "login", "username": username, "password": password]
        task.resume()
        receiveLoop(task: task, gen: gen)
        if let frame = lastLoginFrame {
            sendRaw(frame, on: task)
        }
    }

    private var lastLoginFrame: [String: Any]?

    /// 断开后指数退避重连（1s 起步，翻倍至 60s）
    private func scheduleReconnect() {
        guard wantConnection, !userRequestedClose else { return }
        let gen = generation
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, reconnectMaxDelay)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.wantConnection, !self.userRequestedClose, self.generation == gen else { return }
            self.openSocket()
        }
    }

    // MARK: - 收帧循环

    private func receiveLoop(task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            guard let self, self.generation == gen else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let text):
                    self.handleFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleFrame(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop(task: task, gen: gen)

            case .failure:
                self.handleDisconnect(gen: gen)
            }
        }
    }

    /// 处理一帧（有密钥则解密；解密失败探测明文 handshake_fail）
    private func handleFrame(_ text: String) {
        DispatchQueue.main.async { self.processFrame(text) }
    }

    /// （主线程）解析并处理一帧
    private func processFrame(_ text: String) {
        var obj: [String: Any]?

        if let key {
            if let plain = try? CryptoBox.decrypt(text, key: key) {
                obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
            }
        } else {
            obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }

        if obj == nil,
           let plainObj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           (plainObj["type"] as? String) == "handshake_fail" {
            // 密钥错误：服务器已断开，禁止自动重连
            userRequestedClose = true
            wantConnection = false
            closeAndReset()
            stage = .login
            loginError = "通信密钥与服务器不一致"
            return
        }

        guard let payload = obj else { return }
        route(payload)
    }

    /// 解密成功后的统一分发
    private func route(_ obj: [String: Any]) {
        switch obj["type"] as? String ?? "" {

        case "login_ok":
            key = CryptoBox.deriveKey(from: secret)
            fileToken = obj["file_token"] as? String ?? ""
            let users = Set(obj["online_users"] as? [String] ?? [])
            reconnectDelay = 1.0
            isReachable = true
            flushPending()
            startPing()
            onlineUsers = users
            stage = .contacts
            loginError = nil
            banner = nil
            notify(obj)

        case "login_fail":
            closeAndReset()
            stage = .login
            loginError = (obj["reason"] as? String) ?? "用户名或密码错误"

        case "kicked":
            closeAndReset()
            stage = .login
            loginError = "账号在其他设备登录，本机已下线"

        case "handshake_fail":
            closeAndReset()
            stage = .login
            loginError = "通信密钥与服务器不一致"

        case "presence":
            let name = obj["username"] as? String ?? ""
            let online = obj["online"] as? Bool ?? false
            if online { onlineUsers.insert(name) }
            else { onlineUsers.remove(name) }
            notify(obj)

        case "pong":
            break

        default:
            notify(obj)
        }
    }

    private func notify(_ obj: [String: Any]) {
        onEvent?(obj)
    }

    private func handleDisconnect(gen: Int) {
        guard generation == gen else { return }
        DispatchQueue.main.async { self.finalizeDisconnect() }
    }

    private func finalizeDisconnect() {
        isReachable = false
        pingTimer?.invalidate()
        pingTimer = nil
        socket = nil
        guard wantConnection, !userRequestedClose else { return }
        if stage == .contacts { banner = "连接已断开，正在重连…" }
        scheduleReconnect()
    }

    // MARK: - 发送

    private func startPing() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.send(["type": "ping"])
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    /// 登录成功后冲刷断线期间排队的指令
    private func flushPending() {
        guard !pendingOut.isEmpty else { return }
        let frames = pendingOut
        pendingOut.removeAll()
        for f in frames { sendImmediately(f) }
    }

    /// 业务指令统一出口：在线直发，断线时排队
    func send(_ payload: [String: Any]) {
        if isReachable {
            sendImmediately(payload)
        } else if wantConnection {
            pendingOut.append(payload)
        }
    }

    private func sendImmediately(_ payload: [String: Any]) {
        guard let task = socket, isReachable else { return }
        sendRaw(payload, on: task)
    }

    /// 尽力发一帧（logout 用，不排队）
    private func sendImmediatelyBestEffort(_ payload: [String: Any]) {
        guard let task = socket else { return }
        sendRaw(payload, on: task)
    }

    private func sendRaw(_ payload: [String: Any], on task: URLSessionWebSocketTask) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }

        if let key, let enc = try? CryptoBox.encrypt(text, key: key) {
            task.send(.string(enc)) { error in
                if let error { NSLog("[SimpleChat] ws send error: \(error.localizedDescription)") }
            }
        } else if key == nil {
            task.send(.string(text)) { error in
                if let error { NSLog("[SimpleChat] ws send error: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - 业务指令

    /// 文件下载地址（带 file_token 鉴权）
    func fileURL(fileId: String) -> String {
        "\(httpBase)/api/file/\(fileId)?token=\(fileToken)"
    }

    func requestHistory(peer: String, beforeId: Int = 0, limit: Int = 200) {
        send(["type": "history", "peer": peer, "before_id": beforeId, "limit": limit])
    }

    func markRead(peer: String, lastReadId: Int) {
        send(["type": "read", "peer": peer, "last_read_id": lastReadId])
    }

    func sendTyping(to peer: String, state: Bool) {
        send(["type": "typing", "to": peer, "state": state])
    }

    func clearHistory(peer: String) {
        send(["type": "clear", "peer": peer])
    }

    /// 发文本消息
    func sendMessage(to peer: String, content: String, cid: Int) {
        send(["type": "send", "to": peer, "content": content, "cid": cid])
    }

    var httpBase: String { "http://\(host):\(port)" }

    enum SendError: LocalizedError {
        case notReady, tooLarge
        var errorDescription: String? {
            switch self {
            case .notReady: return "当前未连接服务器"
            case .tooLarge: return "文件超过 50MB 上限"
            }
        }
    }
}
