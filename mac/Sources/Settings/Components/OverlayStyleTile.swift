import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 可点选的浮窗样式磁贴：上方静态预览 + 下方标题；选中时描强调色粗边。
final class OverlayStyleTile: NSView {
    let mono: Bool
    private let theme: VPTheme
    var onSelect: (() -> Void)?

    init(mono: Bool, title: String, theme: VPTheme) {
        self.mono = mono
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.setAppearanceBackground(theme.cardAlt)
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(theme.sep)

        let preview = OverlayStylePreview(mono: mono)
        preview.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = theme.text
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(preview)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            preview.centerXAnchor.constraint(equalTo: centerXAnchor),
            preview.widthAnchor.constraint(equalToConstant: 148),
            preview.heightAnchor.constraint(equalToConstant: 50),
            titleLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 10),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        layer?.setAppearanceBorder((selected ? theme.accent : theme.sep))
        layer?.borderWidth = selected ? 2 : 1
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
