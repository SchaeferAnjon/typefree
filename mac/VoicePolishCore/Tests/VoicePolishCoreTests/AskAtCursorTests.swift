import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import VoicePolishCore

/// 修饰键匹配 + 两种倾听模式的状态机。都是纯逻辑，不碰 AppKit 事件，所以能直接测。
final class AskCursorModifierTests: XCTestCase {
    private let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0000_0001)
    private let rightControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0000_2000)
    private let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x0000_0020)

    func testDefaultIsLeftControl() {
        XCTAssertEqual(AskCursorModifierCombo.fallback.modifiers, [.leftControl])
        XCTAssertEqual(AskCursorModifierCombo.parse(nil).configValue, "leftControl")
        XCTAssertEqual(AskCursorModifierCombo.parse("").configValue, "leftControl")
        XCTAssertEqual(AskCursorModifierCombo.parse("nonsense").configValue, "leftControl")
    }

    func testParseKeepsSidesAndAcceptsOldSidelessValues() {
        XCTAssertEqual(AskCursorModifierCombo.parse("rightOption").modifiers, [.rightOption])
        // 不带左右的老写法当成左边那个
        XCTAssertEqual(AskCursorModifierCombo.parse("option").modifiers, [.leftOption])
        XCTAssertEqual(AskCursorModifierCombo.parse("control+shift").modifiers, [.leftControl, .leftShift])
    }

    func testConfigValueIsStableRegardlessOfOrder() {
        let a = AskCursorModifierCombo([.leftCommand, .leftControl])!
        let b = AskCursorModifierCombo([.leftControl, .leftCommand])!
        XCTAssertEqual(a.configValue, b.configValue)
        XCTAssertEqual(a.configValue, "leftControl+leftCommand")
    }

    func testLeftControlMatchesOnlyTheLeftKey() {
        let combo = AskCursorModifierCombo([.leftControl])!
        XCTAssertTrue(combo.matches(leftControl))
        XCTAssertFalse(combo.matches(rightControl))
        XCTAssertFalse(combo.matches(leftOption))
        XCTAssertFalse(combo.matches(CGEventFlags(rawValue: 0)))
    }

    func testOtherModifierFamiliesBlockTheMatch() {
        let combo = AskCursorModifierCombo([.leftControl])!
        // ⌘ 一起按着 = 用户在用系统手势，不该被我们抢走
        let controlAndCommand = CGEventFlags(rawValue: leftControl.rawValue | CGEventFlags.maskCommand.rawValue | 0x0000_0008)
        XCTAssertFalse(combo.matches(controlAndCommand))
    }

    func testCombinationNeedsBothKeys() {
        let combo = AskCursorModifierCombo([.leftControl, .leftShift])!
        let both = CGEventFlags(rawValue: leftControl.rawValue | CGEventFlags.maskShift.rawValue | 0x0000_0002)
        XCTAssertTrue(combo.matches(both))
        XCTAssertFalse(combo.matches(leftControl))
    }

    /// 少数输入设备只填通用位、不填左右位：宁可左右不分，也不能变成按了没反应
    func testFallsBackToFamilyBitWhenDeviceBitsAreMissing() {
        let combo = AskCursorModifierCombo([.leftControl])!
        XCTAssertTrue(combo.matches(.maskControl))
    }

    /// 大写锁定、数字小键盘这些位不该影响判断
    func testIgnoresUnrelatedFlags() {
        let combo = AskCursorModifierCombo([.leftControl])!
        let withNoise = CGEventFlags(rawValue: leftControl.rawValue
            | CGEventFlags.maskAlphaShift.rawValue
            | CGEventFlags.maskNumericPad.rawValue
            | CGEventFlags.maskNonCoalesced.rawValue)
        XCTAssertTrue(combo.matches(withNoise))
    }
}

