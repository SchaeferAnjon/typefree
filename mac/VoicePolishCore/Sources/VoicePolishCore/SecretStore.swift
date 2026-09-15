import Foundation
import Security

/// 读取结果：区分「确实没有」和「读不到」（钥匙串被锁 / 用户拒绝授权 / access group 出错）。
/// 调用方据此决定能否安全地生成新密钥——读不到时生成新密钥会把旧数据变成永久乱码。
public enum SecretLookup {
    case found(String)
    case notFound
    case error(String)
}

/// 敏感凭证存储后端。set 返回是否成功（fail-closed 的基础）。
/// 协议化以便测试注入内存实现，并把 Keychain 细节隔离在一处。
public protocol SecretStoring {
    func get(_ account: String) -> String?
    func lookup(_ account: String) -> SecretLookup
    /// value 为 nil/空串时删除。返回写入/删除是否成功。
    @discardableResult func set(_ account: String, _ value: String?) -> Bool
}

public extension SecretStoring {
    /// 默认实现分不清「没有」和「出错」，一律按「没有」处理；能区分的后端（钥匙串）应覆写。
    func lookup(_ account: String) -> SecretLookup {
        get(account).map { .found($0) } ?? .notFound
    }
}

/// 系统钥匙串实现（macOS / iOS 通用）。
public final class KeychainSecretStore: SecretStoring {
    public static let shared = KeychainSecretStore()

    private let service: String
    private let accessGroup: String?

    /// - accessGroup: iOS 跨主 App 与键盘扩展共享时传入解析后的组名（如 `<TeamID>.com.voicepolish.shared`）；
    ///   macOS 必须传 nil。
    public init(service: String = "com.voicepolish.secret", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    public func get(_ account: String) -> String? {
        if case .found(let value) = lookup(account) { return value }
        return nil
    }

    public func lookup(_ account: String) -> SecretLookup {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .error("keychain item data unreadable")
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return .error(message)
        }
    }

    @discardableResult
    public func set(_ account: String, _ value: String?) -> Bool {
        guard let value = value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(baseQuery(account) as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false   // 其它错误：写入失败，调用方据此 fail-closed
    }
}

/// 仅供测试 / 预览：进程内存，不落盘、不碰钥匙串。
public final class InMemorySecretStore: SecretStoring {
    private var store: [String: String] = [:]
    public init() {}
    public func get(_ account: String) -> String? { store[account] }
    @discardableResult public func set(_ account: String, _ value: String?) -> Bool {
        if let v = value, !v.isEmpty { store[account] = v } else { store[account] = nil }
        return true
    }
}
