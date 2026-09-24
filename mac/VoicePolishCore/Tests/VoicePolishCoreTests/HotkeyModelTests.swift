import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import VoicePolishCore

final class HotkeyModelTests: XCTestCase {
    private var dir: URL!
    private var config: VoicePolishConfig!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vphk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        config = VoicePolishConfig(configDir: dir, secrets: InMemorySecretStore())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func raw(_ key: String) -> String? { config.string(forKey: key) }

    private let optSpace = RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: .option, keyDisplay: "Space")

    // MARK: - 标志位与 AppKit 一致（config 里存的就是 rawValue）

    #if canImport(AppKit)
    func testModifierFlagBitsMatchAppKit() {
        XCTAssertEqual(HotkeyModifierFlags.shift.rawValue, NSEvent.ModifierFlags.shift.rawValue)
        XCTAssertEqual(HotkeyModifierFlags.control.rawValue, NSEvent.ModifierFlags.control.rawValue)
        XCTAssertEqual(HotkeyModifierFlags.option.rawValue, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(HotkeyModifierFlags.command.rawValue, NSEvent.ModifierFlags.command.rawValue)
        XCTAssertEqual(HotkeyModifierFlags.function.rawValue, NSEvent.ModifierFlags.function.rawValue)
        XCTAssertEqual(HotkeyModifierFlags.capsLock.rawValue, NSEvent.ModifierFlags.capsLock.rawValue)
        XCTAssertEqual(HotkeyModifierFlags.deviceIndependentFlagsMask.rawValue,
                       NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
        XCTAssertEqual(UInt64(HotkeyModifierFlags.option.rawValue), CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(UInt64(HotkeyModifierFlags.command.rawValue), CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(UInt64(HotkeyModifierFlags.control.rawValue), CGEventFlags.maskControl.rawValue)
        XCTAssertEqual(UInt64(HotkeyModifierFlags.shift.rawValue), CGEventFlags.maskShift.rawValue)
        XCTAssertEqual(UInt64(HotkeyModifierFlags.function.rawValue), CGEventFlags.maskSecondaryFn.rawValue)
    }
    #endif

    // MARK: - 听写快捷键读写

    func testRecordingDefaultsToOption() {
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.option))
        XCTAssertFalse(RecordingHotkeyShortcut.isDisabled(in: config))
        XCTAssertEqual(RecordingHotkeyModifier.current(in: config), .option)
    }

    func testRecordingCommandThenFnThenNone() {
        RecordingHotkeyShortcut.useModifier(.command, in: config)
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.command))
        XCTAssertEqual(raw("recording_hotkey_mode"), "modifier")
        XCTAssertEqual(raw("recording_hotkey_modifier"), "command")
        XCTAssertFalse(RecordingHotkeyShortcut.isDisabled(in: config))

        RecordingHotkeyShortcut.useModifier(.fn, in: config)
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.fn))
        XCTAssertEqual(raw("recording_hotkey_modifier"), "fn")
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config).displayName, "fn Fn")

        RecordingHotkeyShortcut.disable(in: config)
        XCTAssertTrue(RecordingHotkeyShortcut.isDisabled(in: config))
        XCTAssertEqual(raw("recording_hotkey_mode"), "none")
        // 「不设置」只改 mode，上次选的键还在，current 仍返回它（调用方先看 isDisabled）
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.fn))

        RecordingHotkeyShortcut.useModifier(.command, in: config)
        XCTAssertFalse(RecordingHotkeyShortcut.isDisabled(in: config))
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.command))
    }

    func testRecordingCustomRoundTripUsesContractKeys() {
        let shortcut = RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: [.option, .shift], keyDisplay: "Space")
        RecordingHotkeyShortcut.useCustom(shortcut, in: config)
        XCTAssertEqual(raw("recording_hotkey_mode"), "custom")
        XCTAssertEqual(raw(RecordingHotkeyCustomShortcut.keyCodeConfigKey), "49")
        XCTAssertEqual(raw("recording_hotkey_custom_key_code"), "49")
        XCTAssertEqual(raw("recording_hotkey_custom_modifiers"), String(HotkeyModifierFlags([.option, .shift]).rawValue))
        XCTAssertEqual(raw("recording_hotkey_custom_key_display"), "Space")
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .custom(shortcut))
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config).displayName, "⌥⇧Space")

        // 切回单修饰键：自定义组合留在 config 里，但不再生效
        RecordingHotkeyShortcut.useModifier(.control, in: config)
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.control))
        XCTAssertEqual(raw("recording_hotkey_custom_key_code"), "49")
    }

    func testCustomModeWithBrokenDataFallsBackToModifier() {
        config.save(value: "custom", forKey: "recording_hotkey_mode")
        config.save(value: "shift", forKey: "recording_hotkey_modifier")
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.shift))
        config.save(value: "abc", forKey: "recording_hotkey_custom_key_code")
        config.save(value: "524288", forKey: "recording_hotkey_custom_modifiers")
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.shift))
    }

    func testUnknownModifierFallsBackToOption() {
        config.save(value: "hyper", forKey: "recording_hotkey_modifier")
        XCTAssertEqual(RecordingHotkeyModifier.current(in: config), .option)
    }

    func testSavedCustomKeepsRawModifierBitsAndDefaultsDisplay() {
        let rawBits = HotkeyModifierFlags.command.rawValue | 0x08 | 0x100   // 带设备位也原样读回
        config.save(value: "12", forKey: "ask_plain_hotkey_custom_key_code")
        config.save(value: String(rawBits), forKey: "ask_plain_hotkey_custom_modifiers")
        let saved = RecordingHotkeyCustomShortcut.saved(prefix: "ask_plain_hotkey", in: config)
        XCTAssertEqual(saved?.modifiers.rawValue, rawBits)
        XCTAssertEqual(saved?.keyDisplay, "Key 12")
        XCTAssertEqual(saved?.displayName, "⌘Key 12")
    }

    func testTapToggleConfig() {
        XCTAssertTrue(RecordingHotkeyBehavior.isTapToggleEnabled(in: config))
        config.save(bool: false, forKey: "recording_hotkey_tap_toggle_enabled")
        XCTAssertFalse(RecordingHotkeyBehavior.isTapToggleEnabled(in: config))
        config.save(value: "true", forKey: RecordingHotkeyBehavior.tapToggleConfigKey)
        XCTAssertTrue(RecordingHotkeyBehavior.isTapToggleEnabled(in: config))
        XCTAssertEqual(RecordingHotkeyBehavior.holdThreshold, 0.50)
    }

    // MARK: - 问 AI 快捷键读写

    func testAskHotkeyDefaults() {
        XCTAssertEqual(AskHotkey.screen.current(in: config), .modifier(.rightOption))
        XCTAssertNil(AskHotkey.plain.current(in: config))
        XCTAssertTrue(AskHotkey.screen.isActive(in: config))
        XCTAssertFalse(AskHotkey.plain.isActive(in: config))
        XCTAssertEqual(AskHotkey.plain.displayName(in: config), "未设置")
        XCTAssertEqual(AskHotkey.screen.displayName(in: config), "⌥ 右 Option")
    }

    func testAskHotkeyUseModifierCustomAndClear() {
        AskHotkey.screen.useModifier(.rightCommand, in: config)
        XCTAssertEqual(raw("ask_hotkey_mode"), "modifier")
        XCTAssertEqual(raw("ask_hotkey_modifier"), "rightCommand")
        XCTAssertEqual(AskHotkey.screen.current(in: config), .modifier(.rightCommand))

        let shortcut = RecordingHotkeyCustomShortcut(keyCode: 40, modifiers: [.control, .option], keyDisplay: "K")
        AskHotkey.plain.useCustom(shortcut, in: config)
        XCTAssertEqual(raw("ask_plain_hotkey_mode"), "custom")
        XCTAssertEqual(raw("ask_plain_hotkey_custom_key_code"), "40")
        XCTAssertEqual(raw("ask_plain_hotkey_custom_key_display"), "K")
        XCTAssertEqual(AskHotkey.plain.current(in: config), .custom(shortcut))
        XCTAssertEqual(AskHotkey.plain.displayName(in: config), "⌃⌥K")
        // 两套各存各的，听写不受影响
        XCTAssertNil(raw("recording_hotkey_custom_key_code"))
        XCTAssertEqual(RecordingHotkeyShortcut.current(in: config), .modifier(.option))

        AskHotkey.screen.clear(in: config)
        XCTAssertEqual(raw("ask_hotkey_mode"), "none")
        XCTAssertNil(AskHotkey.screen.current(in: config))
        XCTAssertFalse(AskHotkey.screen.isActive(in: config))
        XCTAssertNil(AskHotkey.screen.conflict(in: config))

        // 清掉之后再选键：回到 modifier 模式
        AskHotkey.screen.useModifier(.control, in: config)
        XCTAssertEqual(AskHotkey.screen.current(in: config), .modifier(.control))
    }

    func testAskHotkeyNoneModeIgnoresDefault() {
        config.save(value: "none", forKey: "ask_hotkey_mode")
        config.save(value: "shift", forKey: "ask_hotkey_modifier")
        XCTAssertNil(AskHotkey.screen.current(in: config))
    }

    // MARK: - 撞键

    func testConflictSameAsRecording() {
        AskHotkey.screen.useModifier(.option, in: config)
        XCTAssertEqual(AskHotkey.screen.conflict(in: config), "和「开始说话」的快捷键相同")
        XCTAssertFalse(AskHotkey.screen.isActive(in: config))
        XCTAssertFalse(AskHotkey.screen.uses(.option, in: config))

        // 听写设成「不设置」后就不撞了
        RecordingHotkeyShortcut.disable(in: config)
        XCTAssertNil(AskHotkey.screen.conflict(in: config))
        XCTAssertTrue(AskHotkey.screen.isActive(in: config))
        XCTAssertTrue(AskHotkey.screen.uses(.option, in: config))
    }

    func testConflictOverlapWithRecordingModifier() {
        AskHotkey.plain.useCustom(optSpace, in: config)   // ⌥Space 和听写的 Option 重叠
        XCTAssertEqual(AskHotkey.plain.conflict(in: config), "和「开始说话」的快捷键重叠")
        RecordingHotkeyShortcut.useModifier(.command, in: config)
        // 看屏幕问默认的右 Option 通用位也是 ⌥，一样重叠
        XCTAssertEqual(AskHotkey.plain.conflict(in: config), "和「看屏幕问 AI」的快捷键重叠")
        AskHotkey.screen.clear(in: config)
        XCTAssertNil(AskHotkey.plain.conflict(in: config))
        XCTAssertTrue(AskHotkey.plain.isActive(in: config))
    }

    func testPlainConflictsWithScreenButNotViceVersa() {
        RecordingHotkeyShortcut.useModifier(.control, in: config)
        AskHotkey.plain.useModifier(.rightOption, in: config)   // 和看屏幕问的默认键相同
        XCTAssertEqual(AskHotkey.plain.conflict(in: config), "和「看屏幕问 AI」的快捷键相同")
        XCTAssertNil(AskHotkey.screen.conflict(in: config))   // 优先级更高的那一套照常
        XCTAssertTrue(AskHotkey.screen.isActive(in: config))

        AskHotkey.screen.clear(in: config)
        XCTAssertNil(AskHotkey.plain.conflict(in: config))
    }

    func testRecordingConflictReportedBeforeScreen() {
        AskHotkey.screen.useModifier(.option, in: config)
        AskHotkey.plain.useModifier(.option, in: config)
        XCTAssertEqual(AskHotkey.plain.conflict(in: config), "和「开始说话」的快捷键相同")
    }

    func testRightOptionDoesNotConflictWithOption() {
        // 听写 Option + 看屏幕问右 Option（默认组合）：不算撞，靠 leftOnly 分开
        XCTAssertNil(AskHotkey.screen.conflict(in: config))
        XCTAssertTrue(AskHotkey.screen.uses(.rightOption, in: config))
    }

    // MARK: - overlaps

    func testOverlapsModifierPairs() {
        XCTAssertTrue(RecordingHotkeyShortcut.modifier(.option).overlaps(.modifier(.option)))
        XCTAssertFalse(RecordingHotkeyShortcut.modifier(.option).overlaps(.modifier(.rightOption)))
        XCTAssertFalse(RecordingHotkeyShortcut.modifier(.command).overlaps(.modifier(.rightCommand)))
        XCTAssertFalse(RecordingHotkeyShortcut.modifier(.option).overlaps(.modifier(.command)))
        XCTAssertFalse(RecordingHotkeyShortcut.modifier(.fn).overlaps(.modifier(.control)))
    }

    func testOverlapsCustomPairs() {
        let a = RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: .option, keyDisplay: "Space")
        // 同键同修饰键，多出的非修饰位（设备位、capsLock）不影响
        let b = RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: HotkeyModifierFlags(rawValue: HotkeyModifierFlags.option.rawValue | 0x20 | HotkeyModifierFlags.capsLock.rawValue), keyDisplay: "空格")
        XCTAssertTrue(RecordingHotkeyShortcut.custom(a).overlaps(.custom(b)))
        let otherKey = RecordingHotkeyCustomShortcut(keyCode: 36, modifiers: .option, keyDisplay: "Return")
        XCTAssertFalse(RecordingHotkeyShortcut.custom(a).overlaps(.custom(otherKey)))
        let otherMods = RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: [.option, .shift], keyDisplay: "Space")
        XCTAssertFalse(RecordingHotkeyShortcut.custom(a).overlaps(.custom(otherMods)))
    }

    func testOverlapsCustomVersusModifier() {
        let optSpace = RecordingHotkeyShortcut.custom(optSpace)
        XCTAssertTrue(optSpace.overlaps(.modifier(.option)))
        XCTAssertTrue(RecordingHotkeyShortcut.modifier(.option).overlaps(optSpace))   // 对称
        // 右 Option 的通用位也是 ⌥：按右 Option 同样会先开录
        XCTAssertTrue(optSpace.overlaps(.modifier(.rightOption)))
        XCTAssertFalse(optSpace.overlaps(.modifier(.command)))

        // 组合里有两颗修饰键：单按其中一颗不会被当成这个组合
        let optShiftSpace = RecordingHotkeyShortcut.custom(
            RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: [.option, .shift], keyDisplay: "Space"))
        XCTAssertFalse(optShiftSpace.overlaps(.modifier(.option)))
        XCTAssertFalse(RecordingHotkeyShortcut.modifier(.shift).overlaps(optShiftSpace))

        let cmdC = RecordingHotkeyShortcut.custom(RecordingHotkeyCustomShortcut(keyCode: 8, modifiers: .command, keyDisplay: "C"))
        XCTAssertTrue(cmdC.overlaps(.modifier(.command)))
        XCTAssertTrue(cmdC.overlaps(.modifier(.rightCommand)))
        let fnF = RecordingHotkeyShortcut.custom(RecordingHotkeyCustomShortcut(keyCode: 3, modifiers: .function, keyDisplay: "F"))
        XCTAssertTrue(fnF.overlaps(.modifier(.fn)))
    }

    // MARK: - 显示名

    func testArbiterShowsLeftOptionWhenRightIsTaken() {
        // 默认：听写 Option，看屏幕问占右 Option → 听写显示「左 Option」
        XCTAssertTrue(HotkeyArbiter.leftOnly(for: "recording", shortcut: .modifier(.option), in: config))
        XCTAssertEqual(HotkeyArbiter.displayName(for: "recording", shortcut: .modifier(.option), in: config), "⌥ 左 Option")
        // 右 Option 自己不带「左」
        XCTAssertEqual(HotkeyArbiter.displayName(for: "ask_hotkey", shortcut: .modifier(.rightOption), in: config), "⌥ 右 Option")

        AskHotkey.screen.clear(in: config)
        XCTAssertFalse(HotkeyArbiter.leftOnly(for: "recording", shortcut: .modifier(.option), in: config))
        XCTAssertEqual(HotkeyArbiter.displayName(for: "recording", shortcut: .modifier(.option), in: config), "⌥ Option")
    }

    func testArbiterLeftCommandIsSymmetric() {
        // 听写占右 Command，看屏幕问用通用 Command：问 AI 那一套只认左边
        RecordingHotkeyShortcut.useModifier(.rightCommand, in: config)
        AskHotkey.screen.useModifier(.command, in: config)
        XCTAssertEqual(AskHotkey.screen.displayName(in: config), "⌘ 左 Command")
        XCTAssertEqual(HotkeyArbiter.displayName(for: "recording", shortcut: .modifier(.rightCommand), in: config), "⌘ 右 Command")
        // 听写设成「不设置」后，右 Command 没人占了
        RecordingHotkeyShortcut.disable(in: config)
        XCTAssertEqual(AskHotkey.screen.displayName(in: config), "⌘ Command")
    }

    func testArbiterIgnoresInactiveHotkeys() {
        // 撞了键、不生效的那一套不参与让位
        AskHotkey.screen.clear(in: config)
        AskHotkey.plain.useModifier(.rightOption, in: config)
        RecordingHotkeyShortcut.useModifier(.rightOption, in: config)
        XCTAssertNotNil(AskHotkey.plain.conflict(in: config))
        XCTAssertEqual(HotkeyArbiter.others(than: "recording", in: config), [])
        XCTAssertEqual(HotkeyArbiter.others(than: "ask_plain_hotkey", in: config), [.modifier(.rightOption)])
    }

    func testArbiterMiscDisplayNames() {
        XCTAssertEqual(HotkeyArbiter.displayName(for: "recording", shortcut: nil, in: config), "未设置")
        XCTAssertEqual(HotkeyArbiter.displayName(for: "recording", shortcut: .modifier(.control), in: config), "⌃ Control")
        XCTAssertFalse(HotkeyArbiter.leftOnly(for: "recording", shortcut: .custom(optSpace), in: config))
        XCTAssertEqual(HotkeyArbiter.displayName(for: "recording", shortcut: .custom(optSpace), in: config), "⌥Space")
    }

    func testModifierNamesAndSymbols() {
        XCTAssertEqual(RecordingHotkeyModifier.allCases.map(\.rawValue),
                       ["option", "command", "control", "shift", "fn", "rightCommand", "rightOption"])
        XCTAssertEqual(RecordingHotkeyShortcut.modifier(.rightCommand).displayName, "⌘ 右 Command")
        XCTAssertEqual(RecordingHotkeyShortcut.modifier(.rightCommand).debugName, "rightCommand")
        XCTAssertEqual(RecordingHotkeyShortcut.custom(optSpace).debugName, "custom(⌥Space)")
        XCTAssertEqual(RecordingHotkeyModifier.fn.symbolName, "function")
        XCTAssertEqual(RecordingHotkeyModifier.rightOption.flag, .option)
        XCTAssertEqual(RecordingHotkeyModifier.option.rightVariant, .rightOption)
        XCTAssertEqual(RecordingHotkeyModifier.command.rightVariant, .rightCommand)
        XCTAssertNil(RecordingHotkeyModifier.shift.rightVariant)
    }

    // MARK: - 左右设备位

    private let cmd = UInt64(HotkeyModifierFlags.command.rawValue)
    private let opt = UInt64(HotkeyModifierFlags.option.rawValue)

    func testRightCommandUsesDeviceBit() {
        XCTAssertFalse(RecordingHotkeyModifier.rightCommand.matches(rawFlags: cmd | 0x08))           // 只按左 ⌘
        XCTAssertTrue(RecordingHotkeyModifier.rightCommand.matches(rawFlags: cmd | 0x10))            // 只按右 ⌘
        XCTAssertTrue(RecordingHotkeyModifier.rightCommand.matches(rawFlags: cmd | 0x08 | 0x10))     // 左右都按
        XCTAssertFalse(RecordingHotkeyModifier.rightCommand.matches(rawFlags: 0x10))                 // 没有通用位不算
        XCTAssertTrue(RecordingHotkeyModifier.command.matches(rawFlags: cmd | 0x10))
        XCTAssertFalse(RecordingHotkeyModifier.command.matches(rawFlags: cmd | 0x10, optionLeftOnly: true))
        XCTAssertTrue(RecordingHotkeyModifier.command.matches(rawFlags: cmd | 0x08, optionLeftOnly: true))
    }

    func testRightOptionUsesDeviceBit() {
        XCTAssertFalse(RecordingHotkeyModifier.rightOption.matches(rawFlags: opt | 0x20))
        XCTAssertTrue(RecordingHotkeyModifier.rightOption.matches(rawFlags: opt | 0x40))
        XCTAssertTrue(RecordingHotkeyModifier.rightOption.matches(rawFlags: opt | 0x20 | 0x40))
        XCTAssertTrue(RecordingHotkeyModifier.option.matches(rawFlags: opt | 0x40))
        XCTAssertFalse(RecordingHotkeyModifier.option.matches(rawFlags: opt | 0x40, optionLeftOnly: true))
        XCTAssertTrue(RecordingHotkeyModifier.option.matches(rawFlags: opt | 0x20 | 0x40, optionLeftOnly: true))
        // leftOnly 只影响 Option / Command
        XCTAssertTrue(RecordingHotkeyModifier.control.matches(rawFlags: UInt64(HotkeyModifierFlags.control.rawValue), optionLeftOnly: true))
        XCTAssertTrue(RecordingHotkeyModifier.fn.matches(rawFlags: UInt64(HotkeyModifierFlags.function.rawValue)))
        XCTAssertFalse(RecordingHotkeyModifier.shift.matches(rawFlags: opt))
    }

    func testCaptureSingleModifier() {
        XCTAssertEqual(RecordingHotkeyModifier.capture(flags: .option, keyCode: 58), .option)
        XCTAssertEqual(RecordingHotkeyModifier.capture(flags: .option, keyCode: 61), .rightOption)
        XCTAssertEqual(RecordingHotkeyModifier.capture(flags: .command, keyCode: 54), .rightCommand)
        XCTAssertEqual(RecordingHotkeyModifier.capture(flags: .function, keyCode: 63), .fn)
        XCTAssertEqual(RecordingHotkeyModifier.capture(flags: HotkeyModifierFlags(rawValue: HotkeyModifierFlags.shift.rawValue | 0x02), keyCode: 56), .shift)
        XCTAssertNil(RecordingHotkeyModifier.capture(flags: [.option, .command], keyCode: 58))
        XCTAssertNil(RecordingHotkeyModifier.capture(flags: [.control, .capsLock], keyCode: 59))
        XCTAssertNil(RecordingHotkeyModifier.capture(flags: [], keyCode: 0))
    }

    // MARK: - 自定义组合

    func testCustomMatchingAndDisplay() {
        XCTAssertTrue(optSpace.matchesKeyDown(keyCode: 49, flags: HotkeyModifierFlags(rawValue: HotkeyModifierFlags.option.rawValue | 0x20)))
        XCTAssertFalse(optSpace.matchesKeyDown(keyCode: 49, flags: [.option, .shift]))
        XCTAssertFalse(optSpace.matchesKeyDown(keyCode: 36, flags: .option))
        XCTAssertTrue(optSpace.matchesKeyUp(keyCode: 49))
        XCTAssertFalse(optSpace.matchesKeyUp(keyCode: 36))
        XCTAssertEqual(RecordingHotkeyCustomShortcut.symbols(for: [.command, .function, .shift, .option, .control]), "⌃⌥⇧⌘fn")
        XCTAssertEqual(RecordingHotkeyCustomShortcut.normalized([.option, .capsLock, .numericPad]), .option)
    }

    func testConflictWarnings() {
        XCTAssertNotNil(RecordingHotkeyCustomShortcut(keyCode: 49, modifiers: .command, keyDisplay: "Space").conflictWarning)
        XCTAssertNotNil(RecordingHotkeyCustomShortcut(keyCode: 48, modifiers: [.command, .shift], keyDisplay: "Tab").conflictWarning)
        XCTAssertNotNil(RecordingHotkeyCustomShortcut(keyCode: 8, modifiers: .command, keyDisplay: "C").conflictWarning)
        XCTAssertNil(RecordingHotkeyCustomShortcut(keyCode: 8, modifiers: [.command, .option], keyDisplay: "C").conflictWarning)
        XCTAssertNil(optSpace.conflictWarning)
    }

    func testKeyDisplayNames() {
        XCTAssertEqual(RecordingHotkeyCustomShortcut.keyDisplayName(keyCode: 49, characters: " "), "Space")
        XCTAssertEqual(RecordingHotkeyCustomShortcut.keyDisplayName(keyCode: 111, characters: nil), "F12")
        XCTAssertEqual(RecordingHotkeyCustomShortcut.keyDisplayName(keyCode: 0, characters: "a"), "A")
        XCTAssertEqual(RecordingHotkeyCustomShortcut.keyDisplayName(keyCode: 200, characters: "  "), "Key 200")
        XCTAssertEqual(RecordingHotkeyCustomShortcut.keyDisplayName(keyCode: 200, characters: nil), "Key 200")
    }
}
