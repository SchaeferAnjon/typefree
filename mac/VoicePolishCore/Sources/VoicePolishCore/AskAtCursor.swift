import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 指针问 AI 的触发修饰键，区分左右。和听写热键（RecordingHotkeyModifier）各管各的：
/// 那个管键盘听写，这个只管「修饰键 + 鼠标左键」这一个手势。
///
/// 左右靠 CGEventFlags 里的设备相关位判断（IOLLEvent.h 的 NX_DEVICE*KEYMASK）：
/// 通用位（maskControl 等）只说「有个 Control 按着」，设备位才说是哪一边。
public enum AskCursorModifier: String, CaseIterable, Sendable {
    case leftControl
    case rightControl
    case leftOption
    case rightOption
    case leftShift
    case rightShift
    case leftCommand
    case rightCommand

    /// 这个键属于哪一族（左右 Control 是同一族）。严格匹配时用它排除「别的族也按着」。
    public enum Family: CaseIterable, Sendable {
        case control, option, shift, command
    }

    public var family: Family {
        switch self {
        case .leftControl, .rightControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftShift, .rightShift: return .shift
        case .leftCommand, .rightCommand: return .command
        }
    }

    public var isLeft: Bool {
        switch self {
        case .leftControl, .leftOption, .leftShift, .leftCommand: return true
        default: return false
        }
    }

    public var displayName: String {
        let side = isLeft ? "左" : "右"
        switch family {
        case .control: return side + " Control"
        case .option: return side + " Option"
        case .shift: return side + " Shift"
        case .command: return side + " Command"
        }
    }

