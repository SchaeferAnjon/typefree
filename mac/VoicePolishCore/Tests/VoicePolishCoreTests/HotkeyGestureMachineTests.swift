import XCTest
@testable import VoicePolishCore

/// 模拟 HotkeyManager：执行状态机给出的动作、记下回调、手动触发定时器。
private final class Driver {
    var machine: HotkeyGestureMachine
    var suspended = false
    var active = true
    var leftOnly = false
    var recording = false
    var startAccepts = true

    var callbacks: [String] = []
    var logs: [String] = []
    var lastActions: [HotkeyGestureMachine.Action] = []
    var holdTimer: TimeInterval?        // 挂着的长按升级定时器（startedAt）
    var releaseTimerPending = false     // 挂着的松手确认定时器

    init(_ shortcut: RecordingHotkeyShortcut, tapToggle: Bool = true) {
        machine = HotkeyGestureMachine(shortcut: shortcut, tapToggleEnabled: tapToggle)
    }

    var env: HotkeyGestureMachine.Environment {
        HotkeyGestureMachine.Environment(
            isSuspended: { [unowned self] in self.suspended },
            isActive: { [unowned self] in self.active },
            optionLeftOnly: { [unowned self] in self.leftOnly },
            isRecording: { [unowned self] in self.recording })
    }

    func send(_ input: HotkeyGestureMachine.Input) {
        let actions = machine.handle(input, env: env)
        lastActions = actions
        perform(actions)
    }

    func perform(_ actions: [HotkeyGestureMachine.Action]) {
        for action in actions {
            switch action {
            case .start(let at):
                callbacks.append("start")
                if startAccepts { recording = true }
                send(.startResult(accepted: startAccepts, at: at))
            case .stop: callbacks.append("stop"); recording = false
            case .cancel: callbacks.append("cancel"); recording = false
            case .chordCancel: callbacks.append("chordCancel"); recording = false
            case .classified(let hold): callbacks.append(hold ? "hold" : "tap")
            case .scheduleHoldPromotion(let startedAt, let delay):
                XCTAssertEqual(delay, RecordingHotkeyBehavior.holdThreshold)
                holdTimer = startedAt
            case .cancelHoldPromotion: holdTimer = nil
            case .scheduleReleaseCheck(let delay):
                XCTAssertEqual(delay, 0.08)
                releaseTimerPending = true
            case .cancelReleaseCheck: releaseTimerPending = false
            case .log(let message): logs.append(message)
            }
        }
    }

    // 输入

    func flags(_ raw: UInt64, at t: TimeInterval, keyCode: UInt16 = 0) {
        send(.flagsChanged(rawFlags: raw, keyCode: keyCode, at: t))
    }

    func keyDown(_ keyCode: UInt16, _ flags: HotkeyModifierFlags, at t: TimeInterval, isRepeat: Bool = false) {
        send(.keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat, at: t))
    }

    func keyUp(_ keyCode: UInt16, at t: TimeInterval) {
        send(.keyUp(keyCode: keyCode, at: t))
    }

    /// 长按门槛到点
    func fireHold() {
        guard let startedAt = holdTimer else { return }
        holdTimer = nil
        send(.holdPromotionDue(startedAt: startedAt))
    }

    /// 松手确认到点
    func fireRelease(stillDown: Bool = false, at t: TimeInterval) {
        XCTAssertTrue(releaseTimerPending, "没有挂着的松手确认")
        releaseTimerPending = false
        send(.releaseCheckDue(stillDown: stillDown, at: t))
    }
}

final class HotkeyGestureMachineTests: XCTestCase {
    private let opt = UInt64(HotkeyModifierFlags.option.rawValue)
    private let cmd = UInt64(HotkeyModifierFlags.command.rawValue)
    private let shift = UInt64(HotkeyModifierFlags.shift.rawValue)
    private let leftOpt: UInt64 = 0x20, rightOpt: UInt64 = 0x40
    private let leftCmd: UInt64 = 0x08, rightCmd: UInt64 = 0x10

