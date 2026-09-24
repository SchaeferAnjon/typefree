import Foundation

/// 一套热键的手势状态机：按住说话 / 轻点锁定 / Esc 取消 / 组合键丢弃。
///
/// 纯值类型：App 层（HotkeyManager）把 NSEvent 转成 Input 喂进来，按顺序执行返回的 Action
/// （回调、定时器、日志）。定时器到点时再把 holdPromotionDue / releaseCheckDue 喂回来。
/// 回调类 Action（start / stop / cancel / chordCancel / classified）总是排在同一批的最后，
/// 状态在回调之前就已经改好，回调里同步重入（比如 recordingDidLeaveActiveState）也安全。
public struct HotkeyGestureMachine {
    public enum State: Equatable {
        case idle
        case pressing(startedAt: TimeInterval, sawChord: Bool)
        case holdRecording(startedAt: TimeInterval, sawChord: Bool)
        case latchedRecording

        public var debugName: String {
            switch self {
            case .idle: return "idle"
            case .pressing(_, let sawChord): return "pressing(chord=\(sawChord))"
            case .holdRecording(_, let sawChord): return "holdRecording(chord=\(sawChord))"
            case .latchedRecording: return "latchedRecording"
            }
        }
    }

    public enum Input: Equatable {
        /// 修饰键变化。rawFlags = NSEvent.modifierFlags.rawValue（含左右设备位）
        case flagsChanged(rawFlags: UInt64, keyCode: UInt16, at: TimeInterval)
        case keyDown(keyCode: UInt16, flags: HotkeyModifierFlags, isRepeat: Bool, at: TimeInterval)
        case keyUp(keyCode: UInt16, at: TimeInterval)
        /// 执行 .start 之后，把 onStart 的返回值喂回来
        case startResult(accepted: Bool, at: TimeInterval)
        /// .scheduleHoldPromotion 的定时器到点
        case holdPromotionDue(startedAt: TimeInterval)
        /// .scheduleReleaseCheck 的定时器到点。stillDown = 此刻热键是不是其实还按着
        case releaseCheckDue(stillDown: Bool, at: TimeInterval)
    }

    public enum Action: Equatable {
        /// 调 onStart，把返回值用 .startResult 喂回来
        case start(at: TimeInterval)
        case stop
        /// 长按期间按 Esc
        case cancel
        /// 刚按下热键就按了别的键（⌘C、⇧ 打大写）
        case chordCancel
        /// true = 长按（松手即停），false = 轻点锁定
        case classified(hold: Bool)
        /// 覆盖掉之前那个长按升级定时器
        case scheduleHoldPromotion(startedAt: TimeInterval, delay: TimeInterval)
        case cancelHoldPromotion
        /// 覆盖掉之前那个松手确认定时器
        case scheduleReleaseCheck(delay: TimeInterval)
        case cancelReleaseCheck
        case log(String)
    }

    /// 每次事件时向 App 问的几件事。都是闭包、按需才调，和原来一样不在每次按键时多读配置
    public struct Environment {
        public var isSuspended: () -> Bool
        public var isActive: () -> Bool
        public var optionLeftOnly: () -> Bool
        public var isRecording: () -> Bool

        public init(isSuspended: @escaping () -> Bool,
                    isActive: @escaping () -> Bool,
                    optionLeftOnly: @escaping () -> Bool,
                    isRecording: @escaping () -> Bool) {
            self.isSuspended = isSuspended
            self.isActive = isActive
            self.optionLeftOnly = optionLeftOnly
            self.isRecording = isRecording
        }
    }

    /// 松手后等这么久再确认一次是不是真松了（flag 抖动会误报松手）
    public static let releaseConfirmDelay: TimeInterval = 0.08
    /// 全局 + 本地两个监听器会对同一次按下 / 松手各报一次，同方向 50ms 内的重复丢掉
    public static let dedupeWindow: TimeInterval = 0.05
    public static let escapeKeyCode: UInt16 = 53

    public private(set) var shortcut: RecordingHotkeyShortcut
    public private(set) var tapToggleEnabled: Bool
    public private(set) var state: State = .idle
    public private(set) var wasModifierDown = false
    /// 「真实松手时刻」。松手事件一到就记下，用来：①按真实「按下→松手」时长判定单击/长按，
    /// 避免把 0.08s 确认延迟算进时长；②在 0.08s 确认窗口内压制长按升级，防止临界单击被升级成长按后立刻停
    /// （胶囊一闪而过）。每次新一轮按下清空。
    public private(set) var releaseObservedAt: TimeInterval?

    private var lastEventTime: TimeInterval = 0
    private var lastProcessedModifierDown = false   // 上一次「已处理」事件的方向，用于只去重同方向的重复
    private var lastShortcutEventTime: TimeInterval = 0
    private var lastProcessedShortcutDown = false

    public init(shortcut: RecordingHotkeyShortcut, tapToggleEnabled: Bool) {
        self.shortcut = shortcut
        self.tapToggleEnabled = tapToggleEnabled
    }

    // MARK: - 外部重置

