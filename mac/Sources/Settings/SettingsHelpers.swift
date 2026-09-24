import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - Reusable helpers

    func pageHeader(eyebrow: String, title: String, sub: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let eyebrowLbl = label(eyebrow, size: 11, weight: .medium, color: theme.text3)
        let titleLbl = label(title, size: 28, weight: .semibold, color: theme.text)
        let subLbl = label(sub, size: 13, weight: .regular, color: theme.text2)
        subLbl.maximumNumberOfLines = 0
        stack.addArrangedSubview(eyebrowLbl)
        stack.addArrangedSubview(titleLbl)
        stack.addArrangedSubview(subLbl)
        stack.setCustomSpacing(2, after: eyebrowLbl)
        stack.setCustomSpacing(6, after: titleLbl)
        return stack
    }

    enum HeaderButtonStyle { case accent, danger }

    func makePageHeaderRow(eyebrow: String, title: String, sub: String,
                            buttonTitle: String,
                            buttonStyle: HeaderButtonStyle,
                            buttonAction: Selector,
                            secondaryTitle: String? = nil,
                            secondaryAction: Selector? = nil) -> NSView {
        let container = NSView()
        let header = pageHeader(eyebrow: eyebrow, title: title, sub: sub)
        let btn = VPButton(title: buttonTitle,
                           style: (buttonStyle == .accent ? .primary : .danger),
                           theme: theme, target: self, action: buttonAction)
        btn.translatesAutoresizingMaskIntoConstraints = false
        [header, btn].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            btn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            btn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        // 可选「次按钮」（描边样式），放在主按钮左侧。
        if let secondaryTitle = secondaryTitle, let secondaryAction = secondaryAction {
            let sBtn = VPButton(title: secondaryTitle, style: .secondary,
                                theme: theme, target: self, action: secondaryAction)
            sBtn.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(sBtn)
            NSLayoutConstraint.activate([
                sBtn.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8),
                sBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
                header.trailingAnchor.constraint(lessThanOrEqualTo: sBtn.leadingAnchor, constant: -16),
            ])
        } else {
            header.trailingAnchor.constraint(lessThanOrEqualTo: btn.leadingAnchor, constant: -16).isActive = true
        }
        return container
    }

    func sectionTitle(_ text: String) -> NSView {
        let lbl = label(text, size: 12, weight: .semibold, color: theme.text2)
        return lbl
    }

    func makeCard() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.borderWidth = 1
        v.layer?.setAppearanceBorder(theme.sep)
        v.layer?.setAppearanceBackground(theme.card)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func mount(_ body: NSView, in card: NSView) {
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    func makeEmptyState(_ text: String) -> NSView {
        let card = makeCard()
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        let l = label(text, size: 13, weight: .regular, color: theme.text3)
        l.alignment = .center
        l.maximumNumberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            l.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            l.topAnchor.constraint(equalTo: body.topAnchor, constant: 36),
            l.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -36),
        ])
        mount(body, in: card)
        return card
    }

    func makePill(text: String) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.setAppearanceBackground(theme.cardAlt)
        let l = label(text, size: 11, weight: .regular, color: theme.text2)
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 2),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -2),
        ])
        return v
    }

    func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isSelectable = false
        l.alignment = .left
        l.lineBreakMode = .byWordWrapping
        return l
    }

    /// 「标题 + 说明 + 右侧控件」这类行的横向约束：文字列吃掉控件以外的全部宽度，控件按自身宽度靠右。
    /// 折行标签的 preferredMaxLayoutWidth 是 0，固有宽度取的是上一次布局给它的宽度。以前文字列和空白占位的
    /// 拥抱优先级都是 250，谁被拉宽不确定：页面在窗口没定宽时重建（切回 App 触发），标签先被排窄一次，
    /// 之后就拿这个窄宽度当固有宽度，多出来的空间全给了占位，说明被挤成一条窄列。
    /// 这里去掉占位，把标签宽度钉死在文字列上，文字列最低拥抱、控件最高拥抱和抗压，结果和建的时机无关。
    func layoutTextColumn(_ textStack: NSStackView, beside control: NSView) {
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for case let text as NSTextField in textStack.arrangedSubviews {
            text.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// 多行自适应标签（用于历史正文/原文这类可能很长的文本，按真实宽度算高度，不会被截断）。
    func makeWrappingLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> WrappingLabel {
        let l = WrappingLabel(frame: .zero)
        l.isEditable = false
        l.isSelectable = false
        l.isBordered = false
        l.drawsBackground = false
        l.stringValue = text
        l.font = mono ? monoFont(size: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .left
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.cell?.wraps = true
        l.cell?.isScrollable = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    func circle(color: NSColor, size: CGFloat) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.setAppearanceBackground(color)
        v.layer?.cornerRadius = size / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: size),
            v.heightAnchor.constraint(equalToConstant: size),
        ])
        return v
    }

    func makeTextField(_ value: String?, mono: Bool = false) -> NSTextField {
        let f = NSTextField()
        f.stringValue = value ?? ""
        if mono {
            f.font = monoFont(size: 12, weight: .regular)
        }
        return f
    }

    func makeSecureField(_ value: String?) -> NSSecureTextField {
        let f = NSSecureTextField()
        f.stringValue = value ?? ""
        return f
    }

    func isPolishConfigured() -> Bool {
        let provider = config.string(forKey: "polish_provider") ?? "qwen"
        switch provider {
        case "qwen":
            return !(config.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY") ?? "").isEmpty
        case "zhipu":
            return !(config.string(forKey: "zhipu_api_key", envKey: "ZHIPU_API_KEY") ?? "").isEmpty
        case "deepseek":
            return !(config.string(forKey: DeepSeekEndpoint.secretKey, envKey: DeepSeekEndpoint.envKey) ?? "").isEmpty
        case "none":
            return true   // 用户主动选了「不优化」，不是没配置
        default:
            return !(config.string(forKey: "ark_api_key", envKey: "ARK_API_KEY") ?? "").isEmpty
        }
    }

    func quickHistoryLineCount() -> Int {
        historyStore.pruneExpiredEntries()
        guard let data = try? Data(contentsOf: historyStore.fileURL) else { return 0 }
        var count = 0
        for byte in data where byte == 0x0A { count += 1 }
        return count
    }

    /// 把存储的 "2026-05-12 00:55:49" 转成更友好的"今天 00:55" / "昨天 18:32" / "5月10日 14:00"
    func formatHistoryTime(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: raw) else { return raw }

        let timeFormat = DateFormatter()
        timeFormat.dateFormat = "HH:mm"
        let hm = timeFormat.string(from: date)

        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 \(hm)" }
        if cal.isDateInYesterday(date) { return "昨天 \(hm)" }

        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "zh_CN")
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            dayFormat.dateFormat = "M月d日 HH:mm"
        } else {
            dayFormat.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return dayFormat.string(from: date)
    }

    func formatNumber(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func showAlert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.runModal()
    }
}