    // MARK: - 长按

    func testHoldPromotesThenReleaseStops() {
        let d = Driver(.modifier(.option))
        d.flags(opt | leftOpt, at: 10)
        XCTAssertEqual(d.callbacks, ["start"])
        XCTAssertEqual(d.machine.state, .pressing(startedAt: 10, sawChord: false))
        XCTAssertEqual(d.holdTimer, 10)

        d.fireHold()
        XCTAssertEqual(d.machine.state, .holdRecording(startedAt: 10, sawChord: false))
        XCTAssertEqual(d.callbacks, ["start", "hold"])

        d.flags(0, at: 12)
        XCTAssertEqual(d.machine.releaseObservedAt, 12)
        XCTAssertEqual(d.callbacks, ["start", "hold"])   // 先等 0.08s 确认
        d.fireRelease(at: 12.09)
        XCTAssertEqual(d.callbacks, ["start", "hold", "stop"])
        XCTAssertEqual(d.machine.state, .idle)
        XCTAssertFalse(d.machine.wasModifierDown)
        XCTAssertTrue(d.logs.contains("→ onStop hold duration=2.000 chord=false"))
    }

    func testLongPressWithoutTimerStillStopsByDuration() {
        // 升级定时器没来得及跑（主线程卡住），按真实时长判定也是长按
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.flags(0, at: 0.8)
        d.fireRelease(at: 0.9)
        XCTAssertEqual(d.callbacks, ["start", "stop"])
        XCTAssertNil(d.holdTimer)
    }

    // MARK: - 轻点锁定

    func testTapLatchesThenSecondTapStops() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.flags(0, at: 0.2)
        d.fireRelease(at: 0.28)
        XCTAssertEqual(d.machine.state, .latchedRecording)
        XCTAssertEqual(d.callbacks, ["start", "tap"])
        XCTAssertNil(d.holdTimer)   // 松手时撤掉了长按升级

        d.flags(opt, at: 3)
        XCTAssertEqual(d.callbacks, ["start", "tap", "stop"])
        XCTAssertEqual(d.machine.state, .idle)
        XCTAssertEqual(d.lastActions.last, .stop)
        XCTAssertTrue(d.logs.contains("→ onStop (tap toggle)"))

