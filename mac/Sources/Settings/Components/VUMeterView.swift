import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - VU meter (bar style)

final class VUMeterView: NSView {
    private var level: CGFloat = 0  // smoothed, 0...1
    var tint: NSColor = .systemBlue
    private let segmentCount = 7

    override var isFlipped: Bool { false }

    func update(level peak: Float) {
        let target = CGFloat(min(max(peak * 1.4, 0), 1))
        // Smooth rise, faster fall
        if target > level {
            level = level * 0.4 + target * 0.6
        } else {
            level = level * 0.85 + target * 0.15
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let segGap: CGFloat = 3
        let segWidth = (bounds.width - segGap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount)
        let segHeight = bounds.height
        let activeCount = Int(round(level * CGFloat(segmentCount)))
        let inactive = tint.withAlphaComponent(0.18)
        for i in 0..<segmentCount {
            let x = CGFloat(i) * (segWidth + segGap)
            let r = NSRect(x: x, y: 0, width: segWidth, height: segHeight)
            (i < activeCount ? tint : inactive).setFill()
            let path = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
        _ = ctx  // silence unused warning
    }
}
