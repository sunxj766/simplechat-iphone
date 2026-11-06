import Foundation
import CryptoKit

/// 与服务器互通的 AES-256-GCM 封帧：
/// 帧格式 = base64( 12字节nonce ‖ AESGCM密文 ‖ 16字节tag )
/// 密钥   = SHA-256("SimpleChat-v1-" + 口令)，AAD 为 nil
/// （与 server.py / 安卓 / Windows 客户端逐字节一致）
enum CryptoBox {

    static let kdfPrefix = "SimpleChat-v1-"
    static let nonceLength = 12

    /// 由口令派生 256 位对称密钥
    static func deriveKey(from secret: String) -> SymmetricKey {
        let data = Data((kdfPrefix + secret).utf8)
        let digest = SHA256.hash(data: data)
        return SymmetricKey(data: digest)
    }

    /// 加密 JSON 文本帧：返回 base64 字符串
    static func encrypt(_ text: String, key: SymmetricKey) throws -> String {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(text.utf8), using: key, nonce: nonce)
        var out = Data()
        out.append(contentsOf: nonce.rawRepresentation)     // 12B nonce
        out.append(sealed.ciphertext)                       // 密文
        out.append(sealed.tag)                              // 16B tag
        return out.base64EncodedString()
    }

    /// 解密 base64 帧：前 12 字节为 nonce，其余为密文+tag
    static func decrypt(_ frame: String, key: SymmetricKey) throws -> Data {
        guard let raw = Data(base64Encoded: frame), raw.count > nonceLength else {
            throw CryptoError.badFrame
        }
        let nonce = try AES.GCM.Nonce(data: raw.prefix(nonceLength))
        let sealed = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: raw.dropFirst(nonceLength).dropLast(16),
            tag: raw.suffix(16))
        return try AES.GCM.open(sealed, using: key)
    }

    enum CryptoError: Error {
        case badFrame
    }
}
