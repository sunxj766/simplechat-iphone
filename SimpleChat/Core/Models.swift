import Foundation

// MARK: - 消息模型（对应服务器 message / history_resp / undelivered 中的消息对象）

struct Message: Identifiable, Equatable {
    let id: Int
    let sender: String
    let receiver: String
    var content: String
    let ts: TimeInterval
    var msgType: MsgType = .text
    var file: FileMeta?

    enum MsgType: String {
        case text, image, file
    }

    struct FileMeta: Equatable {
        let id: String
        let name: String
        let size: Int
        let mime: String

        var isImage: Bool { mime.hasPrefix("image/") }
    }

    var isMine: Bool { sender == Session.shared.username }

    /// 会话对方（本人发的是 to，收到的是 from）
    var peer: String { isMine ? receiver : sender }

    /// 服务器时间 → 本地时间
    var date: Date { Date(timeIntervalSince1970: ts) }
}

extension Message {
    /// 从服务器 JSON（message / history_resp / undelivered 通用）构造。
    /// 服务器字段：id/from/to/content/ts/msg_type/file{id,name,size,mime}
    /// （另有扁平 file_* 与 content_enc 字段，客户端忽略）
    init?(json: [String: Any]) {
        guard
            let id = json["id"] as? Int,
            let sender = json["from"] as? String,
            let receiver = json["to"] as? String,
            let content = json["content"] as? String,
            let ts = (json["ts"] as? TimeInterval) ?? (json["ts"] as? Int).map({ TimeInterval($0) })
        else { return nil }

        var type = MsgType.text
        if let t = json["msg_type"] as? String, let mt = MsgType(rawValue: t) {
            type = mt
        }

        var meta: FileMeta?
        if let f = json["file"] as? [String: Any],
           let fid = f["id"] as? String, !fid.isEmpty {
            meta = FileMeta(
                id: fid,
                name: (f["name"] as? String) ?? "文件",
                size: (f["size"] as? Int) ?? 0,
                mime: (f["mime"] as? String) ?? "application/octet-stream")
        } else if let fid = json["file_id"] as? String, !fid.isEmpty {
            // 兼容：仅扁平字段的情况
            meta = FileMeta(
                id: fid,
                name: (json["file_name"] as? String) ?? "文件",
                size: (json["file_size"] as? Int) ?? 0,
                mime: (json["file_mime"] as? String) ?? "application/octet-stream")
        }

        self.init(id: id, sender: sender, receiver: receiver, content: content, ts: ts)
        msgType = type
        file = meta
    }
}

// MARK: - 联系人

struct Contact: Identifiable {
    let username: String
    let nickname: String
    var online: Bool
    var unread: Int

    var id: String { username }
    var displayName: String { nickname.isEmpty ? username : nickname }
}

// MARK: - 全局会话身份

final class Session {
    static let shared = Session()
    var username: String = ""
}
