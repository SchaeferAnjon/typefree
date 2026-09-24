import Foundation

// 快捷键的数据类型、配置读写、撞键检测和显示名。不依赖 AppKit：修饰键用 HotkeyModifierFlags 表示，
// 位定义和 NSEvent.ModifierFlags / CGEventFlags 完全一致，App 层用 rawValue 互转。
// 配置键名（recording_hotkey_* / ask_hotkey_* / ask_plain_hotkey_*）是跨版本契约，不能改。
// 每个读写都有带 `in config:` 的版本，默认 VoicePolishConfig.shared，测试时传临时目录的实例。

/// 修饰键标志。rawValue 与 NSEvent.ModifierFlags.rawValue 逐位相同（CGEventFlags 低 32 位也相同），
/// 自定义快捷键存进 config 的就是这个 rawValue。
public struct HotkeyModifierFlags: OptionSet, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let capsLock = HotkeyModifierFlags(rawValue: 1 << 16)
    public static let shift = HotkeyModifierFlags(rawValue: 1 << 17)
    public static let control = HotkeyModifierFlags(rawValue: 1 << 18)
    public static let option = HotkeyModifierFlags(rawValue: 1 << 19)
    public static let command = HotkeyModifierFlags(rawValue: 1 << 20)
    public static let numericPad = HotkeyModifierFlags(rawValue: 1 << 21)
    public static let help = HotkeyModifierFlags(rawValue: 1 << 22)
    public static let function = HotkeyModifierFlags(rawValue: 1 << 23)
    public static let deviceIndependentFlagsMask = HotkeyModifierFlags(rawValue: 0xffff_0000)
}

public enum RecordingHotkeyBehavior {
    public static let tapToggleConfigKey = "recording_hotkey_tap_toggle_enabled"
    public static let defaultTapToggleEnabled = true
    // 区分「单击（按一下开始/再按一下停）」与「长按说话（松手即停）」的门槛。
    // 原 0.30 太靠前：用户的「单击」手感常落在 0.3 秒上下，偶尔越线被误判成长按、松手秒停，
    // 表现为「胶囊一闪而过」。放宽到 0.50，让 0.3~0.4 秒的单击稳定算单击，长按需按住超过半秒。
    public static let holdThreshold: TimeInterval = 0.50

    public static var isTapToggleEnabled: Bool { isTapToggleEnabled(in: .shared) }

    public static func isTapToggleEnabled(in config: VoicePolishConfig) -> Bool {
        config.bool(forKey: tapToggleConfigKey, defaultValue: defaultTapToggleEnabled)
    }
}

public enum RecordingHotkeyModifier: String, CaseIterable {
    case option
    case command
    case control
    case shift
    case fn
    case rightCommand
    case rightOption

    public static let configKey = "recording_hotkey_modifier"

    public static var current: RecordingHotkeyModifier { current(in: .shared) }

    public static func current(in config: VoicePolishConfig) -> RecordingHotkeyModifier {
        let raw = config.string(forKey: configKey) ?? RecordingHotkeyModifier.option.rawValue
        return RecordingHotkeyModifier(rawValue: raw) ?? .option
    }

    public var displayName: String {
        switch self {
        case .option: return "Option"
        case .command: return "Command"
        case .control: return "Control"
        case .shift: return "Shift"
        case .fn: return "Fn"
        case .rightCommand: return "右 Command"
        case .rightOption: return "右 Option"
        }
    }

    public var symbol: String {
        switch self {
        case .option, .rightOption: return "⌥"
        case .command, .rightCommand: return "⌘"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .fn: return "fn"
        }
    }

    public var menuTitle: String {
        displayName
    }

    public var symbolName: String {
        switch self {
        case .option, .rightOption: return "option"
        case .command, .rightCommand: return "command"
        case .control: return "control"
        case .shift: return "shift"
        case .fn: return "function"
        }
    }