    public var symbol: String {
        switch family {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    #if canImport(CoreGraphics)
    /// 通用位：只表示「这一族有键按着」
    public var familyFlag: CGEventFlags {
        switch family {
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .shift: return .maskShift
        case .command: return .maskCommand
        }
    }

    /// 设备相关位（IOLLEvent.h）。CGEventFlags 没给这些常量，按 rawValue 写。
    public var deviceFlag: CGEventFlags {
        switch self {
        case .leftControl: return CGEventFlags(rawValue: 0x0000_0001)   // NX_DEVICELCTLKEYMASK
        case .rightControl: return CGEventFlags(rawValue: 0x0000_2000)  // NX_DEVICERCTLKEYMASK
        case .leftShift: return CGEventFlags(rawValue: 0x0000_0002)     // NX_DEVICELSHIFTKEYMASK
        case .rightShift: return CGEventFlags(rawValue: 0x0000_0004)    // NX_DEVICERSHIFTKEYMASK
        case .leftCommand: return CGEventFlags(rawValue: 0x0000_0008)   // NX_DEVICELCMDKEYMASK
        case .rightCommand: return CGEventFlags(rawValue: 0x0000_0010)  // NX_DEVICERCMDKEYMASK
        case .leftOption: return CGEventFlags(rawValue: 0x0000_0020)    // NX_DEVICELALTKEYMASK
        case .rightOption: return CGEventFlags(rawValue: 0x0000_0040)   // NX_DEVICERALTKEYMASK
        }
    }

    /// 这个键此刻按着吗。设备位在少数输入设备上不填，所以设备位没出现时退回只看通用位：
    /// 宁可左右不分，也不能变成按了没反应。
    public func isDown(in flags: CGEventFlags, siblingDeviceFlag: CGEventFlags) -> Bool {
        guard flags.contains(familyFlag) else { return false }
        if flags.contains(deviceFlag) { return true }
        // 通用位在、两个设备位都不在 = 这台设备不报左右，认它
        return !flags.contains(siblingDeviceFlag)
    }

    /// 同族的另一边（判断「设备位有没有被填」用）
    public var sibling: AskCursorModifier {
        switch self {
        case .leftControl: return .rightControl
        case .rightControl: return .leftControl
        case .leftOption: return .rightOption
        case .rightOption: return .leftOption
        case .leftShift: return .rightShift
        case .rightShift: return .leftShift
        case .leftCommand: return .rightCommand
        case .rightCommand: return .leftCommand
        }
    }
    #endif

    /// 显示顺序按键盘上的排列来（⌃⌥⇧⌘），和系统快捷键的写法一致
    public static let displayOrder: [AskCursorModifier] = [
        .leftControl, .rightControl, .leftOption, .rightOption,
        .leftShift, .rightShift, .leftCommand, .rightCommand,
    ]
}

/// 一组修饰键（可以是一个，也可以是组合）。配置里存成 "option" 或 "control+option"，顺序无关。
public struct AskCursorModifierCombo: Equatable, Sendable {
    public let modifiers: Set<AskCursorModifier>

    /// 默认左 Control：右手在触控板上，左手小指就在它上面，不用挪手。
    public static let fallback = AskCursorModifierCombo(unchecked: [.leftControl])

    private init(unchecked modifiers: Set<AskCursorModifier>) {
        self.modifiers = modifiers
    }

    public init?(_ modifiers: Set<AskCursorModifier>) {
        guard !modifiers.isEmpty else { return nil }
        self.modifiers = modifiers
    }

    /// 解析配置值；空的、认不出的、只剩噪音的一律退回默认（左 Control）。
    /// 也认不带左右的老写法（"option"），当成左边那个。
    public static func parse(_ raw: String?) -> AskCursorModifierCombo {
        guard let raw else { return fallback }
        let parts = raw.split(whereSeparator: { $0 == "+" || $0 == "," || $0 == " " })
        let parsed = parts.compactMap { part -> AskCursorModifier? in
            let token = String(part)
            if let exact = AskCursorModifier(rawValue: token) { return exact }
            switch token.lowercased() {
            case "control": return .leftControl
            case "option": return .leftOption
            case "shift": return .leftShift
            case "command": return .leftCommand
            default: return nil
            }
        }
        return AskCursorModifierCombo(Set(parsed)) ?? fallback
    }

    /// 写回配置用的稳定字符串（按显示顺序排，同一组合永远是同一个值）
    public var configValue: String {
        AskCursorModifier.displayOrder.filter { modifiers.contains($0) }.map(\.rawValue).joined(separator: "+")
    }

    public var displayName: String {
        let ordered = AskCursorModifier.displayOrder.filter { modifiers.contains($0) }
        return ordered.map(\.symbol).joined() + " " + ordered.map(\.displayName).joined(separator: "+")
    }

    #if canImport(CoreGraphics)
    /// 严格匹配：配置里的键（含左右）全部按着，配置以外的族一个都不能按着。
    /// 严格是有意的：这样 ⌘ 点击（打开新标签页）、⇧ 点击（连选）不会被配成左 Control 的触发器抢走。
    public func matches(_ flags: CGEventFlags) -> Bool {
        for modifier in modifiers
        where !modifier.isDown(in: flags, siblingDeviceFlag: modifier.sibling.deviceFlag) {
            return false
        }
        let usedFamilies = Set(modifiers.map(\.family))
        for family in AskCursorModifier.Family.allCases where !usedFamilies.contains(family) {
            if flags.contains(Self.familyFlag(family)) { return false }
        }
        return true
    }

    private static func familyFlag(_ family: AskCursorModifier.Family) -> CGEventFlags {
        switch family {
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .shift: return .maskShift
        case .command: return .maskCommand
        }
    }
    #endif
}

/// 倾听模式：按住说话，还是点一下开始、再点一下结束
public enum AskCursorListenMode: String, CaseIterable, Sendable {
    /// 按住左键期间一直录音，松开即结束提问
    case hold
    /// 修饰键 + 点击开始录音，松手后继续录；之后任意一次鼠标点击结束并提问
    case clickToggle

    public var displayName: String {
        switch self {
        case .hold: return "按住说话"
        case .clickToggle: return "点一下开始，再点一下结束"
        }
    }
}

/// 指针问 AI 的配置项。读写都走 VoicePolishConfig，和其他功能一致。
public enum AskAtCursorSettings {
    public static let enabledKey = "ask_at_cursor_enabled"
    public static let defaultEnabled = false
    public static let modifierKey = "ask_at_cursor_modifier"
    public static let listenModeKey = "ask_at_cursor_listen_mode"
    public static let defaultListenMode = AskCursorListenMode.clickToggle
    /// 提问时带屏幕截图（含原来的空白处长按问 AI）
    public static let screenshotEnabledKey = "ask_screenshot_enabled"
    public static let screenshotDefaultEnabled = true
    /// 手填视觉模型名，覆盖内置默认值
    public static let visionModelKey = "ask_vision_model"
    /// 点击切换模式的安全上限：录到这么久还没结束就自动结束并提问
    public static let maxListenSeconds: TimeInterval = 60

    public static var isEnabled: Bool {
        VoicePolishConfig.shared.bool(forKey: enabledKey, defaultValue: defaultEnabled)
    }

    public static var isScreenshotEnabled: Bool {
        VoicePolishConfig.shared.bool(forKey: screenshotEnabledKey, defaultValue: screenshotDefaultEnabled)
    }

    public static var combo: AskCursorModifierCombo {
        AskCursorModifierCombo.parse(VoicePolishConfig.shared.string(forKey: modifierKey))
    }

    public static var listenMode: AskCursorListenMode {
        guard let raw = VoicePolishConfig.shared.string(forKey: listenModeKey),
              let mode = AskCursorListenMode(rawValue: raw) else { return defaultListenMode }
        return mode
    }

    public static var visionModelOverride: String? {
        let raw = VoicePolishConfig.shared.string(forKey: visionModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }
}

#if canImport(CoreGraphics)
/// 指针问 AI 的事件状态机。只做「看到这个事件该吞掉吗、该做什么」的判断，
/// 不碰 AppKit、不碰录音，因此可以直接单测。事件拦截回调里必须快，所以这里全是纯计算。
public struct AskCursorMachine {
    public enum Input: Equatable {
        /// 左键按下（flags 是这份事件自带的修饰键状态）
        case mouseDown(modifiers: CGEventFlags)
        /// 任意其他鼠标键按下（点击切换模式下也算「结束这一次」）
        case otherButtonDown
        case mouseUp
        case mouseDragged
        case escape
        /// 安全上限到点
        case timeout
    }

    public enum Action: Equatable {
        case none
        /// 开始一次指针问 AI
        case begin
        /// 结束录音并提问
        case finish
        /// 丢掉这次录音，不提问
        case cancel
    }

    public struct Output: Equatable {
        /// true = 这个事件不要传给底下的 App
        public let swallow: Bool
        public let action: Action

        public init(swallow: Bool, action: Action) {
            self.swallow = swallow
            self.action = action
        }

        static let pass = Output(swallow: false, action: .none)
    }

    public enum State: Equatable {
        case idle
        /// 按住模式：录音中，等松手
        case holding
        /// 点击切换模式：录音已开始，触发的那一下还没松开
        case toggleArmed
        /// 点击切换模式：已松手，录音继续，等下一次点击结束
        case listening
        /// 这一下按键剩下的拖动和松开都要吞掉，吞完回 idle
        case swallowUntilUp
    }

    public private(set) var state: State = .idle
    public let combo: AskCursorModifierCombo
    public let mode: AskCursorListenMode

    public init(combo: AskCursorModifierCombo, mode: AskCursorListenMode, state: State = .idle) {
        self.combo = combo
        self.mode = mode
        self.state = state
    }

    /// canStart：此刻能不能开一次新的提问（正在录音 / 正在出结果时为 false）。
    public mutating func handle(_ input: Input, canStart: Bool) -> Output {
        switch state {
        case .idle:
            guard case .mouseDown(let flags) = input, combo.matches(flags), canStart else { return .pass }
            state = (mode == .hold) ? .holding : .toggleArmed
            return Output(swallow: true, action: .begin)

        case .holding:
            switch input {
            case .mouseDragged:
                return Output(swallow: true, action: .none)
            case .mouseUp:
                state = .idle
                return Output(swallow: true, action: .finish)
            case .escape:
                state = .swallowUntilUp
                return Output(swallow: false, action: .cancel)
            case .timeout:
                state = .swallowUntilUp
                return Output(swallow: false, action: .finish)
            case .mouseDown, .otherButtonDown:
                return Output(swallow: true, action: .none)
            }

        case .toggleArmed:
            switch input {
            case .mouseDragged:
                return Output(swallow: true, action: .none)
            case .mouseUp:
                state = .listening
                return Output(swallow: true, action: .none)
            case .escape:
                state = .swallowUntilUp
                return Output(swallow: false, action: .cancel)
            case .timeout:
                state = .swallowUntilUp
                return Output(swallow: false, action: .finish)
            case .mouseDown, .otherButtonDown:
                return Output(swallow: true, action: .none)
            }

        case .listening:
            switch input {
            case .mouseDown, .otherButtonDown:
                // 结束这一下也要吞掉：否则会点开指针底下的链接、按钮
                state = .swallowUntilUp
                return Output(swallow: true, action: .finish)
            case .escape:
                state = .idle
                return Output(swallow: false, action: .cancel)
            case .timeout:
                state = .idle
                return Output(swallow: false, action: .finish)
            case .mouseUp, .mouseDragged:
                return .pass
            }

        case .swallowUntilUp:
            switch input {
            case .mouseDragged:
                return Output(swallow: true, action: .none)
            case .mouseUp:
                state = .idle
                return Output(swallow: true, action: .none)
            case .mouseDown, .otherButtonDown:
                // 又来了一次按下，说明上一下的松开没收到（事件拦截被系统短暂停用过）。
                // 不自愈的话这一下会「按下放行、松开被吞」，底下的 App 以为鼠标一直按着。
                state = .idle
                return handle(input, canStart: canStart)
            case .escape, .timeout:
                return .pass
            }
        }
    }

    /// 录音被别的途径停掉（快捷键、菜单、出错）：回到初始状态，但别让半截按键漏给 App
    public mutating func reset() {
        switch state {
        case .holding, .toggleArmed:
            state = .swallowUntilUp
        case .idle, .listening, .swallowUntilUp:
            state = .idle
        }
    }

    /// 录音是否正在进行（用来决定要不要挂安全上限定时器、要不要收 Esc）
    public var isActive: Bool {
        switch state {
        case .holding, .toggleArmed, .listening: return true
        case .idle, .swallowUntilUp: return false
        }
    }
}
#endif
