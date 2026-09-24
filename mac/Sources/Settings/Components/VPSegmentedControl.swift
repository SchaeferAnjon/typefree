import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 自绘分段控件：统一圆角轨道 + 选中「浅底圆角药丸」，匹配设计稿的软填充观感。
/// 原生 NSSegmentedControl 会带系统竖线分隔、白底未选段、抬起式药丸，与设计稿不一致，故自绘。
/// 对外暴露与 NSSegmentedControl 一致的 `selectedSegment` 读写 + target/action。
final class VPSegmentedControl: NSView {
    private var containers: [NSView] = []
    private var itemLabels: [NSTextField] = []
    private let selBg: NSColor
    private let selBorder: NSColor
    private let selText: NSColor
    private let normalText: NSColor

    weak var target: AnyObject?
    var action: Selector?

    var selectedSegment: Int = 0 {
        didSet { restyle() }
    }

    init(labels: [String], trackBg: NSColor, trackBorder: NSColor,
         selBg: NSColor, selBorder: NSColor, selText: NSColor, normalText: NSColor,
         target: AnyObject?, action: Selector?) {
        self.selBg = selBg
        self.selBorder = selBorder
        self.selText = selText
        self.normalText = normalText
        self.target = target
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.setAppearanceBackground(trackBg)
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(trackBorder)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.distribution = .fillEqually   // 三个选项等宽平铺，撑满整个控件宽度
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        for text in labels {
            let c = NSView()
            c.wantsLayer = true
            c.layer?.cornerRadius = 6
            c.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 12.5)
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                l.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
                l.topAnchor.constraint(equalTo: c.topAnchor, constant: 6),
                l.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -6),
            ])
            containers.append(c)
            itemLabels.append(l)
            stack.addArrangedSubview(c)
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func restyle() {
        for (i, c) in containers.enumerated() {
            let on = (i == selectedSegment)
            c.layer?.setAppearanceBackground((on ? selBg : NSColor.clear))
            c.layer?.borderWidth = on ? 1 : 0
            c.layer?.setAppearanceBorder((on ? selBorder : NSColor.clear))
            // 选中药丸加极淡阴影，模拟系统设置里「浮起」的白药丸
            c.layer?.setAppearanceShadow(NSColor.black)
            c.layer?.shadowOpacity = on ? 0.12 : 0
            c.layer?.shadowRadius = 1.5
            c.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
            itemLabels[i].textColor = on ? selText : normalText
            itemLabels[i].font = .systemFont(ofSize: 12.5, weight: on ? .semibold : .regular)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, c) in containers.enumerated() where c.convert(c.bounds, to: self).contains(p) {
            if i != selectedSegment {
                selectedSegment = i
                if let action = action { NSApp.sendAction(action, to: target, from: self) }
            }
            return
        }
    }
}
