import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

final class TypefreeUpdateButton: NSButton {
    enum Role { case primary, secondary }

    let role: Role
    private var hovering = false

    init(title: String, role: Role) {
        self.role = role
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyStyle()
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func applyStyle() {
        let titleColor: NSColor
        let background: NSColor
        let border: NSColor
        if !isEnabled {
            titleColor = NSColor(hex: 0xA0A1A7)
            background = NSColor(hex: 0xEFEFF0)
            border = .clear
        } else {
            switch role {
            case .primary:
                titleColor = .white
                background = hovering ? NSColor(hex: 0x303033) : NSColor(hex: 0x111113)
                border = .clear
            case .secondary:
                titleColor = NSColor(hex: 0x242428)
                background = hovering ? NSColor(hex: 0xF2F2F3) : .white
                border = NSColor.black.withAlphaComponent(0.14)
            }
        }

        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: titleColor
        ])
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = role == .secondary && isEnabled ? 1 : 0
    }
}
