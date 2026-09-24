import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

final class HotkeyRecorderView: AppearanceObservingView {
    private let displayLabel = NSTextField(labelWithString: "点击这里，然后按下新的快捷键")
    private let hintLabel = NSTextField(labelWithString: "建议使用 Option / Command / Control / Shift 搭配一个按键")
    private(set) var shortcut: RecordingHotkeyCustomShortcut?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func flagsChanged(with event: NSEvent) {
        let modifiers = RecordingHotkeyCustomShortcut.normalized(event.modifierFlags)
        guard !modifiers.isEmpty else {
            hintLabel.stringValue = "先按住一个修饰键，再按一个普通键"
            return
        }
        displayLabel.stringValue = "\(RecordingHotkeyCustomShortcut.symbols(for: modifiers)) ..."
        hintLabel.stringValue = "继续按一个按键完成录入"
    }

    /// 方向键、F1-F20、Home/End/PageUp/PageDown/向前删除/Help 的 keyCode
    private static let keysWithImplicitFn: Set<UInt16> = [
        123, 124, 125, 126,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
        115, 119, 116, 121, 117, 114,
    ]

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        let modifiers = RecordingHotkeyCustomShortcut.normalized(event.modifierFlags)
        // 方向键、F 键、Home/End 这类键系统自己会带上 .function，不代表用户按了 fn，判断有没有修饰键时去掉它。
        // 存的时候保留原样，matchesKeyDown 拿到的事件同样带着 .function，才对得上
        let pressed = Self.keysWithImplicitFn.contains(event.keyCode) ? modifiers.subtracting(.function) : modifiers
        guard !pressed.isEmpty else {
            shortcut = nil
            displayLabel.stringValue = "需要搭配修饰键"
            hintLabel.stringValue = "请至少按住 Option / Command / Control / Shift 中的一个"
            return
        }
        let keyDisplay = RecordingHotkeyCustomShortcut.keyDisplayName(for: event)
        let next = RecordingHotkeyCustomShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            keyDisplay: keyDisplay
        )
        shortcut = next
        displayLabel.stringValue = next.displayName
        hintLabel.stringValue = next.conflictWarning ?? "可以保存这个快捷键"
    }

    func setShortcut(_ shortcut: RecordingHotkeyCustomShortcut?) {
        self.shortcut = shortcut
        displayLabel.stringValue = shortcut?.displayName ?? "点击这里，然后按下新的快捷键"
        hintLabel.stringValue = "建议使用 Option / Command / Control / Shift 搭配一个按键"
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(NSColor.separatorColor)
        layer?.setAppearanceBackground(NSColor.controlBackgroundColor)

        displayLabel.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        displayLabel.textColor = .labelColor
        displayLabel.alignment = .center
        displayLabel.lineBreakMode = .byTruncatingMiddle

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [displayLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 360),
            heightAnchor.constraint(equalToConstant: 118),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
