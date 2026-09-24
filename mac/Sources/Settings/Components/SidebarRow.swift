import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

final class SidebarRow: NSView {
    typealias Page = SettingsWindowController.Page

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let indicator = NSView()

    let page: Page
    var onClick: ((Page) -> Void)?
    private var theme: VPTheme = .automatic
    private var hovering = false
    var isSelected: Bool = false { didSet { applyState() } }

    init(page: Page, count: String?) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        let symbol = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: nil)
        let configured = symbol?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        iconView.image = configured ?? symbol
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = page.title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.stringValue = count ?? ""
        countLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isHidden = (count ?? "").isEmpty

        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1.5
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.alphaValue = 0

        addSubview(indicator)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -2),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 3),
            indicator.heightAnchor.constraint(equalToConstant: 14),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func updateCount(_ count: String?) {
        countLabel.stringValue = count ?? ""
        countLabel.isHidden = (count ?? "").isEmpty
    }

    func apply(theme: VPTheme) {
        self.theme = theme
        indicator.layer?.setAppearanceBackground(theme.accent)
        applyState()
    }

    private func applyState() {
        let bg: NSColor
        if isSelected {
            bg = theme.sidebarSel
        } else if hovering {
            bg = theme.sidebarHover
        } else {
            bg = .clear
        }
        layer?.setAppearanceBackground(bg)
        iconView.contentTintColor = isSelected ? theme.accent : theme.text3
        titleLabel.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
        titleLabel.textColor = isSelected ? theme.text : theme.text2
        countLabel.textColor = theme.text3
        indicator.alphaValue = isSelected ? 1 : 0
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(page)
    }

    // 辅助功能：整行当一个按钮，读屏和自动化能认出是哪一页并「按下」切过去（原先只认鼠标）
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { titleLabel.stringValue }
    override func isAccessibilitySelected() -> Bool { isSelected }
    override func accessibilityPerformPress() -> Bool {
        onClick?(page)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyState()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyState()
    }
}
