import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - Page: Explore

    func buildExplore(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 探索", title: "探索",
                                             sub: "发现新的输入和表达方式，按需开启。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeExploreCard(
            id: "translation", title: "语音翻译", summary: "把说出的话翻译成指定语言，直接输入。",
            rows: [makeDefaultOutputLanguageRow(), makeOutputLanguageCommandRow()],
            demo: .translation,
            detailTitle: "语言与口令设置", details: { self.makeOutputLanguageCommandOptions() }
        ))
        stack.addArrangedSubview(makeMouseHoldToTalkCard())
        stack.addArrangedSubview(makeAskHotkeyCard())
    }

    func makeExploreCard(id: String, title: String, summary: String,
                         control: NSView? = nil, rows: [NSView] = [],
                         demo: WhatsNewGuide.Feature? = nil,
                         detailTitle: String = "查看使用方法", details: () -> NSView) -> NSView {
        let card = makeCard()
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        text.addArrangedSubview(label(title, size: 16, weight: .semibold, color: theme.text))
        let desc = label(summary, size: 12.5, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0
        text.addArrangedSubview(desc)
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 20
        header.addArrangedSubview(text)
        if let control {
            header.addArrangedSubview(NSView())
            header.addArrangedSubview(control)
        }
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true

        for row in rows {
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }

        let expanded = expandedExploreCards.contains(id)
        let disclosure = VPButton(title: expanded ? "收起说明" : detailTitle,
                                  style: .secondary, size: .small, theme: theme,
                                  target: self, action: #selector(exploreCardToggled(_:)))
        disclosure.identifier = NSUserInterfaceItemIdentifier(id)
        disclosure.setAccessibilityExpanded(expanded)
        if let demo {
            // 「看演示」放在「查看使用方法」左边：动画比文字说明更直观，想重看随时点
            let demoButton = VPButton(title: "看演示", style: .secondary, size: .small, theme: theme,
                                      target: self, action: #selector(exploreDemoTapped(_:)))
            demoButton.tag = demo.rawValue
            let buttons = NSStackView(views: [demoButton, disclosure])
            buttons.orientation = .horizontal
            buttons.spacing = 8
            column.addArrangedSubview(buttons)
        } else {
            column.addArrangedSubview(disclosure)
        }
        if expanded {
            let body = details()
            column.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }
        mount(column, in: card)
        return card
    }

    func makeExploreHelp(_ text: String) -> NSView {
        let view = label(text, size: 12.5, weight: .regular, color: theme.text2)
        view.maximumNumberOfLines = 0
        return view
    }

    @objc private func exploreDemoTapped(_ sender: NSButton) {
        guard let feature = WhatsNewGuide.Feature(rawValue: sender.tag) else { return }
        presentGuide(feature: feature, finishTitle: "完成", onlyThisFeature: true)
    }

    @objc private func exploreCardToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if expandedExploreCards.contains(id) {
            expandedExploreCards.remove(id)
        } else {
            expandedExploreCards.insert(id)
        }
        invalidate(.explore)
    }

    /// 鼠标长按说话（实验功能）。开关只写配置，监听器每次按下时读取，无需通知重建。
    private func makeMouseHoldToTalkCard() -> NSView {
        let toggle = VPToggle(theme: theme, target: self, action: #selector(mouseHoldToTalkChanged(_:)))
        toggle.setOn(MouseHoldToTalkSettings.isEnabled, animated: false)
        toggle.setAccessibilityLabel("鼠标长按说话")
        return makeExploreCard(id: "mouse", title: "鼠标长按说话",
                               summary: "在输入框里按住鼠标说话，松开后自动输入。", control: toggle, demo: .mouseHold) {
            self.makeExploreHelp("开始说话：在输入框上按住鼠标左键约半秒，松开即结束。\n\n锁定录音：向下拖动，或移到胶囊内及边缘附近。绿光亮起后松手继续说，点 ✓ 完成、× 取消。\n\n拖开取消：按住鼠标拖远，红光亮起后松手取消；移回胶囊可恢复锁定。锁定后，也可重新按住胶囊向外拖动取消。普通移动鼠标不会取消录音。\n\n微信：仅在聊天主窗口底部输入区域的左半部分生效，会接管微信自带的按住语音输入。触控板不建议开启。")
        }
    }

    // MARK: 输出语言

    /// 默认输出语言：不管说什么语言都翻成它。开着时录音胶囊常驻语言标签，说口令可临时切换。
    private func makeDefaultOutputLanguageRow() -> NSView {
        let title = label("默认输出语言", size: 13, weight: .medium, color: theme.text)
        let desc = label("固定翻译成一种语言，或选择跟随说话语言。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        var items: [VPDropdown.Item] = [VPDropdown.Item(value: "", title: "跟随说话语言")]
        for language in OutputLanguage.configured() where language.enabled {
            items.append(VPDropdown.Item(value: language.id, title: language.name))
        }
        let current = config.string(forKey: OutputLanguage.defaultConfigKey) ?? ""
        let popup = VPDropdown(items: items, selectedValue: items.contains { $0.value == current } ? current : "",
                               trackBg: theme.card,
                               trackBorder: Self.dropdownBorder,
                               textColor: theme.text, chevronColor: theme.text3)
        popup.onSelect = { [weak self] value in
            self?.config.save(value: value, forKey: OutputLanguage.defaultConfigKey)
        }
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        layoutTextColumn(textStack, beside: popup)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.distribution = .fill
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(popup)
        return row
    }

    private func makeOutputLanguageCommandRow() -> NSView {
        let title = label("语音口令", size: 13, weight: .medium, color: theme.text)
        let desc = label("说「用英文」或「翻译成日文」，临时切换本次输出。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0
        let master = VPToggle(theme: theme, target: self, action: #selector(outputLanguageCommandEnabledChanged(_:)))
        master.setOn(config.bool(forKey: OutputLanguage.commandEnabledConfigKey, defaultValue: true), animated: false)
        master.setAccessibilityLabel("语音口令")
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        layoutTextColumn(textStack, beside: master)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.distribution = .fill
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(master)
        return row
    }

    /// 语言开关、触发词和添加语言沿用原配置，默认收起。
    private func makeOutputLanguageCommandOptions() -> NSView {
        outputLanguagePhraseFields = [:]
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        let help = makeExploreHelp("在句首或句尾加上口令，这一次就用指定语言输出。句首说完口令后稍停一下。开启固定语言时，胶囊会显示对应语言标签。翻译需要开启 AI 润色。")
        column.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // 语言：一排小圆片，黑底 = 开着，点一下切换
        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 8
        let chipLabel = label("语言", size: 12.5, weight: .medium, color: theme.text3)
        chipLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        chips.addArrangedSubview(chipLabel)
        let languages = OutputLanguage.configured()
        for language in languages {
            let chip = VPButton(title: language.name, style: language.enabled ? .primary : .secondary, size: .small, theme: theme,
                                target: self, action: #selector(outputLanguageChipTapped(_:)))
            chip.identifier = NSUserInterfaceItemIdentifier(language.id)
            chip.toolTip = "说「\(language.phrases.first ?? "用" + language.name)」这一句就用\(language.name)输出"
            chips.addArrangedSubview(chip)
        }
        column.addArrangedSubview(chips)

        // 高级：自定义触发词 / 添加语言，默认收起
        let disclosure = VPButton(title: outputLanguageAdvancedExpanded ? "收起自定义触发词" : "自定义触发词…", style: .secondary, size: .small, theme: theme,
                                  target: self, action: #selector(outputLanguageAdvancedToggled))
        column.addArrangedSubview(disclosure)

        if outputLanguageAdvancedExpanded {
            for language in languages {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 10
                let name = label(language.name, size: 12.5, weight: .medium, color: theme.text2)
                name.widthAnchor.constraint(equalToConstant: 64).isActive = true
                let field = makeTextField(language.phrases.joined(separator: "，"))
                field.font = .systemFont(ofSize: 12)
                field.placeholderString = "触发词，用逗号分隔"
                field.identifier = NSUserInterfaceItemIdentifier("olang:" + language.id)
                field.delegate = self
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
                outputLanguagePhraseFields[language.id] = field
                row.addArrangedSubview(name)
                row.addArrangedSubview(field)
                if !language.isBuiltin {
                    let remove = VPButton(title: "移除", style: .secondary, size: .small, theme: theme,
                                          target: self, action: #selector(outputLanguageRemoveTapped(_:)))
                    remove.identifier = NSUserInterfaceItemIdentifier(language.id)
                    row.addArrangedSubview(remove)
                }
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }

            let addRow = NSStackView()
            addRow.orientation = .horizontal
            addRow.alignment = .centerY
            addRow.spacing = 10
            let addLabel = label("添加语言", size: 12.5, weight: .medium, color: theme.text3)
            addLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let nameField = makeTextField("")
            nameField.font = .systemFont(ofSize: 12)
            nameField.placeholderString = "语言名，如 泰语"
            nameField.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let phrasesField = makeTextField("")
            phrasesField.font = .systemFont(ofSize: 12)
            phrasesField.placeholderString = "触发词，不填则用「用泰语、翻译成泰语」"
            phrasesField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let addButton = VPButton(title: "添加", style: .secondary, size: .small, theme: theme,
                                     target: self, action: #selector(outputLanguageAddTapped))
            outputLanguageAddNameField = nameField
            outputLanguageAddPhrasesField = phrasesField
            addRow.addArrangedSubview(addLabel)
            addRow.addArrangedSubview(nameField)
            addRow.addArrangedSubview(phrasesField)
            addRow.addArrangedSubview(addButton)
            column.addArrangedSubview(addRow)
            addRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        return column
    }

    @objc private func outputLanguageCommandEnabledChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: OutputLanguage.commandEnabledConfigKey)
    }

    @objc private func outputLanguageChipTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var list = OutputLanguage.configured()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].enabled.toggle()
        OutputLanguage.save(list)
        // 默认语言被关掉了 → 回到跟随
        if !list[index].enabled, config.string(forKey: OutputLanguage.defaultConfigKey) == id {
            config.save(value: "", forKey: OutputLanguage.defaultConfigKey)
        }
        invalidate(.explore)
    }

    @objc private func outputLanguageAdvancedToggled() {
        outputLanguageAdvancedExpanded.toggle()
        invalidate(.explore)
    }

    func saveOutputLanguagePhrases(id: String, text: String) {
        var list = OutputLanguage.configured()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let phrases = OutputLanguage.parsePhrases(text)
        guard phrases != list[index].phrases else { return }
        list[index].phrases = phrases
        OutputLanguage.save(list)
    }

    @objc private func outputLanguageRemoveTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var list = OutputLanguage.configured()
        list.removeAll { $0.id == id }
        OutputLanguage.save(list)
        if config.string(forKey: OutputLanguage.defaultConfigKey) == id {
            config.save(value: "", forKey: OutputLanguage.defaultConfigKey)
        }
        invalidate(.explore)
    }

    @objc private func outputLanguageAddTapped() {
        let name = (outputLanguageAddNameField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var phrases = OutputLanguage.parsePhrases(outputLanguageAddPhrasesField?.stringValue ?? "")
        if phrases.isEmpty { phrases = ["用\(name)", "翻译成\(name)", "翻成\(name)", "\(name)输出"] }
        var list = OutputLanguage.configured()
        list.append(OutputLanguage.makeCustom(name: name, phrases: phrases))
        OutputLanguage.save(list)
        invalidate(.explore)
    }

    @objc private func mouseHoldToTalkChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: MouseHoldToTalkSettings.enabledKey)
    }
}
