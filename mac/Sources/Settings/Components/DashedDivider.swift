import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - Dashed divider

final class DashedDivider: NSView {
    var color: NSColor = .separatorColor

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: CGPoint(x: 0, y: bounds.midY))
        ctx.addLine(to: CGPoint(x: bounds.width, y: bounds.midY))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
