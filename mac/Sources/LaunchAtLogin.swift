import AppKit
import ServiceManagement
import VoicePolishCore

/// 开机自启动（登录项）。macOS 13+ 用 `SMAppService`，注册 / 注销各一行，无需单独的辅助 App。
///
/// 策略（与 Ray 商定）：**默认开** —— 新安装、以及老用户首次升到带此功能的版本，都自动登记一次；
/// 但**只在「从未自动登记过」时做这一次**，之后绝不自作主张改动，完全交给用户：
/// - 用户在设置开关里关掉 → 尊重，不再自动打开；
/// - 用户在「系统设置 → 登录项」里手动增删 → 也不去较劲（开关以系统真实状态为准）。
enum LaunchAtLogin {
    /// 标记：是否已执行过「首次默认登记」。缺失 = 还没做过。
    static let defaultAppliedKey = "launch_at_login_default_applied"

    /// 当前是否已是登录项。以系统状态为准，这样设置开关能如实反映用户在系统设置里的手动改动。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 开 / 关登录项（设置页开关回调）。成功返回 true；失败（极少见，如系统拒绝）返回 false。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            return true
        } catch {
            return false
        }
    }

    /// 启动时调用：从未自动登记过 → 默认开机自启（登记一次）并打标记；已打过标记则什么都不做。
    static func applyDefaultIfFirstLaunch() {
        let config = VoicePolishConfig.shared
        guard !config.bool(forKey: defaultAppliedKey, defaultValue: false) else { return }
        setEnabled(true)
        config.save(bool: true, forKey: defaultAppliedKey)
    }
}

// MARK: - Dock 图标

/// 「在 Dock 中显示」（默认开）。关掉 = 切成 accessory：Dock 和 ⌘Tab 里都不再出现，和纯菜单栏 App 一样；
/// 菜单栏图标照常在（「打开 Typefree」从那里进），在访达 / 启动台再次打开 App 也会弹出主窗口。
enum DockIcon {
    static let configKey = "show_dock_icon"

    static var isShown: Bool {
        VoicePolishConfig.shared.bool(forKey: configKey, defaultValue: true)
    }

    /// 设置页开关回调：存下选择并立即生效。
    static func setShown(_ shown: Bool) {
        VoicePolishConfig.shared.save(bool: shown, forKey: configKey)
        apply()
    }

    /// 按当前选择设置激活策略；启动时（applicationWillFinishLaunching，Dock 图标出现前）调一次。
    static func apply() {
        let policy: NSApplication.ActivationPolicy = isShown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}
