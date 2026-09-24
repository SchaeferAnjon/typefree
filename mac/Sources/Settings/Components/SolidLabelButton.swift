import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - 墨黑自绘按钮（无边框、圆角实心、文字色固定）

/// 用于定价页激活按钮：墨黑底白字、圆角无边框。
/// 关键点——激活流程会直接改 `.title`（"激活中…"/"激活"），普通 NSButton 那会丢掉颜色变黑底黑字看不见；
/// 这里重写 `title` 的赋值，始终把文字重新包成固定色，激活逻辑无需改动。
final class SolidLabelButton: NSButton {
    private let titleColor: NSColor

    init(title: String, color: NSColor, target: AnyObject?, action: Selector?) {
        self.titleColor = color
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 9
        font = .systemFont(ofSize: 13, weight: .semibold)
        self.title = title   // 触发 didSet，套上固定色
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String {
        didSet {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: titleColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ])
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
