import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    private func makeAutoLearnCard() -> NSView {
        let card = makeCard()

        let title = label("自动学习（词汇与风格）", size: 14, weight: .medium, color: theme.text)
        let desc = label("根据你的日常输入自动学习常用词汇和表达习惯，越用越懂你。学到的词在下方列表可随时删除，删过的不再学。", size: 12, weight: .regular, color: theme.text3)

        let toggle = VPToggle(theme: theme, target: self, action: #selector(autoLearnChanged(_:)))
        toggle.setOn(config.bool(forKey: "term_corrections_auto_learn_enabled", defaultValue: true), animated: false)
        autoLearnCheckbox = toggle

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        layoutTextColumn(textStack, beside: toggle)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    @objc private func autoLearnChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: "term_corrections_auto_learn_enabled")
    }

    // MARK: - Page: Vocabulary

    func buildVocab(into stack: NSStackView) {
        loadVocabularyEntries()

        let header = pageHeader(
            eyebrow: "TYPEFREE / 个人词库",
            title: "个人词库",
            sub: "添加你常说的人名、产品名、专有名词，语音识别会优先认出它们。你改过的错词也会自动学进来。"
        )
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(20, after: header)

        // 快速添加：输入框回车即加，不弹窗
        let quickAdd = makeVocabQuickAddRow()
        stack.addArrangedSubview(quickAdd)
        stack.setCustomSpacing(20, after: quickAdd)

        // 词条网格（含筛选）
        if vocabularyEntries.isEmpty {
            let empty = makeEmptyState("还没有词。在上面输入一个常说的人名、产品名试试。")
            stack.addArrangedSubview(empty)
            stack.setCustomSpacing(20, after: empty)
        } else {
            let seg = VPSegmentedControl(
                labels: ["所有", "自动学习", "手动添加"],
                trackBg: theme.cardAlt,
                trackBorder: theme.sep,
                selBg: theme.segSelBg,
                selBorder: theme.sep,
                selText: theme.text,
                normalText: theme.text2,
                target: self,
                action: #selector(vocabFilterChanged(_:)))
            seg.selectedSegment = vocabFilter
            seg.widthAnchor.constraint(equalToConstant: 280).isActive = true
            stack.addArrangedSubview(seg)
            stack.setCustomSpacing(14, after: seg)

            let visible: [(index: Int, entry: VocabularyEntry)] = vocabularyEntries.enumerated()
                .filter { item in
                    switch vocabFilter {
                    case 1: return item.element.isAutoLearned
                    case 2: return !item.element.isAutoLearned
                    default: return true
                    }
                }
                .map { (index: $0.offset, entry: $0.element) }

            if visible.isEmpty {
                let empty = label(vocabFilter == 1 ? "还没有自动学到的词。" : "还没有手动添加的词。",
                                  size: 13, weight: .regular, color: theme.text3)
                stack.addArrangedSubview(empty)
                stack.setCustomSpacing(20, after: empty)
            } else {
                let grid = makeVocabGrid(visible)
                stack.addArrangedSubview(grid)
                stack.setCustomSpacing(20, after: grid)
            }
        }

        // 词库相关开关
        let autoLearn = makeAutoLearnCard()
        stack.addArrangedSubview(autoLearn)
        stack.setCustomSpacing(8, after: autoLearn)
        stack.addArrangedSubview(makeBuiltinHotWordsCard())
    }

    @objc private func vocabFilterChanged(_ sender: VPSegmentedControl) {
        vocabFilter = sender.selectedSegment
        invalidate(.vocabulary)
    }

    // MARK: 快速添加

    private func makeVocabQuickAddRow() -> NSView {
        let field = NSTextField()
        field.placeholderString = "输入常说的词，回车添加"
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(vocabQuickAddSubmitted)
        if let cell = field.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false   // 只在回车时触发，失焦不误加
        }
        vocabQuickAddField = field

        // 系统默认 bezel 太淡，包进圆角容器自己画明显的边框（与反馈输入框同做法、边框更深）
        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = 8
        fieldWrap.layer?.borderWidth = 1.5
        fieldWrap.layer?.setAppearanceBorder(theme.text3)
        fieldWrap.layer?.setAppearanceBackground(theme.card)
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
            fieldWrap.heightAnchor.constraint(equalToConstant: 32),
        ])

        let addBtn = VPButton(title: "添加词汇", style: .primary, size: .regular,
                              theme: theme, target: self, action: #selector(vocabQuickAddSubmitted))
        addBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(fieldWrap)
        row.addArrangedSubview(addBtn)
        fieldWrap.widthAnchor.constraint(equalToConstant: 340).isActive = true
        addBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true

        // 包一层让整行靠左、不被拉伸
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    @objc private func vocabQuickAddSubmitted() {
        guard let field = vocabQuickAddField else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        field.stringValue = ""
        // 已有同名词条就不重复加（输入框已清空，效果上等于"已收录"）
        if vocabularyEntries.contains(where: { $0.target.caseInsensitiveCompare(word) == .orderedSame }) {
            return
        }
        vocabularyEntries.insert(
            VocabularyEntry(target: word, variants: [], category: "其他", source: "manual"),
            at: 0
        )
        saveVocabularyEntries()
        rebuildSidebar()
        invalidate(.vocabulary)
        // 页面重建后把焦点放回输入框，方便连续添加
        DispatchQueue.main.async { [weak self] in
            guard let self, let newField = self.vocabQuickAddField else { return }
            self.window?.makeFirstResponder(newField)
        }
    }

    // MARK: 词条网格

    /// 3 列网格，参考竞品排版：词卡 = 来源图标 + 词，悬停浮现「错法/删除」操作
    private func makeVocabGrid(_ items: [(index: Int, entry: VocabularyEntry)]) -> NSView {
        let columns = 3
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        var rowStart = 0
        while rowStart < items.count {
            let rowItems = Array(items[rowStart..<min(rowStart + columns, items.count)])
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 10
            for item in rowItems {
                row.addArrangedSubview(makeVocabChip(entry: item.entry, originalIndex: item.index))
            }
            // 末行不足 3 个时用占位补齐，保持卡片等宽
            for _ in rowItems.count..<columns {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(filler)
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            rowStart += columns
        }
        return grid
    }

    private func makeVocabChip(entry: VocabularyEntry, originalIndex: Int) -> NSView {
        let chip = VocabChipView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 10
        chip.layer?.borderWidth = 1
        chip.layer?.setAppearanceBorder(theme.sep)
        chip.layer?.setAppearanceBackground(theme.card)
        chip.normalBg = theme.card
        chip.hoverBg = theme.cardAlt
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: entry.isAutoLearned ? "sparkles" : "pencil",
                             accessibilityDescription: entry.isAutoLearned ? "自动学习" : "手动添加")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.contentTintColor = theme.text3
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let word = label(entry.target, size: 13, weight: .medium, color: theme.text)
        word.lineBreakMode = .byTruncatingTail
        word.maximumNumberOfLines = 1
        word.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 已记录错法数的弱提示（悬停时让位给操作按钮）
        let hint: NSTextField? = entry.variants.isEmpty
            ? nil
            : label("\(entry.variants.count) 个错法", size: 10.5, weight: .regular, color: theme.text3)

        let variantsBtn = makeChipIconButton(symbol: "character.cursor.ibeam",
                                             tooltip: "管理常见错法",
                                             action: #selector(manageVariantsTapped(_:)),
                                             tag: originalIndex)
        let deleteBtn = makeChipIconButton(symbol: "trash",
                                           tooltip: "删除",
                                           action: #selector(deleteVocabularyEntry(_:)),
                                           tag: originalIndex)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(variantsBtn)
        actions.addArrangedSubview(deleteBtn)
        actions.isHidden = true

        chip.onHoverChange = { [weak actions, weak hint] hovering in
            actions?.isHidden = !hovering
            hint?.isHidden = hovering
        }

        let inner = NSStackView()
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 8
        inner.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        inner.addArrangedSubview(icon)
        inner.addArrangedSubview(word)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inner.addArrangedSubview(spacer)
        if let hint { inner.addArrangedSubview(hint) }
        inner.addArrangedSubview(actions)
        inner.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            inner.topAnchor.constraint(equalTo: chip.topAnchor),
            inner.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
        ])
        return chip
    }

    private func makeChipIconButton(symbol: String, tooltip: String, action: Selector, tag: Int) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let btn = NSButton(image: image, target: self, action: action)
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.contentTintColor = theme.text3
        btn.toolTip = tooltip
        btn.tag = tag
        return btn
    }

    @objc private func deleteVariantTapped(_ sender: NSButton) {
        let entryIndex = sender.tag / 1000
        let variantIndex = sender.tag % 1000
        guard vocabularyEntries.indices.contains(entryIndex),
              vocabularyEntries[entryIndex].variants.indices.contains(variantIndex) else { return }
        vocabularyEntries[entryIndex].variants.remove(at: variantIndex)
        saveVocabularyEntries()
        variantPopover?.close()
        invalidate(.vocabulary)
    }

    @objc private func deleteVocabularyEntry(_ sender: NSButton) {
        guard vocabularyEntries.indices.contains(sender.tag) else { return }
        let entry = vocabularyEntries[sender.tag]
        let alert = NSAlert()
        alert.messageText = "删除个人词语"
        alert.informativeText = "确定删除「\(entry.target)」吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        vocabularyEntries.remove(at: sender.tag)
        saveVocabularyEntries()
        rebuildSidebar()
        invalidate(.vocabulary)
    }

    // MARK: 错法管理（小气泡：看已有错法、删、加，不弹系统对话框）

    @objc private func manageVariantsTapped(_ sender: NSButton) {
        let index = sender.tag
        guard vocabularyEntries.indices.contains(index) else { return }
        variantPopover?.close()

        let entry = vocabularyEntries[index]

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = label("「\(entry.target)」常被错识别成", size: 12, weight: .medium, color: theme.text2)
        content.addArrangedSubview(title)

        if !entry.variants.isEmpty {
            let chips = NSStackView()
            chips.orientation = .horizontal
            chips.alignment = .centerY
            chips.spacing = 6
            for (vi, v) in entry.variants.enumerated() {
                chips.addArrangedSubview(makePopoverVariantChip(text: v, entryIndex: index, variantIndex: vi))
            }
            content.addArrangedSubview(chips)
        }

        let field = NSTextField()
        field.placeholderString = "输入新错法，回车保存"
        field.font = .systemFont(ofSize: 12)
        field.target = self
        field.action = #selector(variantPopoverSubmitted)
        if let cell = field.cell as? NSTextFieldCell {
            cell.sendsActionOnEndEditing = false
        }
        content.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let wrapper = AppearanceObservingView()
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        let vc = NSViewController()
        vc.view = wrapper
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc

        variantPopover = popover
        variantPopoverField = field
        variantPopoverEntryIndex = index
        // 钉在整张词条卡片上，不钉在图标上：图标是"悬停才显示"的，鼠标移向气泡时
        // 会离开词条、图标被藏起来——NSPopover 的锚点视图一不可见，气泡就自动关闭，
        // 造成"点开就消失、没法使用"（owner 2026-07-03 反馈）。卡片永远可见，气泡就稳了。
        var anchor: NSView = sender
        var probe: NSView? = sender.superview
        while let view = probe {
            if view is VocabChipView { anchor = view; break }
            probe = view.superview
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        // 焦点要经气泡自己的窗口给，且等气泡窗口显示出来之后
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }

    /// 气泡里的错法 chip：词 + ✕ 删除
    private func makePopoverVariantChip(text: String, entryIndex: Int, variantIndex: Int) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.setAppearanceBackground(theme.cardAlt)
        v.translatesAutoresizingMaskIntoConstraints = false

        let l = label(text, size: 11, weight: .regular, color: theme.text2)
        l.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "✕", target: self, action: #selector(deleteVariantTapped(_:)))
        close.isBordered = false
        close.font = .systemFont(ofSize: 9, weight: .medium)
        close.contentTintColor = theme.text3
        close.tag = entryIndex * 1000 + variantIndex   // 词条数远小于 1000，安全
        close.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(l)
        v.addSubview(close)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
            close.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 2),
            close.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    @objc private func variantPopoverSubmitted() {
        let index = variantPopoverEntryIndex
        guard let field = variantPopoverField,
              vocabularyEntries.indices.contains(index) else {
            variantPopover?.close()
            return
        }
        let variant = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        variantPopover?.close()
        guard !variant.isEmpty,
              variant.caseInsensitiveCompare(vocabularyEntries[index].target) != .orderedSame,
              !vocabularyEntries[index].variants.contains(where: { $0.caseInsensitiveCompare(variant) == .orderedSame }) else {
            return
        }
        vocabularyEntries[index].variants.append(variant)
        saveVocabularyEntries()
        invalidate(.vocabulary)
    }

    // MARK: 词库开关

    private func makeBuiltinHotWordsCard() -> NSView {
        let card = makeCard()

        let title = label("内置科技词热词", size: 14, weight: .medium, color: theme.text)
        let desc = label("Claude、Xcode、GitHub 等常用科技词。不常聊技术可以关掉。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(builtinHotWordsChanged(_:)))
        toggle.setOn(config.bool(forKey: "bigasr_include_builtin_hot_words", defaultValue: true), animated: false)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        layoutTextColumn(textStack, beside: toggle)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(toggle)

        mount(row, in: card)
        return card
    }

    @objc private func builtinHotWordsChanged(_ sender: VPToggle) {
        config.save(bool: sender.isOn, forKey: "bigasr_include_builtin_hot_words")
    }

    // MARK: 词库存取

    func loadVocabularyEntries() {
        guard let items = config.loadConfig()["term_corrections"] as? [[String: Any]] else {
            vocabularyEntries = []
            return
        }
        vocabularyEntries = items.compactMap { item in
            guard let target = (item["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else { return nil }
            let variants = (item["variants"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != target }
            return VocabularyEntry(
                target: target,
                variants: variants,
                category: item["category"] as? String ?? "其他",
                source: item["source"] as? String ?? ""
            )
        }
    }

    private func saveVocabularyEntries() {
        let items: [[String: Any]] = vocabularyEntries.map {
            ["target": $0.target, "variants": $0.variants, "category": $0.category, "source": $0.source]
        }
        config.save(values: ["term_corrections": items])
    }
}
