import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - 录音浮窗样式预览

/// 录音浮窗样式的「静态缩略图」：按 OverlayWindow 里 SiriCapsuleView 的真实配色，
/// 画一颗定格的小胶囊（不动画、不耗 CPU），让用户在设置里一眼看出两种样式的差别。
final class OverlayStylePreview: NSView {
    private let mono: Bool
    init(mono: Bool) { self.mono = mono; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 50) }

    override func draw(_ dirtyRect: NSRect) {
        let pillW: CGFloat = 116, pillH: CGFloat = 30
        let rect = NSRect(x: (bounds.width - pillW) / 2, y: (bounds.height - pillH) / 2,
                          width: pillW, height: pillH)
        let radius = pillH / 2
        let capsule = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // 1. 胶囊填充：缩略图里两种都画成深色实心（墨黑更黑一点），方便在浅色卡片上辨识。
        (mono ? NSColor(white: 0.03, alpha: 1) : NSColor(white: 0.07, alpha: 1)).setFill()
        capsule.fill()

        // 2. 声波条：定格的钟形波形，裁剪在胶囊内（条数/间距/内缩与真实浮窗一致）。
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        let barCount = 24
        let barSpacing: CGFloat = 1.5
        let barW = (pillW - 12) / CGFloat(barCount) - barSpacing
        let totalW = CGFloat(barCount) * (barW + barSpacing) - barSpacing
        let startX = rect.minX + (pillW - totalW) / 2
        let minH: CGFloat = 2.5
        let maxH = pillH - 9
        for i in 0..<barCount {
            let t = CGFloat(i) / CGFloat(barCount - 1)
            let bell = sin(CGFloat.pi * t)                          // 中间高、两边低
            let wobble = 0.55 + 0.45 * abs(sin(CGFloat(i) * 1.7))   // 固定起伏，制造波形感
            let h = max(minH, minH + (maxH - minH) * bell * wobble)
            let x = startX + CGFloat(i) * (barW + barSpacing)
            let barRect = NSRect(x: x, y: rect.midY - h / 2, width: barW, height: h)
            barColor(t).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // 3. 边框：彩色＝多色渐变环（近似浮窗的旋转 conic，静态）；墨黑＝淡白细边。
        if mono {
            NSColor(white: 1, alpha: 0.16).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
        } else {
            drawColorfulRing(rect: rect, radius: radius)
        }
    }

    /// 波形条颜色：彩色＝粉→紫→蓝插值（同 SiriCapsuleView.barColorLeft/Mid/Right）；墨黑＝白。
    private func barColor(_ t: CGFloat) -> NSColor {
        if mono { return NSColor(white: 1, alpha: 0.92) }
        let pink = NSColor(red: 1.0, green: 0.25, blue: 0.50, alpha: 1)
        let purple = NSColor(red: 0.75, green: 0.20, blue: 0.90, alpha: 1)
        let blue = NSColor(red: 0.30, green: 0.35, blue: 1.00, alpha: 1)
        return t < 0.5 ? lerp(pink, purple, t * 2) : lerp(purple, blue, (t - 0.5) * 2)
    }

    private func lerp(_ a: NSColor, _ b: NSColor, _ k: CGFloat) -> NSColor {
        let a2 = a.usingColorSpace(.sRGB) ?? a
        let b2 = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: a2.redComponent + (b2.redComponent - a2.redComponent) * k,
                       green: a2.greenComponent + (b2.greenComponent - a2.greenComponent) * k,
                       blue: a2.blueComponent + (b2.blueComponent - a2.blueComponent) * k, alpha: 1)
    }

    /// 用一条 2px 环形路径填多色横向渐变，近似浮窗的彩色旋转边框（静态，是与 Mac 实时效果的已知偏差）。
    private func drawColorfulRing(rect: NSRect, radius: CGFloat) {
        let lw: CGFloat = 2
        let ring = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let hole = NSBezierPath(roundedRect: rect.insetBy(dx: lw, dy: lw),
                                xRadius: max(0, radius - lw), yRadius: max(0, radius - lw))
        ring.append(hole.reversed)
        ring.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        ring.addClip()
        let gradient = NSGradient(colors: [
            NSColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1),   // Blue
            NSColor(red: 0.60, green: 0.30, blue: 0.95, alpha: 1),   // Purple
            NSColor(red: 0.95, green: 0.35, blue: 0.60, alpha: 1),   // Pink
            NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1),   // Orange
            NSColor(red: 0.30, green: 0.85, blue: 0.65, alpha: 1),   // Teal
            NSColor(red: 0.35, green: 0.45, blue: 1.00, alpha: 1),   // Blue
        ])
        gradient?.draw(in: bounds, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}
