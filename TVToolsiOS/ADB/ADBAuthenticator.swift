import Foundation
import Security

// MARK: - ADB RSA 认证
//
// AOSP (system/core/adb/adb_auth_host.cpp) 的握手认证：
//   1. adbd -> AUTH(arg0=1 TOKEN), data = 20 字节随机 token
//   2. host -> AUTH(arg0=2 SIGNATURE), data = RSA_sign(NID_sha1, token, 20, ...)
//      即 "对 token 做 SHA1 摘要 + PKCS#1 v1.5 私钥签名"
//      对应 iOS: SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA1, token)
//   3. 若 adbd 不认识这把钥匙，会再要一次；此时
//      host -> AUTH(arg0=3 RSAPUBLICKEY), data = adbkey.pub 全文 + "\0"
//      电视上会弹「是否允许 USB 调试」，用户点允许后 adbd 回 CNXN。
//
// ⚠️ 关键取舍：adbkey.pub 不是标准 PEM，而是 Android 自定义的
//    RSAPublicKey 结构（bits / n0inv / modulus 小端 / rr / exponent）的 base64，
//    其中 n0inv、rr 需要 Montgomery 大数运算才能算出来。
//    在 iOS 上重新生成这套格式风险高，因此本工程【不自行生成密钥对】，改为：
//      · 路径 A（推荐）：导入电脑上已有的 ~/.android/adbkey + adbkey.pub
//        —— 电视很可能早就授权过这把钥匙，成功率最高；
//      · 路径 B：绝大多数电视/盒子 ro.adb.secure=0，根本不发 AUTH，直接 CNXN 成功。
//    用 tools/prepare_adbkey.py 把 adbkey 转成 App 可导入的 JSON。

final class ADBAuthenticator {

    enum AuthError: LocalizedError {
        case noKey
        case badPEM
        case keyImportFailed(OSStatus)
        case signFailed(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "尚未导入 ADB 密钥（若电视免认证，可忽略此项）"
            case .badPEM: return "密钥数据不是合法的 DER base64"
            case .keyImportFailed(let s): return "iOS 无法导入这把 RSA 私钥（OSStatus \(s)），请用 prepare_adbkey.py 转成 PKCS#1 DER"
            case .signFailed(let m): return "签名失败：\(m)"
            }
        }
    }

    private(set) var privateKey: SecKey?
    private(set) var publicKeyText: String = ""
    private(set) var fingerprint: String = ""

    var hasKey: Bool { privateKey != nil && !publicKeyText.isEmpty }

    /// 导入 tools/prepare_adbkey.py 产出的字段
    /// - pkcs1DERBase64: PKCS#1 "RSA PRIVATE KEY" 的 DER，base64 编码
    /// - pubText: adbkey.pub 的原始内容（base64 + " user@host"）
    func importKey(pkcs1DERBase64: String, pubText: String) throws {
        let cleaned = pkcs1DERBase64
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: cleaned), !der.isEmpty else {
            throw AuthError.badPEM
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            let code = error.map { OSStatus(CFErrorGetCode($0.takeRetainedValue())) } ?? errSecParam
            throw AuthError.keyImportFailed(code)
        }
        privateKey = key
        publicKeyText = pubText.trimmingCharacters(in: .whitespacesAndNewlines)
        fingerprint = Self.computeFingerprint(publicKeyText)
        saveToKeychain(pkcs1DERBase64: cleaned, pubText: publicKeyText)
    }

    /// 对 adbd 发来的 20 字节 token 签名（RSA + SHA1 + PKCS#1 v1.5）
    func sign(token: Data) throws -> Data {
        guard let key = privateKey else { throw AuthError.noKey }
        guard token.count == ADB.tokenSize else {
            throw AuthError.signFailed("token 长度应为 \(ADB.tokenSize)，实际 \(token.count)")
        }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA1,
            token as CFData,
            &error
        ) as Data? else {
            let msg = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw AuthError.signFailed(msg)
        }
        return sig
    }

    /// AUTH RSAPUBLICKEY 的 payload：adbkey.pub 全文 + 结尾 \0（adbd 要求 NUL 结尾字符串）
    func publicKeyPayload() -> Data {
        var data = Data(publicKeyText.utf8)
        data.append(0)
        return data
    }

    // MARK: - 持久化（私钥进 Keychain，不落 plist、不进 iCloud）

    private let service = "cn.tvtools.ios.adbkey"

    func restoreFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let der = json["der"], let pub = json["pub"] else { return }
        try? importKey(pkcs1DERBase64: der, pubText: pub)
    }

    private func saveToKeychain(pkcs1DERBase64: String, pubText: String) {
        guard let payload = try? JSONSerialization.data(withJSONObject: [
            "der": pkcs1DERBase64, "pub": pubText
        ]) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = payload
        SecItemAdd(add as CFDictionary, nil)
    }

    func clear() {
        privateKey = nil
        publicKeyText = ""
        fingerprint = ""
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    /// 简单指纹（仅用于界面展示，不是 AOSP 的 MD5 指纹算法）
    private static func computeFingerprint(_ text: String) -> String {
        let first = text.split(separator: " ").first.map(String.init) ?? text
        guard first.count >= 16 else { return first }
        return String(first.prefix(8)) + "…" + String(first.suffix(8))
    }
}
