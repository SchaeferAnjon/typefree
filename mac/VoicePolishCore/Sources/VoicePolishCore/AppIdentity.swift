import Foundation

/// 正式版与开发版（mac/scripts/dev_run.sh 编出来的 Typefree Dev）的身份区分。
///
/// 开发版 bundle id 为 `com.voicepolish.app.dev`，与正式版完全隔离：
/// - 配置目录 `~/.config/voicepolish-dev/`（正式版 `~/.config/voicepolish/`）
/// - 不碰钥匙串：密钥存在开发版配置目录下的 `dev_secrets.json`（0600），也可用环境变量覆盖
/// - 共享 UserDefaults suite、调试日志文件名都加 `-dev` / `.dev`
/// 判断只看运行时 bundle id，正式版代码路径不变。
public enum AppIdentity {
    public static let releaseBundleID = "com.voicepolish.app"
    public static let devBundleID = "com.voicepolish.app.dev"

    /// 当前进程是不是开发版。单元测试（xctest）里为 false，行为与正式版一致。
    public static let isDevBuild: Bool = Bundle.main.bundleIdentifier == devBundleID

    /// 与扩展 / 其他模块共享的 UserDefaults suite 名。开发版加 `.dev` 后缀，不读写正式版的处理模式、试用计数。
    public static var sharedDefaultsSuiteName: String {
        isDevBuild ? "group.com.voicepolish.shared.dev" : "group.com.voicepolish.shared"
    }

    #if os(macOS)
    /// macOS 配置目录：正式版 ~/.config/voicepolish，开发版 ~/.config/voicepolish-dev
    public static var macConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(isDevBuild ? ".config/voicepolish-dev" : ".config/voicepolish", isDirectory: true)
    }

    /// 调试日志：正式版 ~/Library/Logs/VoicePolish.log，开发版 VoicePolish-dev.log
    public static var debugLogFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(isDevBuild ? "Library/Logs/VoicePolish-dev.log" : "Library/Logs/VoicePolish.log")
    }

    #endif

    /// 默认密钥存储：正式版用系统钥匙串；开发版用配置目录下的文件，避免 ad hoc 签名每次重编都弹钥匙串授权框。
    public static func defaultSecretStore() -> SecretStoring {
        #if os(macOS)
        if isDevBuild {
            return FileSecretStore(fileURL: macConfigDirectory.appendingPathComponent("dev_secrets.json"))
        }
        #endif
        return KeychainSecretStore.shared
    }
}

/// 开发版专用：把密钥存成本地 JSON 文件（权限 0600）。正式版不使用。
public final class FileSecretStore: SecretStoring {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[account]
    }

    @discardableResult
    public func set(_ account: String, _ value: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        if let value, !value.isEmpty { all[account] = value } else { all.removeValue(forKey: account) }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }
}
