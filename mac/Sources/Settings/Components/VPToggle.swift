import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 自绘滑动开关（iOS 风格）：开=近黑底圆钮在右，关=灰底圆钮在左；切换带平滑动画。
/// 用 `isOn` 读写状态、target/action 回调，替代系统蓝色复选框。
final class VPToggle: NSControl {
    private let trackOn: NSColor
    private let trackOff: NSColor
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    private let trackW: CGFloat = 38
    private let trackH: CGFloat = 22
    private let knobD: CGFloat = 18
    private let inset: CGFloat = 2

    private(set) var isOn = false

    init(theme: VPTheme, target: AnyObject?, action: Selector?) {
        trackOn = theme.accent
        trackOff = theme.text.withAlphaComponent(0.20)
        super.init(frame: NSRect(x: 0, y: 0, width: trackW, height: trackH))
        self.target = target
        self.action = action
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: trackW).isActive = true
        heightAnchor.constraint(equalToConstant: trackH).isActive = true

        trackLayer.frame = NSRect(x: 0, y: 0, width: trackW, height: trackH)
        trackLayer.cornerRadius = trackH / 2
        layer?.addSublayer(trackLayer)

        knobLayer.frame = NSRect(x: inset, y: inset, width: knobD, height: knobD)
        knobLayer.cornerRadius = knobD / 2
        knobLayer.setAppearanceBackground(theme.onAccent)   // 浅色下为白
        knobLayer.setAppearanceShadow(NSColor.black)
        knobLayer.shadowOpacity = 0.18
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knobLayer)

        render(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 设定开关状态（不触发 action）。animated=false 用于首次回显。
    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        render(animated: animated)
    }

    private func render(animated: Bool) {
        let knobX = isOn ? (trackW - knobD - inset) : inset
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        trackLayer.setAppearanceBackground((isOn ? trackOn : trackOff))
        knobLayer.frame = NSRect(x: knobX, y: inset, width: knobD, height: knobD)
        if !animated { CATransaction.commit() }
    }

    override func mouseDown(with event: NSEvent) { toggleByUser() }

    private func toggleByUser() {
        isOn.toggle()
        render(animated: true)
        sendAction(action, to: target)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // 辅助功能：读屏 / 自动化能读到开关状态并「按下」切换（原先只认鼠标，VoiceOver 用户点不了）
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    override func accessibilityPerformPress() -> Bool {
        toggleByUser()
        return true
    }
}