    /// 通用修饰键位（不分左右）。App 层的 eventFlag / cgFlag 由它的 rawValue 转出来
    public var flag: HotkeyModifierFlags {
        switch self {
        case .option, .rightOption: return .option
        case .command, .rightCommand: return .command
        case .control: return .control
        case .shift: return .shift
        case .fn: return .function
        }
    }

    /// 修饰键标志里区分左右的设备位（IOKit 的 NX_DEVICE*KEYMASK）。通用位只说「有一颗 Option 按着」，
    /// 这两位才说得清是哪一颗；松开其中一颗、另一颗还按着时也不会认错。
    public static let leftOptionDeviceBit: UInt = 0x20
    public static let rightOptionDeviceBit: UInt = 0x40
    public static let leftCommandDeviceBit: UInt = 0x08
    public static let rightCommandDeviceBit: UInt = 0x10

    /// 这颗通用键对应的「右边那颗」；没有左右之分的返回 nil
    public var rightVariant: RecordingHotkeyModifier? {
        switch self {
        case .option: return .rightOption
        case .command: return .rightCommand
        default: return nil
        }
    }

    /// 给定一份修饰键标志（NSEvent.modifierFlags 或 CGEventSource.flagsState 的 rawValue），这颗键算不算按着。
    /// optionLeftOnly：右 Option / 右 Command 让给了另一套热键时，通用的 Option / Command 只认左边那颗
    public func matches(rawFlags: UInt64, optionLeftOnly: Bool = false) -> Bool {
        guard rawFlags & UInt64(flag.rawValue) == UInt64(flag.rawValue) else { return false }
        switch self {
        case .rightCommand:
            return rawFlags & UInt64(Self.rightCommandDeviceBit) != 0
        case .rightOption:
            return rawFlags & UInt64(Self.rightOptionDeviceBit) != 0
        case .option where optionLeftOnly:
            return rawFlags & UInt64(Self.leftOptionDeviceBit) != 0
        case .command where optionLeftOnly:
            return rawFlags & UInt64(Self.leftCommandDeviceBit) != 0
        default:
            return true
        }
    }

    /// 录「单个修饰键」：按下的修饰键里只能恰好有一颗。keyCode 61 = 右 Option，54 = 右 Command
    public static func capture(flags rawFlags: HotkeyModifierFlags, keyCode: UInt16) -> RecordingHotkeyModifier? {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let allowed: [(HotkeyModifierFlags, RecordingHotkeyModifier)] = [
            (.option, keyCode == 61 ? .rightOption : .option),
            (.command, keyCode == 54 ? .rightCommand : .command),
            (.control, .control),
            (.shift, .shift),
            (.function, .fn),
        ]
        let matches = allowed.filter { flags.contains($0.0) }
        guard matches.count == 1 else { return nil }

        let allowedMask: HotkeyModifierFlags = [.option, .command, .control, .shift, .function]
        guard flags.subtracting(allowedMask).isEmpty else { return nil }
        return matches[0].1
    }
}

public struct RecordingHotkeyCustomShortcut: Equatable {
    public static let keyCodeConfigKey = "recording_hotkey_custom_key_code"
    public static let modifiersConfigKey = "recording_hotkey_custom_modifiers"
    public static let keyDisplayConfigKey = "recording_hotkey_custom_key_display"

    public let keyCode: UInt16
    public let modifiers: HotkeyModifierFlags
    public let keyDisplay: String

    public init(keyCode: UInt16, modifiers: HotkeyModifierFlags, keyDisplay: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyDisplay = keyDisplay
    }

    public var displayName: String {
        Self.symbols(for: modifiers) + keyDisplay
    }

    public var conflictWarning: String? {
        let normalized = Self.normalized(modifiers)
        if keyCode == 49 && normalized == .command {
            return "⌘ Space 通常会被系统输入法或 Spotlight 占用，建议换一个组合。"
        }
        if keyCode == 48 && normalized.contains(.command) {
            return "⌘ Tab 通常会被系统用于切换 App，建议换一个组合。"
        }
        if keyDisplay.count == 1 && normalized == .command {
            return "单独使用 ⌘ 加字母，可能和常用 App 菜单快捷键冲突。"
        }
        return nil
    }

