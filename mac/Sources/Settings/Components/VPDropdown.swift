import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 自绘下拉选择控件：外观与 VPSegmentedControl 同一套（浅灰轨道底 + 深边框 + 墨黑文字），
/// 点开用 NSMenu 呈现选项（当前项打勾、统一 13 号字）。用于选项多到横排放不下的场景（如润色模型）。
final class VPDropdown: NSControl {
    /// `warn` = 该项处于需要注意的状态（如免费额度已用完）：
    /// 收起时若选中项 warn，标题用 warnColor（红）提示"要动手"；菜单里则用弱化色，避免满屏红。
    struct Item { let value: String; let title: String; var warn: Bool = false }

    private let titleLabel: NSTextField
    private let menuTextColor: NSColor
    private let menuWarnColor: NSColor
    private let normalTextColor: NSColor
    private let selectedWarnColor: NSColor
    private var items: [Item]
    private(set) var selectedValue: String
    var onSelect: ((String) -> Void)?

    init(items: [Item], selectedValue: String,
         trackBg: NSColor, trackBorder: NSColor, textColor: NSColor, chevronColor: NSColor,
         warnColor: NSColor? = nil, mutedColor: NSColor? = nil) {
        self.items = items
        self.selectedValue = selectedValue
        self.menuTextColor = textColor
        self.menuWarnColor = mutedColor ?? chevronColor
        self.normalTextColor = textColor
        self.selectedWarnColor = warnColor ?? textColor
        let current = items.first { $0.value == selectedValue }
        self.titleLabel = NSTextField(labelWithString: current?.title ?? selectedValue)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.setAppearanceBackground(trackBg)
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(trackBorder)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = (current?.warn == true) ? (warnColor ?? textColor) : textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 系统箭头图标（与原生控件同款），比文字符号更协调
        let chevron = NSImageView()
        if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            chevron.image = img.withSymbolConfiguration(
                .init(pointSize: 9.5, weight: .semibold))
            chevron.contentTintColor = chevronColor
        }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.minimumWidth = bounds.width
        for item in items {
            let mi = NSMenuItem(title: "", action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item.value
            mi.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: item.warn ? menuWarnColor : menuTextColor])
            mi.state = (item.value == selectedValue) ? .on : .off
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        setSelectedValue(value)
        onSelect?(value)
    }

    /// 改显示的选中项（不触发 onSelect）。别处改了同一个设置时用来同步
    func setSelectedValue(_ value: String) {
        selectedValue = value
        let picked = items.first { $0.value == value }
        titleLabel.stringValue = picked?.title ?? value
        titleLabel.textColor = (picked?.warn == true) ? selectedWarnColor : normalTextColor
    }
}
