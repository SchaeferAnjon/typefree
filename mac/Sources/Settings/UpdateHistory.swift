import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - 更新历史

    /// 「更新历史」面板：从 appcast 拉取各版本的发布日期与更新说明。
    /// 数据源就是 Sparkle 用的那份 appcast，不额外维护更新日志文件。
    @objc func showUpdateHistory() {
        guard let window = window else { return }
        let panel = makeUpdateHistoryPanel()
        historyUpdateSheet = panel
        window.beginSheet(panel) { [weak self] _ in self?.historyUpdateSheet = nil }
        loadUpdateHistory()
    }

    private func makeUpdateHistoryPanel() -> NSWindow {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "更新历史"

        let root = NSView()
        root.wantsLayer = true
        root.layer?.setAppearanceBackground(theme.bg)

        let heading = label("更新历史", size: 17, weight: .semibold, color: theme.text)
        let sub = label("当前版本 \(Bundle.main.appVersionString)", size: 12, weight: .regular, color: theme.text3)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22                 // 版本块之间（分隔线两侧各占一半）
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        updateHistoryStack = stack

        let close = VPButton(title: "关闭", style: .secondary, size: .regular,
                             theme: theme, target: self, action: #selector(closeUpdateHistory))

        for v in [heading, sub, scroll, close] { root.addSubview(v) }
        [heading, sub, close].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            sub.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            sub.leadingAnchor.constraint(equalTo: heading.leadingAnchor),

            // 宽度钉在滚动区上（而不是 contentView 上）：给 window.contentView 加尺寸约束
            // 会和系统的 autoresizing 冲突而被丢弃，面板就会被长段落文字的固有宽度撑爆。
            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            scroll.widthAnchor.constraint(equalToConstant: updateHistoryScrollWidth),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -18),

            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        panel.contentView = root
        panel.setContentSize(NSSize(width: updateHistoryScrollWidth + 60, height: 560))
        return panel
    }

    /// 更新历史面板的滚动区宽度；面板总宽 = 它 + 左右各 24 边距。
    private var updateHistoryScrollWidth: CGFloat { 540 }

    @objc private func closeUpdateHistory() {
        guard let sheet = historyUpdateSheet else { return }
        window?.endSheet(sheet)
    }

    private func loadUpdateHistory() {
        setUpdateHistoryMessage("正在获取…")
        guard let url = URL(string: AppLinks.appcastURL) else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData   // 刚发的版本要能立刻看到
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let xml = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let entries = AppcastParser.parse(xml)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if entries.isEmpty {
                    self.setUpdateHistoryMessage("暂时获取不到更新历史，请检查网络后重试。")
                } else {
                    self.renderUpdateHistory(entries)
                }
            }
        }.resume()
    }

    private func setUpdateHistoryMessage(_ text: String) {
        guard let stack = updateHistoryStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let l = label(text, size: 12.5, weight: .regular, color: theme.text3)
        l.maximumNumberOfLines = 0
        stack.addArrangedSubview(l)
    }

    /// 正文折行宽度：滚动区宽度再留出竖向滚动条的位置。
    private var updateHistoryContentWidth: CGFloat { updateHistoryScrollWidth - 16 }

    private func renderUpdateHistory(_ entries: [AppcastEntry]) {
        guard let stack = updateHistoryStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let contentWidth = updateHistoryContentWidth

        let df = DateFormatter()
        df.dateFormat = "yyyy年M月d日"
        df.locale = Locale(identifier: "zh_CN")
        let current = Bundle.main.appVersionString

        for (idx, e) in entries.enumerated() {
            // 版本之间加一条细分隔线，避免整页糊成一片
            if idx > 0 {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.setAppearanceBackground(theme.sep)
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                NSLayoutConstraint.activate([
                    sep.heightAnchor.constraint(equalToConstant: 1),
                    sep.widthAnchor.constraint(equalTo: stack.widthAnchor),
                ])
            }

            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 10                       // 版本号与正文之间留出呼吸
            row.translatesAutoresizingMaskIntoConstraints = false

            let head = NSStackView()
            head.orientation = .horizontal
            head.alignment = .centerY
            head.spacing = 10
            head.addArrangedSubview(label(e.version, size: 16, weight: .semibold, color: theme.text))
            if let d = e.pubDate {
                head.addArrangedSubview(label(df.string(from: d), size: 11.5, weight: .regular, color: theme.text3))
            }
            if e.version == current {
                head.addArrangedSubview(makeSoftTag("当前版本"))
            }
            row.addArrangedSubview(head)

            let body = NSTextField(labelWithString: "")
            body.maximumNumberOfLines = 0
            body.lineBreakMode = .byWordWrapping
            body.preferredMaxLayoutWidth = contentWidth        // 有它才知道在哪儿折行
            body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            body.setContentHuggingPriority(.defaultLow, for: .horizontal)
            body.translatesAutoresizingMaskIntoConstraints = false
            if e.notesHTML.isEmpty {
                body.stringValue = "这一版没有留下更新说明。"
                body.font = .systemFont(ofSize: 12.5)
                body.textColor = theme.text3
            } else if let attr = Self.attributedNotes(fromHTML: e.notesHTML,
                                                      bodyColor: theme.text2, headingColor: theme.text) {
                body.attributedStringValue = attr
            } else {
                body.stringValue = e.notesHTML
                body.font = .systemFont(ofSize: 12.5)
                body.textColor = theme.text2
            }
            row.addArrangedSubview(body)

            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            body.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
    }

    /// 更新说明是 HTML（appcast 的 CDATA），交给 ReleaseNotesRenderer 渲染成富文本（与「发现新版本」弹窗共用同一套排版）；
    /// 失败则由调用方回落纯文本。
    private static func attributedNotes(fromHTML html: String,
                                        bodyColor: NSColor, headingColor: NSColor) -> NSAttributedString? {
        guard let rendered = ReleaseNotesRenderer.attributed(fromHTML: html, bodyColor: bodyColor,
                                                             headingColor: headingColor) else { return nil }
        // CSS 里的颜色是按当时的浅色写死的；换回主题动态色，主窗口深色时也看得清（浅色下解析出来还是原来的颜色）。
        // 只在主窗口这里换，「发现新版本」弹窗那条路不动。
        let notes = NSMutableAttributedString(attributedString: rendered)
        let headingHex = headingColor.cssHex
        notes.enumerateAttributes(in: NSRange(location: 0, length: notes.length)) { attributes, range, _ in
            guard attributes[.link] == nil, let imported = attributes[.foregroundColor] as? NSColor else { return }
            notes.addAttribute(.foregroundColor, value: imported.cssHex == headingHex ? headingColor : bodyColor, range: range)
        }
        return notes
    }
}