    public func matchesKeyDown(keyCode: UInt16, flags: HotkeyModifierFlags) -> Bool {
        keyCode == self.keyCode && Self.normalized(flags) == Self.normalized(modifiers)
    }

    public func matchesKeyUp(keyCode: UInt16) -> Bool {
        keyCode == self.keyCode
    }

    public static var saved: RecordingHotkeyCustomShortcut? { saved(prefix: "recording_hotkey") }

    /// prefix：哪一套热键（recording_hotkey = 听写，ask_hotkey = 看屏幕问 AI）
    public static func saved(prefix: String, in config: VoicePolishConfig = .shared) -> RecordingHotkeyCustomShortcut? {
        guard let keyCodeRaw = config.string(forKey: "\(prefix)_custom_key_code"),
              let keyCode = UInt16(keyCodeRaw),
              let modifiersRaw = config.string(forKey: "\(prefix)_custom_modifiers"),
              let modifiersValue = UInt(modifiersRaw) else { return nil }
        let display = config.string(forKey: "\(prefix)_custom_key_display") ?? "Key \(keyCode)"
        return RecordingHotkeyCustomShortcut(
            keyCode: keyCode,
            modifiers: HotkeyModifierFlags(rawValue: modifiersValue),
            keyDisplay: display
        )
    }

    public static func save(_ shortcut: RecordingHotkeyCustomShortcut, prefix: String = "recording_hotkey",
                            in config: VoicePolishConfig = .shared) {
        config.save(value: String(shortcut.keyCode), forKey: "\(prefix)_custom_key_code")
        config.save(value: String(shortcut.modifiers.rawValue), forKey: "\(prefix)_custom_modifiers")
        config.save(value: shortcut.keyDisplay, forKey: "\(prefix)_custom_key_display")
    }

    public static func normalized(_ flags: HotkeyModifierFlags) -> HotkeyModifierFlags {
        flags.intersection([.option, .command, .control, .shift, .function])
    }

    public static func symbols(for flags: HotkeyModifierFlags) -> String {
        var result = ""
        let normalized = normalized(flags)
        if normalized.contains(.control) { result += "⌃" }
        if normalized.contains(.option) { result += "⌥" }
        if normalized.contains(.shift) { result += "⇧" }
        if normalized.contains(.command) { result += "⌘" }
        if normalized.contains(.function) { result += "fn" }
        return result
    }

    /// characters：事件的 charactersIgnoringModifiers
    public static func keyDisplayName(keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 76: return "Enter"
        case 117: return "Forward Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            let raw = characters?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "Key \(keyCode)" : raw.uppercased()
        }
    }
}

public enum RecordingHotkeyShortcut: Equatable {
    case modifier(RecordingHotkeyModifier)
    case custom(RecordingHotkeyCustomShortcut)

    public static let modeConfigKey = "recording_hotkey_mode"

    /// 听写快捷键设成了「不设置」：不用键盘听写（比如平时用别的输入法），这一套不响应
    public static var isDisabled: Bool { isDisabled(in: .shared) }

    public static func isDisabled(in config: VoicePolishConfig) -> Bool {
        config.string(forKey: modeConfigKey) == "none"
    }

    public static func disable(in config: VoicePolishConfig = .shared) {
        config.save(value: "none", forKey: modeConfigKey)
    }

    public static var current: RecordingHotkeyShortcut { current(in: .shared) }

    public static func current(in config: VoicePolishConfig) -> RecordingHotkeyShortcut {
        if config.string(forKey: modeConfigKey) == "custom",
           let custom = RecordingHotkeyCustomShortcut.saved(prefix: "recording_hotkey", in: config) {
            return .custom(custom)
        }
        return .modifier(RecordingHotkeyModifier.current(in: config))
    }