        d.flags(0, at: 3.1)
        d.fireRelease(at: 3.2)
        XCTAssertEqual(d.callbacks, ["start", "tap", "stop"])   // 第二次松手不再动作
        XCTAssertTrue(d.logs.contains("release ignored in idle"))
    }

    func testTapUsesRealReleaseTimeNotConfirmTime() {
        // 按了 0.45s 松手，确认在 0.53s 才跑：按 0.45 算，是单击
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.flags(0, at: 0.45)
        d.fireHold()   // 0.5s 到点时已经看到松手，不能升级
        XCTAssertEqual(d.machine.state, .pressing(startedAt: 0, sawChord: false))
        d.fireRelease(at: 0.53)
        XCTAssertEqual(d.machine.state, .latchedRecording)
        XCTAssertEqual(d.callbacks, ["start", "tap"])
    }

    func testTapToggleDisabledStopsOnQuickRelease() {
        let d = Driver(.modifier(.option), tapToggle: false)
        d.flags(opt, at: 0)
        d.flags(0, at: 0.1)
        d.fireRelease(at: 0.18)
        XCTAssertEqual(d.callbacks, ["start", "stop"])
        XCTAssertEqual(d.machine.state, .idle)
    }

    func testLatchedRecordingIgnoresRelease() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0); d.flags(0, at: 0.1); d.fireRelease(at: 0.2)
        XCTAssertEqual(d.machine.state, .latchedRecording)
        // 锁定后打字带着 ⌥（不是热键本身的按下）不影响
        d.keyDown(0, .option, at: 1)
        XCTAssertEqual(d.machine.state, .latchedRecording)
        XCTAssertEqual(d.callbacks, ["start", "tap"])
    }

    // MARK: - 组合键

    func testCommandCDuringPressingCancelsImmediately() {
        let d = Driver(.modifier(.command))
        d.flags(cmd | leftCmd, at: 0)
        XCTAssertEqual(d.callbacks, ["start"])
        d.keyDown(8, .command, at: 0.12)   // C
        XCTAssertEqual(d.callbacks, ["start", "chordCancel"])
        XCTAssertEqual(d.lastActions.first, .cancelHoldPromotion)
        XCTAssertEqual(d.lastActions.last, .chordCancel)
        XCTAssertEqual(d.machine.state, .idle)
        XCTAssertNil(d.holdTimer)

        // 松开 ⌘：什么都不做，也不会再 stop
        d.flags(0, at: 0.3)
        d.fireRelease(at: 0.38)
        XCTAssertEqual(d.callbacks, ["start", "chordCancel"])

        // 下一次正常按下照常开录
        d.flags(cmd | leftCmd, at: 2)
        XCTAssertEqual(d.callbacks, ["start", "chordCancel", "start"])
    }

    func testShiftForCapitalLetterCancels() {
        let d = Driver(.modifier(.shift))
        d.flags(shift | 0x02, at: 0)
        d.keyDown(0, .shift, at: 0.05)   // ⇧A
        XCTAssertEqual(d.callbacks, ["start", "chordCancel"])
    }

    func testChordCancelIgnoresKeysWithoutConfiguredModifier() {
        let d = Driver(.modifier(.command))
        d.flags(cmd, at: 0)
        d.keyDown(0, [], at: 0.1)            // 事件里没带 ⌘：不当组合键
        d.keyDown(0, .command, at: 0.2, isRepeat: true)   // 按住重复：忽略
        XCTAssertEqual(d.machine.state, .pressing(startedAt: 0, sawChord: false))
        XCTAssertEqual(d.callbacks, ["start"])
    }

    func testKeyAfterHoldKeepsRecording() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.fireHold()
        d.keyDown(0, .option, at: 1)
        XCTAssertEqual(d.machine.state, .holdRecording(startedAt: 0, sawChord: true))
        XCTAssertEqual(d.callbacks, ["start", "hold"])   // 不取消
        d.flags(0, at: 2)
        d.fireRelease(at: 2.08)
        XCTAssertEqual(d.callbacks, ["start", "hold", "stop"])
        XCTAssertTrue(d.logs.contains("→ onStop hold duration=2.000 chord=true"))
    }

    // MARK: - Esc

    func testEscDuringHoldCancels() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.fireHold()
        d.keyDown(53, .option, at: 1)
        XCTAssertEqual(d.callbacks, ["start", "hold", "cancel"])
        XCTAssertEqual(d.machine.state, .idle)
    }

    func testEscDuringPressingCancelsNotChordCancel() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.keyDown(53, .option, at: 0.1)
        XCTAssertEqual(d.callbacks, ["start", "cancel"])
        d.fireHold()   // 定时器没撤，但状态已不是 pressing，不会升级
        XCTAssertEqual(d.machine.state, .idle)
        XCTAssertEqual(d.callbacks, ["start", "cancel"])
    }

    func testEscWhenLatchedDoesNothing() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0); d.flags(0, at: 0.1); d.fireRelease(at: 0.2)
        d.keyDown(53, [], at: 1)
        XCTAssertEqual(d.machine.state, .latchedRecording)
        XCTAssertEqual(d.callbacks, ["start", "tap"])
    }

    func testEscWhenNotRecordingFallsThroughToChord() {
        let d = Driver(.modifier(.option))
        d.startAccepts = true
        d.flags(opt, at: 0)
        d.recording = false   // App 那边录音其实没起来
        d.keyDown(53, .option, at: 0.1)
        XCTAssertEqual(d.callbacks, ["start", "chordCancel"])
    }

    // MARK: - 右 Command / 右 Option

    func testRightCommandWhileLeftCommandHeld() {
        let d = Driver(.modifier(.rightCommand))
        d.flags(cmd | leftCmd, at: 0)                 // 先按住左 ⌘
        XCTAssertEqual(d.callbacks, [])
        d.flags(cmd | leftCmd | rightCmd, at: 0.3)    // 再按右 ⌘
        XCTAssertEqual(d.callbacks, ["start"])
        XCTAssertTrue(d.machine.wasModifierDown)
        d.flags(cmd | leftCmd, at: 0.5)               // 松开右 ⌘，左 ⌘ 还按着
        XCTAssertTrue(d.releaseTimerPending)
        d.fireRelease(at: 0.58)
        XCTAssertEqual(d.callbacks, ["start", "tap"])
        XCTAssertEqual(d.machine.state, .latchedRecording)

        d.flags(cmd | leftCmd | rightCmd, at: 2)      // 再按右 ⌘：结束
        XCTAssertEqual(d.callbacks, ["start", "tap", "stop"])
    }

    func testLeftCommandChangesDoNotReleaseRightCommand() {
        let d = Driver(.modifier(.rightCommand))
        d.flags(cmd | rightCmd, at: 0)
        d.flags(cmd | rightCmd | leftCmd, at: 0.2)    // 按住右 ⌘ 时再按左 ⌘
        d.flags(cmd | rightCmd, at: 0.3)              // 松开左 ⌘
        XCTAssertFalse(d.releaseTimerPending)
        d.fireHold()
        XCTAssertEqual(d.machine.state, .holdRecording(startedAt: 0, sawChord: false))
        d.flags(0, at: 1.5)
        d.fireRelease(at: 1.6)
        XCTAssertEqual(d.callbacks, ["start", "hold", "stop"])
    }

    func testRightOptionIgnoresLeftOption() {
        let d = Driver(.modifier(.rightOption))
        d.flags(opt | leftOpt, at: 0)
        XCTAssertEqual(d.callbacks, [])
        d.flags(opt | leftOpt | rightOpt, at: 0.2)
        XCTAssertEqual(d.callbacks, ["start"])
        d.flags(opt | leftOpt, at: 0.3)
        d.fireRelease(at: 0.4)
        XCTAssertEqual(d.callbacks, ["start", "tap"])
    }

    func testOptionLeftOnlyIgnoresRightOption() {
        let d = Driver(.modifier(.option))
        d.leftOnly = true
        d.flags(opt | rightOpt, at: 0)
        XCTAssertEqual(d.callbacks, [])
        d.flags(opt | rightOpt | leftOpt, at: 1)
        XCTAssertEqual(d.callbacks, ["start"])
    }

    // MARK: - 去重与抖动

    func testDedupeDropsSameDirectionRepeatsOnly() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.flags(opt, at: 0.01)   // 另一个监听器报的同一次按下
        XCTAssertEqual(d.callbacks, ["start"])
        d.flags(0, at: 0.03)     // 50ms 内方向相反的松手：闪电单击，不能吞
        XCTAssertTrue(d.releaseTimerPending)
        d.flags(0, at: 0.04)     // 重复的松手丢掉
        d.fireRelease(at: 0.11)
        XCTAssertEqual(d.callbacks, ["start", "tap"])
    }

    func testFalseReleaseKeepsHoldGoing() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.flags(0, at: 0.2)                      // flag 抖动报了松手
        d.fireRelease(stillDown: true, at: 0.28) // 实际还按着
        XCTAssertNil(d.machine.releaseObservedAt)
        XCTAssertTrue(d.machine.wasModifierDown)
        d.fireHold()
        XCTAssertEqual(d.machine.state, .holdRecording(startedAt: 0, sawChord: false))
        XCTAssertEqual(d.callbacks, ["start", "hold"])
    }

    func testStaleHoldPromotionIgnored() {
        var machine = HotkeyGestureMachine(shortcut: .modifier(.option), tapToggleEnabled: true)
        let env = HotkeyGestureMachine.Environment(isSuspended: { false }, isActive: { true },
                                                   optionLeftOnly: { false }, isRecording: { false })
        _ = machine.handle(.flagsChanged(rawFlags: UInt64(HotkeyModifierFlags.option.rawValue), keyCode: 58, at: 5), env: env)
        _ = machine.handle(.startResult(accepted: true, at: 5), env: env)
        XCTAssertEqual(machine.handle(.holdPromotionDue(startedAt: 1), env: env), [])
        XCTAssertEqual(machine.state, .pressing(startedAt: 5, sawChord: false))
    }

    // MARK: - App 侧状态

    func testStartRejectedStaysIdle() {
        let d = Driver(.modifier(.option))
        d.startAccepts = false
        d.flags(opt, at: 0)
        XCTAssertEqual(d.callbacks, ["start"])
        XCTAssertEqual(d.machine.state, .idle)
        XCTAssertNil(d.holdTimer)
        XCTAssertTrue(d.logs.contains("start ignored by app"))
        d.flags(0, at: 0.2)
        d.fireRelease(at: 0.3)
        XCTAssertEqual(d.callbacks, ["start"])
    }

    func testPressWhileAlreadyRecordingStops() {
        let d = Driver(.modifier(.option))
        d.recording = true   // 比如鼠标长按开的录音
        d.flags(opt, at: 0)
        XCTAssertEqual(d.callbacks, ["stop"])
        XCTAssertEqual(d.machine.state, .idle)
    }

    func testSuspendedIgnoresEverything() {
        let d = Driver(.modifier(.option))
        d.suspended = true
        d.flags(opt, at: 0)
        d.keyDown(49, .option, at: 0.1)
        d.keyUp(49, at: 0.2)
        XCTAssertEqual(d.callbacks, [])
        XCTAssertEqual(d.logs, [])
        XCTAssertFalse(d.machine.wasModifierDown)

        // 录自定义键时暂停，⌥Space 的 ⌥ 也不会开听写
        let custom = Driver(.custom(RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: .option, keyDisplay: "Space")))
        custom.suspended = true
        custom.keyDown(49, .option, at: 0)
        XCTAssertEqual(custom.callbacks, [])

        // 恢复后正常
        d.suspended = false
        d.flags(opt, at: 1)
        XCTAssertEqual(d.callbacks, ["start"])
    }

    func testInactiveProfileIgnoresFlagsAndKeyDown() {
        let d = Driver(.modifier(.option))
        d.active = false
        d.flags(opt, at: 0)
        XCTAssertEqual(d.callbacks, [])
        XCTAssertFalse(d.machine.wasModifierDown)
    }

    func testRecordingDidLeaveActiveStateResets() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0); d.flags(0, at: 0.1); d.fireRelease(at: 0.2)
        XCTAssertEqual(d.machine.state, .latchedRecording)
        d.recording = false   // App 把录音结束了（比如点了胶囊上的对勾）
        d.perform(d.machine.recordingDidLeaveActiveState(isPressedNow: false))
        XCTAssertEqual(d.machine.state, .idle)
        d.flags(opt, at: 2)
        XCTAssertEqual(d.callbacks, ["start", "tap", "start"])   // 下一次按下是新的开始，不是 stop

        // 录音被 App 结束时热键正按着：wasModifierDown 同步为 true，那次松手不会再开录
        d.perform(d.machine.recordingDidLeaveActiveState(isPressedNow: true))
        XCTAssertTrue(d.machine.wasModifierDown)
        XCTAssertNil(d.holdTimer)
        XCTAssertFalse(d.releaseTimerPending)
    }

    func testReconfigureSwitchesShortcut() {
        let d = Driver(.modifier(.option))
        d.flags(opt, at: 0)
        d.perform(d.machine.reconfigure(shortcut: .modifier(.rightCommand), tapToggleEnabled: false, isPressedNow: false))
        XCTAssertEqual(d.machine.state, .idle)
        XCTAssertEqual(d.machine.shortcut, .modifier(.rightCommand))
        XCTAssertFalse(d.machine.tapToggleEnabled)
        XCTAssertNil(d.holdTimer)
        XCTAssertTrue(d.logs.contains("hotkey settings changed: shortcut=rightCommand tapToggle=false"))
        d.recording = false   // App 那边同时把录音收掉了

        d.flags(opt, at: 1)
        XCTAssertEqual(d.callbacks, ["start"])   // Option 不再响应
        d.flags(cmd | rightCmd, at: 2)
        XCTAssertEqual(d.callbacks, ["start", "start"])
    }

    // MARK: - 自定义组合键

    func testCustomShortcutTapAndHold() {
        let optSpace = RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: .option, keyDisplay: "Space")
        let d = Driver(.custom(optSpace))
        d.flags(opt, at: 0)                 // 单按 ⌥ 不响应
        XCTAssertEqual(d.callbacks, [])
        d.keyDown(49, .option, at: 0.1)
        XCTAssertEqual(d.callbacks, ["start"])
        d.keyDown(49, .option, at: 0.12)    // 另一个监听器的重复
        d.keyDown(49, .option, at: 0.2, isRepeat: true)
        XCTAssertEqual(d.callbacks, ["start"])
        d.keyUp(49, at: 0.25)
        d.keyUp(49, at: 0.26)               // 重复的松手
        d.fireRelease(at: 0.33)
        XCTAssertEqual(d.callbacks, ["start", "tap"])

        d.keyDown(49, .option, at: 2)
        XCTAssertEqual(d.callbacks, ["start", "tap", "stop"])
        d.keyUp(49, at: 2.1)
        d.fireRelease(at: 2.18)
        XCTAssertEqual(d.callbacks, ["start", "tap", "stop"])

        // 长按
        d.keyDown(49, .option, at: 5)
        d.fireHold()
        d.keyUp(49, at: 6)
        d.fireRelease(at: 6.08)
        XCTAssertEqual(d.callbacks, ["start", "tap", "stop", "start", "hold", "stop"])
    }

    func testCustomShortcutRequiresExactModifiers() {
        let optSpace = RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: .option, keyDisplay: "Space")
        let d = Driver(.custom(optSpace))
        d.keyDown(49, [.option, .shift], at: 0)
        d.keyDown(49, [], at: 0.2)
        d.keyUp(49, at: 0.3)
        XCTAssertEqual(d.callbacks, [])
        XCTAssertFalse(d.releaseTimerPending)   // 没按下过，keyUp 不发起松手
    }

    func testCallbacksComeLastInEachBatch() {
        var machine = HotkeyGestureMachine(shortcut: .modifier(.option), tapToggleEnabled: true)
        let env = HotkeyGestureMachine.Environment(isSuspended: { false }, isActive: { true },
                                                   optionLeftOnly: { false }, isRecording: { false })
        let press = machine.handle(.flagsChanged(rawFlags: UInt64(HotkeyModifierFlags.option.rawValue), keyCode: 58, at: 0), env: env)
        XCTAssertEqual(press.last, .start(at: 0))
        XCTAssertEqual(press[1], .cancelReleaseCheck)
        XCTAssertEqual(press[2], .cancelHoldPromotion)
        XCTAssertEqual(machine.handle(.startResult(accepted: true, at: 0), env: env),
                       [.scheduleHoldPromotion(startedAt: 0, delay: 0.5)])
    }
}
