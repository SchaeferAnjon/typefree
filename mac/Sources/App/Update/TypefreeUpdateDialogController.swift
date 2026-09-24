import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

@MainActor
final class TypefreeUpdateDialogController: NSWindowController, NSWindowDelegate {
    private let onPrimary: () -> Void
    private let onSecondary: () -> Void
    private let onClose: () -> Void

    init(model: TypefreeUpdateDialogModel,
         onPrimary: @escaping () -> Void,
         onSecondary: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onClose = onClose

        let isStatusOnly = model.badge == "OK"
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 468, height: isStatusOnly ? 342 : 466),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Typefree 更新"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .white
        window.isMovableByWindowBackground = true
        window.contentView = TypefreeUpdateDialogController.makeContent(model: model)
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = true
        }

        super.init(window: window)
        window.delegate = self
        wireButtons(in: window.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 实时刷新副标题（下载进度 / 安装状态），无需重建整个对话框——避免下载过程中窗口闪烁、丢焦点。
    func applyLiveState(subtitle: String) {
        guard let root = window?.contentView else { return }
        Self.findSubtitle(in: root)?.stringValue = subtitle
    }

    private static func findSubtitle(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField, tf.identifier?.rawValue == "typefree.update.subtitle" { return tf }
        for sub in view.subviews {
            if let found = findSubtitle(in: sub) { return found }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    @objc private func primaryTapped() {
        window?.close()
        onPrimary()
    }

    @objc private func secondaryTapped() {
        window?.close()
        onSecondary()
    }

    private func wireButtons(in view: NSView?) {
        guard let view else { return }
        for subview in view.subviews {
            if let button = subview as? TypefreeUpdateButton {
                switch button.role {
                case .primary:
                    button.target = self
                    button.action = #selector(primaryTapped)
                case .secondary:
                    button.target = self
                    button.action = #selector(secondaryTapped)
                }
            }
            wireButtons(in: subview)
        }
    }

    private static func makeContent(model: TypefreeUpdateDialogModel) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0xFFFFFF).cgColor
        let isStatusOnly = model.badge == "OK"
        let margin: CGFloat = 28

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let logo = makeWaveformMark(box: 30, corner: 8)
        let brand = label("Typefree", size: 13.5, weight: .semibold, color: NSColor(hex: 0x111113))
        header.addSubview(logo)
        header.addSubview(brand)
        let trailingHeaderView: NSView = {
            guard !isStatusOnly else { return brand }
            let badge = makeBadge(model.badge, isError: model.isError)
            header.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 8),
                badge.centerYAnchor.constraint(equalTo: brand.centerYAnchor)
            ])
            return badge
        }()
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 32),
            logo.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            logo.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            brand.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            brand.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            trailingHeaderView.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor)
        ])

        let title = label(model.title, size: 22, weight: .semibold, color: NSColor(hex: 0x111113))
        title.lineBreakMode = .byTruncatingTail
        let subtitle = label(model.subtitle, size: 13, weight: .regular, color: NSColor(hex: 0x686970))
        subtitle.maximumNumberOfLines = 0
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.identifier = NSUserInterfaceItemIdentifier("typefree.update.subtitle")   // 供实时刷新进度定位

        let versionPill = makeVersionPill(model.versionText)

        let notesCard = NSView()
        notesCard.wantsLayer = true
        notesCard.layer?.cornerRadius = 10
        notesCard.layer?.backgroundColor = NSColor(hex: 0xF6F6F7).cgColor
        notesCard.translatesAutoresizingMaskIntoConstraints = false

        let notesTitle = label(model.notesTitle, size: 12.5, weight: .semibold, color: NSColor(hex: 0x333337))
        let notesBody = NSTextField(wrappingLabelWithString: model.notes)
        notesBody.font = .systemFont(ofSize: 12.5, weight: .regular)
        notesBody.textColor = NSColor(hex: 0x66676E)
        notesBody.maximumNumberOfLines = 0
        notesBody.translatesAutoresizingMaskIntoConstraints = false
        // 更新说明按 HTML 富文本渲染（小标题/段落/要点分层，与「更新历史」面板同一套排版）；
        // 之前压成纯文本，一版说明糊成一坨。渲染失败回落纯文本。
        if model.notesIsHTML,
           let attr = ReleaseNotesRenderer.attributed(fromHTML: model.notes,
                                                      bodyColor: NSColor(hex: 0x66676E),
                                                      headingColor: NSColor(hex: 0x1F1F23),
                                                      fontSize: 12.5) {
            notesBody.attributedStringValue = attr
        }

        // 文档视图用翻转坐标（原点在左上）：否则内容超出一屏时 NSScrollView 默认停在底部，
        // 用户第一眼看到的是最后两段。
        let notesDoc = TopAnchoredView()
        notesDoc.translatesAutoresizingMaskIntoConstraints = false
        notesDoc.addSubview(notesBody)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = !isStatusOnly
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = notesDoc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        notesCard.addSubview(notesTitle)
        notesCard.addSubview(scroll)
        NSLayoutConstraint.activate([
            notesCard.heightAnchor.constraint(equalToConstant: isStatusOnly ? 96 : 200),
            notesTitle.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 14),
            notesTitle.topAnchor.constraint(equalTo: notesCard.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: notesTitle.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: notesCard.bottomAnchor, constant: -12),
            // 跟 contentView 而不是 scroll 本身：系统「始终显示滚动条」时滚动条占位，
            // 跟 scroll 等宽会让最右边几个字压在滚动条底下被截掉。
            notesDoc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            notesBody.leadingAnchor.constraint(equalTo: notesDoc.leadingAnchor),
            notesBody.trailingAnchor.constraint(equalTo: notesDoc.trailingAnchor),
            notesBody.topAnchor.constraint(equalTo: notesDoc.topAnchor),
            notesDoc.bottomAnchor.constraint(equalTo: notesBody.bottomAnchor)
        ])

        var secondary: TypefreeUpdateButton?
        if let secondaryTitle = model.secondaryTitle {
            secondary = TypefreeUpdateButton(title: secondaryTitle, role: .secondary)
        }
        let primary = TypefreeUpdateButton(title: model.primaryTitle, role: .primary)
        primary.isEnabled = model.primaryEnabled

        [header, title, subtitle, versionPill, notesCard, primary].forEach(root.addSubview)
        if let secondary {
            root.addSubview(secondary)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),

            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            title.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),

            versionPill.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            versionPill.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),

            notesCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            notesCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            notesCard.topAnchor.constraint(equalTo: versionPill.bottomAnchor, constant: 18),

            primary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            primary.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            primary.widthAnchor.constraint(greaterThanOrEqualToConstant: isStatusOnly ? 96 : 118)
        ])

        if let secondary {
            NSLayoutConstraint.activate([
                secondary.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -10),
                secondary.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
                secondary.widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
            ])
        }

        return root
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func makeBadge(_ text: String, isError: Bool) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        let color = isError ? NSColor(hex: 0xC24545) : (text == "OK" ? NSColor(hex: 0x2E8762) : NSColor(hex: 0xE5484D))
        badge.layer?.backgroundColor = color.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        let textLabel = label(text, size: 9.5, weight: .bold, color: .white)
        textLabel.alignment = .center
        badge.addSubview(textLabel)
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            textLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            textLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            textLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor, constant: -0.5)
        ])
        return badge
    }

    private static func makeVersionPill(_ text: String) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.backgroundColor = NSColor(hex: 0xF2F2F3).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        let label = label(text, size: 12.5, weight: .medium, color: NSColor(hex: 0x3F3F43))
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        return pill
    }

    private static func makeWaveformMark(box: CGFloat, corner: CGFloat) -> NSView {
        let bars: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (11, 10, 37.2, 25.6, 5), (28, 10, 26, 48, 5), (45, 10, 18, 64, 5),
            (62, 10, 29.2, 41.6, 5), (79, 10, 38.8, 22.4, 5)
        ]
        let mark = box * 0.68
        let off = (box - mark) / 2
        let scale = mark / 100.0
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = corner
        view.layer?.backgroundColor = NSColor(hex: 0x111113).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: box),
            view.heightAnchor.constraint(equalToConstant: box)
        ])
        for (x, w, y, h, r) in bars {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.frame = CGRect(x: off + x * scale, y: box - off - (y + h) * scale, width: w * scale, height: h * scale)
            bar.cornerRadius = r * scale
            view.layer?.addSublayer(bar)
        }
        return view
    }
}