    public var displayName: String {
        switch self {
        case .modifier(let modifier): return "\(modifier.symbol) \(modifier.displayName)"
        case .custom(let shortcut): return shortcut.displayName
        }
    }

    public var debugName: String {
        switch self {
        case .modifier(let modifier): return modifier.rawValue
        case .custom(let shortcut): return "custom(\(shortcut.displayName))"
        }
    }

    /// 两套热键按下去会不会一起响：完全相同，或者一边是自定义组合、另一边正好是这个组合里唯一的修饰键
    /// （比如 ⌥Space 和 Option：按 ⌥ 时后者先开录，再按 Space 前者也匹配上）。
    /// 通用 Option 和右 Option 不算：那种情况由 HotkeyArbiter.leftOnly 让通用键只认左边那颗。
    public func overlaps(_ other: RecordingHotkeyShortcut) -> Bool {
        switch (self, other) {
        case (.modifier(let a), .modifier(let b)):
            return a == b
        case (.custom(let a), .custom(let b)):
            return a.keyCode == b.keyCode
                && RecordingHotkeyCustomShortcut.normalized(a.modifiers) == RecordingHotkeyCustomShortcut.normalized(b.modifiers)
        case (.custom(let c), .modifier(let m)), (.modifier(let m), .custom(let c)):
            return RecordingHotkeyCustomShortcut.normalized(c.modifiers) == m.flag
        }
    }

    public static func useModifier(_ modifier: RecordingHotkeyModifier, in config: VoicePolishConfig = .shared) {
        config.save(value: "modifier", forKey: modeConfigKey)
        config.save(value: modifier.rawValue, forKey: RecordingHotkeyModifier.configKey)
    }

    public static func useCustom(_ shortcut: RecordingHotkeyCustomShortcut, in config: VoicePolishConfig = .shared) {
        RecordingHotkeyCustomShortcut.save(shortcut, in: config)
        config.save(value: "custom", forKey: modeConfigKey)
    }
}

/// 问 AI 的快捷键。两套：看屏幕问（默认右 Option，按下那一刻鼠标指在哪，截图上的标记就在哪）、
/// 纯提问（不截屏，默认不设，用户自己录）。都只旁听键盘、不拦任何事件，
/// 不像「修饰键 + 点击」那样要站在全系统鼠标点击的必经之路上。
public struct AskHotkey {
    public let prefix: String
    public let defaultModifier: RecordingHotkeyModifier?
    public let title: String

    public init(prefix: String, defaultModifier: RecordingHotkeyModifier?, title: String) {
        self.prefix = prefix
        self.defaultModifier = defaultModifier
        self.title = title
    }

    public static let screen = AskHotkey(prefix: "ask_hotkey", defaultModifier: .rightOption, title: "看屏幕问 AI")
    public static let plain = AskHotkey(prefix: "ask_plain_hotkey", defaultModifier: nil, title: "只提问，不看屏幕")

    private var modeKey: String { "\(prefix)_mode" }
    private var modifierKey: String { "\(prefix)_modifier" }

    /// nil = 还没设
    public var current: RecordingHotkeyShortcut? { current(in: .shared) }

    public func current(in config: VoicePolishConfig) -> RecordingHotkeyShortcut? {
        switch config.string(forKey: modeKey) {
        case "custom":
            return RecordingHotkeyCustomShortcut.saved(prefix: prefix, in: config).map { .custom($0) }
        case "none":
            return nil
        default:
            let saved = config.string(forKey: modifierKey).flatMap { RecordingHotkeyModifier(rawValue: $0) }
            return (saved ?? defaultModifier).map { .modifier($0) }
        }
    }

    public var displayName: String { displayName(in: .shared) }

    public func displayName(in config: VoicePolishConfig) -> String {
        HotkeyArbiter.displayName(for: prefix, shortcut: current(in: config), in: config)
    }

    public func useModifier(_ modifier: RecordingHotkeyModifier, in config: VoicePolishConfig = .shared) {
        config.save(value: "modifier", forKey: modeKey)
        config.save(value: modifier.rawValue, forKey: modifierKey)
    }