final class AskCursorMachineTests: XCTestCase {
    private let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0000_0001)
    private let plain = CGEventFlags(rawValue: 0)

    private func machine(_ mode: AskCursorListenMode) -> AskCursorMachine {
        AskCursorMachine(combo: AskCursorModifierCombo([.leftControl])!, mode: mode)
    }

    // MARK: 按住模式

    func testHoldModeSwallowsTheWholePress() {
        var m = machine(.hold)
        let down = m.handle(.mouseDown(modifiers: leftControl), canStart: true)
        XCTAssertEqual(down, .init(swallow: true, action: .begin))
        XCTAssertEqual(m.handle(.mouseDragged, canStart: false), .init(swallow: true, action: .none))
        XCTAssertEqual(m.handle(.mouseUp, canStart: false), .init(swallow: true, action: .finish))
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: 点击切换模式

    func testClickToggleStartsOnFirstClickAndEndsOnNext() {
        var m = machine(.clickToggle)
        XCTAssertEqual(m.handle(.mouseDown(modifiers: leftControl), canStart: true), .init(swallow: true, action: .begin))
        // 触发的这一下松开也要吞掉，之后录音继续
        XCTAssertEqual(m.handle(.mouseUp, canStart: false), .init(swallow: true, action: .none))
        XCTAssertEqual(m.state, .listening)
        XCTAssertTrue(m.isActive)

        // 结束那一下不带修饰键也算，而且同样要吞掉，否则会点开指针底下的链接
        XCTAssertEqual(m.handle(.mouseDown(modifiers: plain), canStart: false), .init(swallow: true, action: .finish))
        XCTAssertEqual(m.handle(.mouseUp, canStart: false), .init(swallow: true, action: .none))
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(m.isActive)
    }

    func testRightClickAlsoEndsTheToggleSession() {
        var m = machine(.clickToggle)
        _ = m.handle(.mouseDown(modifiers: leftControl), canStart: true)
        _ = m.handle(.mouseUp, canStart: false)
        XCTAssertEqual(m.handle(.otherButtonDown, canStart: false), .init(swallow: true, action: .finish))
    }

    func testEscapeCancelsAndLetsTheKeyEventThrough() {
        var m = machine(.clickToggle)
        _ = m.handle(.mouseDown(modifiers: leftControl), canStart: true)
        _ = m.handle(.mouseUp, canStart: false)
        let esc = m.handle(.escape, canStart: false)
        XCTAssertEqual(esc, .init(swallow: false, action: .cancel))
        XCTAssertEqual(m.state, .idle)
    }

    func testEscapeDuringTheTriggeringPressStillSwallowsTheRelease() {
        var m = machine(.clickToggle)
        _ = m.handle(.mouseDown(modifiers: leftControl), canStart: true)
        XCTAssertEqual(m.handle(.escape, canStart: false), .init(swallow: false, action: .cancel))
        // 手还按着：这一下的松开不能漏给底下的 App
        XCTAssertEqual(m.handle(.mouseUp, canStart: false), .init(swallow: true, action: .none))
        XCTAssertEqual(m.state, .idle)
    }

    func testTimeoutFinishesTheSession() {
        var m = machine(.clickToggle)
        _ = m.handle(.mouseDown(modifiers: leftControl), canStart: true)
        _ = m.handle(.mouseUp, canStart: false)
        XCTAssertEqual(m.handle(.timeout, canStart: false), .init(swallow: false, action: .finish))
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: 不该触发的情况

    func testPlainClickPassesThrough() {
        var m = machine(.clickToggle)
        XCTAssertEqual(m.handle(.mouseDown(modifiers: plain), canStart: true), .init(swallow: false, action: .none))
        XCTAssertEqual(m.handle(.mouseUp, canStart: true), .init(swallow: false, action: .none))
        XCTAssertEqual(m.state, .idle)
    }

    func testDoesNotStartWhenAppIsBusy() {
        var m = machine(.clickToggle)
        XCTAssertEqual(m.handle(.mouseDown(modifiers: leftControl), canStart: false), .init(swallow: false, action: .none))
        XCTAssertEqual(m.state, .idle)
    }

    func testResetKeepsSwallowingTheRestOfThePress() {
        var m = machine(.hold)
        _ = m.handle(.mouseDown(modifiers: leftControl), canStart: true)
        m.reset()
        XCTAssertEqual(m.state, .swallowUntilUp)
        XCTAssertEqual(m.handle(.mouseUp, canStart: false), .init(swallow: true, action: .none))
        XCTAssertEqual(m.state, .idle)
    }

    func testResetWhileIdleIsANoop() {
        var m = machine(.clickToggle)
        m.reset()
        XCTAssertEqual(m.state, .idle)
    }

    /// 松开事件丢了（事件拦截被系统短暂停用过）：下一次按下要自愈，不能「按下放行、松开被吞」
    func testSwallowUntilUpSelfHealsWhenTheUpEventWasLost() {
        var machine = AskCursorMachine(combo: .parse("leftControl"), mode: .clickToggle, state: .swallowUntilUp)
        let plainDown = machine.handle(.mouseDown(modifiers: []), canStart: true)
        XCTAssertEqual(plainDown, .init(swallow: false, action: .none))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.mouseUp, canStart: true), .init(swallow: false, action: .none))
    }
}
