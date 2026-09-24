import Cocoa
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 首页「节律」：近 6 周一行圆点，说得越多点越大越深（问 AI 同款蓝，给首页添点颜色）；没说的是一个小空圈；
/// 周一处一道细线；今天一圈描边。鼠标停在哪天，右下角就写出那天的日期、字数、次数（系统 tooltip 在这里不可靠，自己画）。
final class RhythmStripView: NSView {
    /// 与问 AI 面板同一个蓝（刻意的，不跟随主题强调色）
    static let accent = NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
    private var days: [ActivityRhythm.Day] = []
    private var theme: VPTheme = .automatic
    private let rowHeight: CGFloat = 64
    private let labelHeight: CGFloat = 16
    private let maxDot: CGFloat = 26
    private let minDot: CGFloat = 8
    private var hoverIndex: Int?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: rowHeight + labelHeight) }

    func apply(days: [ActivityRhythm.Day], theme: VPTheme) {
        self.days = days
        self.theme = theme
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !days.isEmpty, bounds.width > 0, p.y <= rowHeight else { setHover(nil); return }
        let slot = bounds.width / CGFloat(days.count)
        let i = Int(p.x / slot)
        setHover((0..<days.count).contains(i) ? i : nil)
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func setHover(_ i: Int?) {
        guard i != hoverIndex else { return }
        hoverIndex = i
        needsDisplay = true
    }

    private func hoverText(_ d: ActivityRhythm.Day) -> String {
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        let label = Self.dayLabel(d.date)
        return d.chars > 0 ? "\(label) · \(nf.string(from: NSNumber(value: d.chars)) ?? "\(d.chars)") 字 · \(d.sessions) 次" : "\(label) · 没有使用"
    }

    private static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return key }
        return "\(m)月\(d)日"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let slot = bounds.width / CGFloat(days.count)
        let maxChars = max(days.map(\.chars).max() ?? 0, 1)
        let cy = rowHeight / 2

        for (i, d) in days.enumerated() {
            let cx = slot * (CGFloat(i) + 0.5)
            // 周一处一道细分隔线（第一列不画）
            if d.weekday == 2 && i > 0 {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: CGFloat(i) * slot, y: 10))
                line.line(to: NSPoint(x: CGFloat(i) * slot, y: rowHeight - 10))
                theme.sep.setStroke()
                line.lineWidth = 1
                line.stroke()
            }
            if d.chars == 0 {
                let r: CGFloat = 3
                let ring = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                theme.cardAlt.setFill(); ring.fill()
                theme.sep.setStroke(); ring.lineWidth = 1; ring.stroke()
            } else {
                // 开平方：一天特别多字时，其他正常的日子不至于都缩成小点
                let t = sqrt(CGFloat(d.chars) / CGFloat(maxChars))
                let size = minDot + t * (maxDot - minDot)
                let dot = NSBezierPath(ovalIn: NSRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
                Self.accent.withAlphaComponent(0.28 + 0.72 * t).setFill()
                dot.fill()
            }
            if d.isToday || i == hoverIndex {
                let r = (d.chars == 0 ? 3 : (minDot + sqrt(CGFloat(d.chars) / CGFloat(maxChars)) * (maxDot - minDot)) / 2) + 3.5
                let ring = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                (d.isToday ? Self.accent : theme.text3).setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }

        // 周标签：按周一分组（和分隔线对齐），每组居中写一个；含今天的最后一组「本周」。
        // 最左边那组可能不满 7 天，放不下标签就不写
        var groups: [Range<Int>] = []
        var start = 0
        for (i, d) in days.enumerated() where d.weekday == 2 && i > 0 {
            groups.append(start..<i)
            start = i
        }
        groups.append(start..<days.count)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.text3]
        for (g, range) in groups.enumerated() {
            let text = g == groups.count - 1 ? "本周" : "\(groups.count - 1 - g) 周前"
            let s = NSAttributedString(string: text, attributes: attrs)
            let width = s.size().width
            let groupW = slot * CGFloat(range.count)
            guard width <= groupW else { continue }
            let x = slot * CGFloat(range.lowerBound) + (groupW - width) / 2
            s.draw(at: NSPoint(x: x, y: rowHeight + 1))
        }

        // 悬停信息：写在周标签那一行的右端
        if let h = hoverIndex, h < days.count {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: theme.text]
            let s = NSAttributedString(string: hoverText(days[h]), attributes: attrs)
            let w = s.size().width
            let bg = NSRect(x: bounds.width - w - 12, y: rowHeight - 2, width: w + 12, height: labelHeight + 4)
            theme.card.setFill(); bg.fill()   // 盖住底下的周标签
            s.draw(at: NSPoint(x: bounds.width - w, y: rowHeight + 1))
        }
    }
}