    public func useCustom(_ shortcut: RecordingHotkeyCustomShortcut, in config: VoicePolishConfig = .shared) {
        RecordingHotkeyCustomShortcut.save(shortcut, prefix: prefix, in: config)
        config.save(value: "custom", forKey: modeKey)
    }

    public func clear(in config: VoicePolishConfig = .shared) {
        config.save(value: "none", forKey: modeKey)
    }

    /// 和优先级更高的热键撞了（听写 > 看屏幕问 > 纯提问）：没法分辨用户想干什么，这一套不响应。
    /// 除了完全相同，自定义组合和单修饰键重叠（⌥Space 和 Option）也算撞，见 overlaps。
    public var conflict: String? { conflict(in: .shared) }

    public func conflict(in config: VoicePolishConfig) -> String? {
        guard let mine = current(in: config) else { return nil }
        if !RecordingHotkeyShortcut.isDisabled(in: config),
           let reason = Self.clash(mine, RecordingHotkeyShortcut.current(in: config)) {
            return "和「开始说话」的快捷键\(reason)"
        }
        if prefix == AskHotkey.plain.prefix, let screen = AskHotkey.screen.current(in: config),
           let reason = Self.clash(mine, screen) {
            return "和「看屏幕问 AI」的快捷键\(reason)"
        }
        return nil
    }

    private static func clash(_ a: RecordingHotkeyShortcut, _ b: RecordingHotkeyShortcut) -> String? {
        guard a.overlaps(b) else { return nil }
        return a.debugName == b.debugName ? "相同" : "重叠"
    }

    public var isActive: Bool { isActive(in: .shared) }

    public func isActive(in config: VoicePolishConfig) -> Bool {
        current(in: config) != nil && conflict(in: config) == nil
    }

    /// 这一套是否占用了某颗「右边的」修饰键
    public func uses(_ modifier: RecordingHotkeyModifier, in config: VoicePolishConfig = .shared) -> Bool {
        guard isActive(in: config), case .modifier(let mine)? = current(in: config) else { return false }
        return mine == modifier
    }
}

/// 三套热键（听写、看屏幕问、纯提问）之间的让位规则。
public enum HotkeyArbiter {
    /// 除 name 这一套之外，其他正在生效的热键
    public static func others(than name: String, in config: VoicePolishConfig = .shared) -> [RecordingHotkeyShortcut] {
        var all: [(String, RecordingHotkeyShortcut?)] = RecordingHotkeyShortcut.isDisabled(in: config)
            ? [] : [("recording", RecordingHotkeyShortcut.current(in: config))]
        for hotkey in [AskHotkey.screen, AskHotkey.plain] where hotkey.isActive(in: config) {
            all.append((hotkey.prefix, hotkey.current(in: config)))
        }
        return all.filter { $0.0 != name }.compactMap { $0.1 }
    }

    /// name 这一套用的是通用的 Option / Command，而「右边那颗」被别的热键单独占了：
    /// 这时通用键只认左边那颗，两套不会同时响。哪一套占右边都一样，规则是对称的。
    public static func leftOnly(for name: String, shortcut: RecordingHotkeyShortcut?,
                                in config: VoicePolishConfig = .shared) -> Bool {
        guard case .modifier(let mine)? = shortcut, let right = mine.rightVariant else { return false }
        return others(than: name, in: config).contains { if case .modifier(let m) = $0 { return m == right } else { return false } }
    }

    /// 显示用：只认左边时照实写「左 Option」
    public static func displayName(for name: String, shortcut: RecordingHotkeyShortcut?,
                                   in config: VoicePolishConfig = .shared) -> String {
        guard let shortcut else { return "未设置" }
        if case .modifier(let m) = shortcut, leftOnly(for: name, shortcut: shortcut, in: config) {
            return "\(m.symbol) 左 \(m.displayName)"
        }
        return shortcut.displayName
    }
}
