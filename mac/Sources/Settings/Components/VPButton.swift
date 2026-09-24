import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 全 App 统一的自绘按钮：固定高度 / 圆角 / 字重，带顺滑悬停反馈，替代散落各处的系统 .rounded 按钮。
/// 4 种样式：主操作实心(primary) / 次操作描边(secondary) / 危险操作(danger) / 图标(icon)。
/// 2 种尺寸：regular(高 30) / small(高 26，用于卡片内行内操作)。
final class VPButton: NSButton {
    enum Style { case primary, secondary, danger, icon }
    enum Size { case regular, small }

    private let style: Style
    private let size: Size
    private let titleColor: NSColor
    private let bgNormal: NSColor
    private let bgHover: NSColor
    private var hovering = false

    init(title: String, style: Style, size: Size = .regular, theme: VPTheme,
                     target: AnyObject?, action: Selector?) {
        self.style = style
        self.size = size
        switch style {
        case .primary:
            titleColor = theme.onAccent
            bgNormal = theme.accent
            bgHover = theme.accent.appearanceBlended(withFraction: 0.16, of: theme.onAccent)
        case .secondary:
            titleColor = theme.text
            bgNormal = theme.card
            bgHover = theme.cardAlt
        case .danger:
            titleColor = theme.danger
            bgNormal = theme.card
            bgHover = theme.danger.withAlphaComponent(0.07)
        case .icon:
            titleColor = theme.text3
            bgNormal = .clear
            bgHover = theme.cardAlt
        }
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = (style == .icon) ? 7 : 8
        switch style {
        case .secondary:
            layer?.borderWidth = 1
            layer?.setAppearanceBorder(theme.text.withAlphaComponent(0.14))
        case .danger:
            layer?.borderWidth = 1
            layer?.setAppearanceBorder(theme.danger.withAlphaComponent(0.32))
        default:
            layer?.borderWidth = 0
        }
        self.title = title   // 触发 didSet 套字色
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var fontSize: CGFloat { size == .regular ? 13 : 12 }
    private var fixedHeight: CGFloat { size == .regular ? 30 : 26 }
    private var hPadding: CGFloat { size == .regular ? 14 : 12 }

    override var title: String {
        didSet {
            let p = NSMutableParagraphStyle(); p.alignment = .center
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: titleColor,
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .paragraphStyle: p,
            ])
        }
    }

    override var intrinsicContentSize: NSSize {
        if style == .icon { return NSSize(width: fixedHeight, height: fixedHeight) }
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + hPadding * 2, height: fixedHeight)
    }

    private func updateBackground() {
        layer?.setAppearanceBackground((hovering ? bgHover : bgNormal))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateBackground() }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
