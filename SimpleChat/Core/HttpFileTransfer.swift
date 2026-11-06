import Foundation

/// 文件上传/下载（纯 HTTP，与服务器 /api/upload 与 /api/file/{id} 对接）。
/// multipart 字段严格为：token / to / file（顺序与安卓、Windows 一致）。
enum HttpFileTransfer {

    struct UploadResult {
        let fileId: String
        let name: String
        let size: Int
        let mime: String
    }

    enum TransferError: LocalizedError {
        case notReady
        case tooLarge
        case badResponse
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "当前未连接服务器"
            case .tooLarge:
                return "文件超过 50MB 上限"
            case .badResponse:
                return "服务器响应无法解析"
            case .server(let code, let msg):
                return "服务器错误 \(code)：\(msg)"
            }
        }
    }

    static let maxFileSize: Int64 = 50 * 1024 * 1024

    // MARK: - 上传

    /// 同步上传（调用方放后台线程）。
    /// POST /api/upload，multipart 字段依次为 token、to、file。
    static func upload(url: URL, fileUrl: URL, token: String, to user: String) throws -> UploadResult {
        let size = (try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= maxFileSize else { throw TransferError.tooLarge }

        let fileName = fileUrl.lastPathComponent
        let mime = mimeForExtension(fileName)
        let boundary = "Boundary." + UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")

        // ---- 组装 multipart body（分段拼接，避免一次性大字符串）----
        let crlf = "\r\n"
        var body = Data()

        func appendPartHeader(name: String, filename: String?) {
            body.append(Data(("--" + boundary + crlf).utf8))
            var head = "Content-Disposition: form-data; name=\"" + name + "\""
            if let filename {
                head += "; filename=\"" + filename + "\""
            }
            head += crlf
            body.append(Data(head.utf8))
        }

        // 字段 1：token
        appendPartHeader(name: "token", filename: nil)
        body.append(Data((crlf).utf8))
        body.append(Data(token.utf8))
        body.append(Data(crlf.utf8))

        // 字段 2：to
        appendPartHeader(name: "to", filename: nil)
        body.append(Data((crlf).utf8))
        body.append(Data(user.utf8))
        body.append(Data(crlf.utf8))

        // 字段 3：file（本体）
        appendPartHeader(name: "file", filename: fileName)
        body.append(Data("Content-Type: " + mime + crlf + crlf.utf8))
        body.append(try Data(contentsOf: fileUrl))
        body.append(Data(crlf.utf8))

        // 收尾
        body.append(Data(("--" + boundary + "--" + crlf).utf8))
        request.httpBody = body

        // ---- 同步等待响应 ----
        var outResult: UploadResult?
        var outError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, resp, err in
            defer { semaphore.signal() }
            if let err {
                outError = err
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let data else {
                outError = TransferError.server(code, String(data: data ?? Data(), encoding: .utf8) ?? "")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fileId = obj["file_id"] as? String else {
                outError = TransferError.badResponse
                return
            }
            outResult = UploadResult(
                fileId: fileId,
                name: (obj["name"] as? String) ?? fileName,
                size: (obj["size"] as? Int) ?? size,
                mime: (obj["mime"] as? String) ?? mime)
        }.resume()

        semaphore.wait()
        if let outError { throw outError }
        guard let result = outResult else { throw TransferError.badResponse }
        return result
    }

    // MARK: - 下载

    /// 同步下载文件字节（图片预览用；调用方放后台线程）
    static func downloadData(url: URL) throws -> Data {
        var outData: Data?
        var outError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: url) { data, resp, err in
            defer { semaphore.signal() }
            if let err {
                outError = err
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let data else {
                outError = TransferError.server(code, "")
                return
            }
            outData = data
        }.resume()

        semaphore.wait()
        if let outError { throw outError }
        guard let d = outData else { throw TransferError.badResponse }
        return d
    }

    /// 同步下载到目标文件（附件用）
    static func downloadToFile(url: URL, destination: URL) throws {
        let data = try downloadData(url: url)
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - MIME 推断

    /// 简易 mime 推断（服务器最终以自己的判定为准）
    static func mimeForExtension(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "bmp":         return "image/bmp"
        case "pdf":         return "application/pdf"
        case "txt":         return "text/plain"
        case "zip":         return "application/zip"
        case "mp4":         return "video/mp4"
        case "mp3":         return "audio/mpeg"
        default:            return "application/octet-stream"
        }
    }
}