    /// 录音被 App 结束 / 取消了。isPressedNow：此刻热键是不是按着
    public mutating func recordingDidLeaveActiveState(isPressedNow: Bool) -> [Action] {
        wasModifierDown = isPressedNow
        state = .idle
        releaseObservedAt = nil
        return [.cancelReleaseCheck, .cancelHoldPromotion, .log("recording state reset by app")]
    }

    /// 设置里改了快捷键。isPressedNow 要按新的 shortcut 算
    public mutating func reconfigure(shortcut: RecordingHotkeyShortcut, tapToggleEnabled: Bool,
                                     isPressedNow: Bool) -> [Action] {
        self.shortcut = shortcut
        self.tapToggleEnabled = tapToggleEnabled
        wasModifierDown = isPressedNow
        state = .idle
        releaseObservedAt = nil
        return [.cancelReleaseCheck, .cancelHoldPromotion,
                .log("hotkey settings changed: shortcut=\(shortcut.debugName) tapToggle=\(tapToggleEnabled)")]
    }

    // MARK: - 事件

    public mutating func handle(_ input: Input, env: Environment) -> [Action] {
        switch input {
        case let .flagsChanged(rawFlags, keyCode, now):
            return flagsChanged(rawFlags: rawFlags, keyCode: keyCode, at: now, env: env)
        case let .keyDown(keyCode, flags, isRepeat, now):
            guard !env.isSuspended() else { return [] }
            return keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat, at: now, env: env)
        case let .keyUp(keyCode, now):
            guard !env.isSuspended() else { return [] }
            return keyUp(keyCode: keyCode, at: now)
        case let .startResult(accepted, now):
            guard accepted else { return [.log("start ignored by app")] }
            state = .pressing(startedAt: now, sawChord: false)
            return [.scheduleHoldPromotion(startedAt: now, delay: RecordingHotkeyBehavior.holdThreshold)]
        case let .holdPromotionDue(startedAt):
            return holdPromotionDue(startedAt: startedAt)
        case let .releaseCheckDue(stillDown, now):
            return releaseCheckDue(stillDown: stillDown, at: now)
        }
    }

    private mutating func flagsChanged(rawFlags: UInt64, keyCode: UInt16, at now: TimeInterval, env: Environment) -> [Action] {
        guard !env.isSuspended(), env.isActive(), case .modifier(let configuredModifier) = shortcut else { return [] }
        let modifierDown = configuredModifier.matches(rawFlags: rawFlags, optionLeftOnly: env.optionLeftOnly())

        // 去重：全局 + 本地两个监听器会对「同一次」按下/松手各报一次，丢掉 50ms 内的重复。
        // 关键：只丢「同方向」的重复（都按下、或都松手）。绝不能只按时间一刀切，否则
        // 50ms 内的「闪电单击」那次方向相反的松手会被当成重复吞掉，状态卡在按下、录音停不下来。
        if now - lastEventTime < Self.dedupeWindow && modifierDown == lastProcessedModifierDown { return [] }
        lastEventTime = now
        lastProcessedModifierDown = modifierDown

        var actions: [Action] = [.log("flagsChanged: modifier=\(configuredModifier.rawValue) down=\(modifierDown) wasDown=\(wasModifierDown) state=\(state.debugName) tapToggle=\(tapToggleEnabled) rawFlags=\(String(rawFlags, radix: 16)) keyCode=\(keyCode)")]

        if modifierDown && !wasModifierDown {
            actions += press(at: now, env: env)
        } else if !modifierDown && wasModifierDown {
            actions += confirmRelease(at: now)
        }
        return actions
    }

    private mutating func keyDown(keyCode: UInt16, flags: HotkeyModifierFlags, isRepeat: Bool,
                                  at now: TimeInterval, env: Environment) -> [Action] {
        guard env.isActive(), !isRepeat else { return [] }

        // 长按录音期间按 Esc → 取消（只在按住着的时候；单击锁定模式有叉号按钮）
        if keyCode == Self.escapeKeyCode, env.isRecording() {
            switch state {
            case .pressing, .holdRecording:
                state = .idle
                return [.log("Esc during hold → onCancel"), .cancel]
            default:
                break
            }
        }

        if case .custom(let custom) = shortcut {
            guard custom.matchesKeyDown(keyCode: keyCode, flags: flags) else { return [] }
            if now - lastShortcutEventTime < Self.dedupeWindow && lastProcessedShortcutDown { return [] }
            lastShortcutEventTime = now
            lastProcessedShortcutDown = true
            var actions: [Action] = [.log("custom keyDown: shortcut=\(custom.displayName) wasDown=\(wasModifierDown) state=\(state.debugName) tapToggle=\(tapToggleEnabled)")]
            if !wasModifierDown {
                actions += press(at: now, env: env)
            }
            return actions
        }

        guard case .modifier(let configuredModifier) = shortcut,
              flags.contains(configuredModifier.flag) else { return [] }

        switch state {
        case .pressing:
            // 刚按下热键还没到长按门槛就按了别的键：是 ⌘C、⇧ 打大写、⌥ 打特殊字符这类组合键，
            // 不是想录音。立刻丢掉这段录音，不送去识别（不然每次复制粘贴都会转写一段杂音、还可能粘进去）。
            state = .idle
            return [.cancelHoldPromotion,
                    .log("keyDown while pressing: chord keyCode=\(keyCode) → onChordCancel"),
                    .chordCancel]
        case .holdRecording(let startedAt, _):
            state = .holdRecording(startedAt: startedAt, sawChord: true)
            return [.log("keyDown while holding: chord keyCode=\(keyCode)")]
        case .idle, .latchedRecording:
            return []
        }
    }

    private mutating func keyUp(keyCode: UInt16, at now: TimeInterval) -> [Action] {
        guard case .custom(let custom) = shortcut, custom.matchesKeyUp(keyCode: keyCode) else { return [] }
        if now - lastShortcutEventTime < Self.dedupeWindow && !lastProcessedShortcutDown { return [] }
        lastShortcutEventTime = now
        lastProcessedShortcutDown = false
        var actions: [Action] = [.log("custom keyUp: shortcut=\(custom.displayName) wasDown=\(wasModifierDown) state=\(state.debugName)")]
        if wasModifierDown {
            actions += confirmRelease(at: now)
        }
        return actions
    }

    private mutating func press(at now: TimeInterval, env: Environment) -> [Action] {
        var actions: [Action] = [.cancelReleaseCheck, .cancelHoldPromotion]
        wasModifierDown = true
        releaseObservedAt = nil   // 新一轮手势开始：清掉上一轮可能残留的松手时刻

        if case .latchedRecording = state {
            state = .idle
            actions += [.log("→ onStop (tap toggle)"), .stop]
            return actions
        }

        if env.isRecording() {
            state = .idle
            actions += [.log("→ onStop (recording already active)"), .stop]
            return actions
        }

        guard case .idle = state else { return actions }

        actions += [.log("→ onStart"), .start(at: now)]
        return actions
    }

    private mutating func holdPromotionDue(startedAt: TimeInterval) -> [Action] {
        guard wasModifierDown else { return [] }
        // 已观测到松手（正处于 0.08s 确认窗口内）→ 这是一次单击，绝不能升级成长按。
        // 否则临界单击（按住接近阈值）会被这里升级为 holdRecording，随后确认流程立刻 onStop，
        // 表现为「单击进入识别后立刻退出 / 胶囊一闪而过」。
        guard releaseObservedAt == nil else { return [] }
        guard case .pressing(let currentStart, let sawChord) = state, currentStart == startedAt else { return [] }

        state = .holdRecording(startedAt: startedAt, sawChord: sawChord)
        return [.log("promoted to holdRecording"), .classified(hold: true)]
    }

    private mutating func confirmRelease(at now: TimeInterval) -> [Action] {
        // 立即记下真实松手时刻（早于 0.08s 防抖确认）。用于按真实时长判定单击/长按，
        // 并在确认窗口内压制长按升级（见 holdPromotionDue 的 releaseObservedAt 守卫）。
        releaseObservedAt = now
        return [.cancelReleaseCheck, .scheduleReleaseCheck(delay: Self.releaseConfirmDelay)]
    }

    private mutating func releaseCheckDue(stillDown: Bool, at now: TimeInterval) -> [Action] {
        var actions: [Action] = [.log("release check: stillDown=\(stillDown) wasDown=\(wasModifierDown) state=\(state.debugName)")]

        // 误报松手（修饰键其实还按着，多见于 flag 抖动）：撤销这次松手记录，
        // 让长按升级照常进行，真正松手时再重新记一次。
        guard !stillDown else {
            releaseObservedAt = nil
            return actions
        }

        wasModifierDown = false
        // 用真实松手时刻判定，而不是「确认定时器执行时刻」（后者比真实松手晚 0.08s+，
        // 会把单击时长算大、把单击误判成长按）。
        actions += finishRelease(at: releaseObservedAt ?? now)
        return actions
    }

    private mutating func finishRelease(at now: TimeInterval) -> [Action] {
        var actions: [Action] = [.cancelHoldPromotion]

        switch state {
        case .pressing(let startedAt, let sawChord):
            let duration = now - startedAt
            if tapToggleEnabled && !sawChord && duration < RecordingHotkeyBehavior.holdThreshold {
                state = .latchedRecording
                actions += [.log("tap latched recording duration=\(String(format: "%.3f", duration))"),
                            .classified(hold: false)]
            } else {
                state = .idle
                actions += [.log("→ onStop duration=\(String(format: "%.3f", duration)) chord=\(sawChord)"), .stop]
            }
        case .holdRecording(let startedAt, let sawChord):
            state = .idle
            actions += [.log("→ onStop hold duration=\(String(format: "%.3f", now - startedAt)) chord=\(sawChord)"), .stop]
        case .latchedRecording:
            actions.append(.log("release after latched recording"))
        case .idle:
            actions.append(.log("release ignored in idle"))
        }
        return actions
    }
}
