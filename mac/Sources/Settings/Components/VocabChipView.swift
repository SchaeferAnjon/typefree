import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - 词库词卡（悬停浮现操作按钮）

final class VocabChipView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var normalBg: NSColor = .clear
    var hoverBg: NSColor = .clear
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.setAppearanceBackground(hoverBg)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.setAppearanceBackground(normalBg)
        onHoverChange?(false)
    }
}
