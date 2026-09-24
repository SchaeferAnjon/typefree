import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - Page: History

    func buildHistory(into stack: NSStackView) {
        allHistoryEntries = historyStore.load(limit: 500)
        historyEntries = allHistoryEntries
        historyVisibleCount = 0
        historyFooter = nil
        cardActionContainers.removeAll()
        cardOutputLabels.removeAll()
        cardViews.removeAll()
        processingIndex = nil

        let header = makePageHeaderRow(
            eyebrow: "TYPEFREE / 历史记录",
            title: "历史记录",
            sub: "文字与音频都只存在本机，没有中间商。重新转写会把音频发送到你配置的识别服务商并产生费用。",
            buttonTitle: "清空历史",
            buttonStyle: .danger,
            buttonAction: #selector(clearHistory),
            secondaryTitle: "导出…",
            secondaryAction: #selector(exportHistory)
        )
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(14, after: header)

        let retentionCard = makeHistoryRetentionCard()
        stack.addArrangedSubview(retentionCard)
        stack.setCustomSpacing(20, after: retentionCard)

        if allHistoryEntries.isEmpty {
            stack.addArrangedSubview(makeEmptyState("还没有历史记录。完成一次语音输入后，这里会显示最近的转写结果。"))
            return
        }

        historyContentStack = stack
        appendNextHistoryBatch()
    }

    func appendNextHistoryBatch() {
        guard let stack = historyContentStack else { return }
        let start = historyVisibleCount
        let end = min(start + historyBatchSize, allHistoryEntries.count)
        guard start < end else { return }

        // remove old footer first
        historyFooter?.removeFromSuperview()
        historyFooter = nil

        var i = start
        var last = end
        while i < last {
            let entry = allHistoryEntries[i]
            if entry.isAsk {
                // 问 AI：同一话题的多轮（相邻、thread 相同）合并成一张卡，允许跨过本批边界
                var group = [i]
                var j = i + 1
                while j < allHistoryEntries.count, allHistoryEntries[j].isAsk, allHistoryEntries[j].thread == entry.thread, entry.thread != nil {
                    group.append(j); j += 1
                }
                let card = makeAskHistoryCard(indices: group)
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                for g in group { cardViews[g] = card }
                i = j
                last = max(last, j)
            } else {
                let card = makeHistoryCard(entry: entry, index: i)
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                cardViews[i] = card
                i += 1
            }
        }
        historyVisibleCount = last

        if historyVisibleCount < allHistoryEntries.count {
            let footer = makeHistoryFooter()
            stack.addArrangedSubview(footer)
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            historyFooter = footer
        }
    }

    private func makeHistoryFooter() -> NSView {
        let v = NSView()
        let l = label("已显示 \(historyVisibleCount) / \(allHistoryEntries.count) · 继续向下滚动加载更多",
                       size: 11, weight: .regular, color: theme.text3)
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            l.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 16),
            l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
        ])
        return v
    }

    func makeHistoryCard(entry: AIPolisher.PolishLog, index: Int) -> NSView {
        let card = makeCard()

        let time = label(formatHistoryTime(entry.time), size: 12, weight: .regular, color: theme.text3)
        let appPill = makePill(text: entry.app)
        let isProcessing = (index == processingIndex)

        // 弹性占位：吸收多余宽度，把右侧内容顶到最右
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [time, appPill] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        // 右侧操作区：可就地在「按钮」与「转圈」之间切换，不重建整页
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        cardActionContainers[index] = actions
        fillHistoryActions(actions, index: index, processing: isProcessing)

        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.distribution = .fill
        metaRow.spacing = 8
        metaRow.addArrangedSubview(time)
        metaRow.addArrangedSubview(appPill)
        metaRow.addArrangedSubview(spacer)
        metaRow.addArrangedSubview(actions)

        // 处理中时正文暗显，提示"正在基于这条重做"。空记录（没录到音频 / 识别为空）显示灰色占位。
        let isEmptyEntry = entry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let output = makeWrappingLabel(
            isEmptyEntry ? "无内容" : entry.output,
            size: 14, weight: .regular,
            color: (isProcessing || isEmptyEntry) ? theme.text3 : theme.text)
        cardOutputLabels[index] = output

        // 只在润色发生时（输出 != 原文）显示原文，避免重复
        let polished = entry.output.trimmingCharacters(in: .whitespacesAndNewlines)
            != entry.asr.trimmingCharacters(in: .whitespacesAndNewlines)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.addArrangedSubview(metaRow)
        stack.addArrangedSubview(output)
        stack.setCustomSpacing(12, after: output)

        var widthConstrainedViews: [NSView] = [metaRow, output]

        if polished {
            let dashed = DashedDivider()
            dashed.color = theme.sep
            dashed.translatesAutoresizingMaskIntoConstraints = false
            dashed.heightAnchor.constraint(equalToConstant: 1).isActive = true

            let asr = makeWrappingLabel("原文 · " + entry.asr, size: 12, weight: .regular, color: theme.text3, mono: true)

            stack.addArrangedSubview(dashed)
            stack.addArrangedSubview(asr)
            stack.setCustomSpacing(8, after: dashed)
            widthConstrainedViews.append(contentsOf: [dashed, asr])
        }

        for v in widthConstrainedViews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        mount(stack, in: card)
        return card
    }

    /// 问 AI 的一段对话（一到多轮）：时间 · 「问 AI」· 所在 App；正文按轮次排：问题（蓝色小竖条）+ 回答（纯文本）
    /// indices 为 allHistoryEntries 里从新到旧的下标，展示时按时间正序
    private func makeAskHistoryCard(indices: [Int]) -> NSView {
        let card = makeCard()
        let newest = allHistoryEntries[indices[0]]
        let turns = indices.reversed().map { allHistoryEntries[$0] }

        let time = label(formatHistoryTime(newest.time), size: 12, weight: .regular, color: theme.text3)
        let askPill = makePill(text: turns.count > 1 ? "问 AI · \(turns.count) 轮" : "问 AI")
        let appPill = makePill(text: newest.app)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [time, askPill, appPill] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let copy = VPButton(title: "复制回答", style: .secondary, size: .small,
                            theme: theme, target: self, action: #selector(copyAskAnswer(_:)))
        copy.tag = indices[0]
        let more = VPButton(title: "···", style: .icon, size: .small,
                            theme: theme, target: self, action: #selector(showAskHistoryActions(_:)))
        more.tag = indices[0]
        for v in [copy, more] {
            v.setContentHuggingPriority(.required, for: .horizontal)
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let metaRow = NSStackView(views: [time, askPill, appPill, spacer, copy, more])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.distribution = .fill
        metaRow.spacing = 8

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.addArrangedSubview(metaRow)
        stack.setCustomSpacing(14, after: metaRow)
        var widthConstrained: [NSView] = [metaRow]

        let askBlue = NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1)
        for (k, turn) in turns.enumerated() {
            // 问题：左侧 3pt 蓝色竖条（与回答面板同款）
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.setAppearanceBackground(askBlue)
            bar.layer?.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            let q = makeWrappingLabel(turn.asr, size: 14, weight: .semibold, color: theme.text)
            let qRow = NSStackView(views: [bar, q])
            qRow.orientation = .horizontal
            qRow.alignment = .top
            qRow.spacing = 10
            bar.heightAnchor.constraint(equalTo: qRow.heightAnchor).isActive = true
            stack.addArrangedSubview(qRow)
            stack.setCustomSpacing(8, after: qRow)
            q.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40 - 13).isActive = true

            let plain = AnswerPanel.plainText(fromMarkdown: turn.output)
            let a = makeWrappingLabel(plain.isEmpty ? "（没有回答）" : plain, size: 13.5, weight: .regular,
                                      color: plain.isEmpty ? theme.text3 : theme.text2)
            stack.addArrangedSubview(a)
            widthConstrained.append(a)
            if k < turns.count - 1 { stack.setCustomSpacing(18, after: a) }
        }
        for v in widthConstrained {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        mount(stack, in: card)
        return card
    }

    /// 和 index 在同一张卡上的记录下标。规则与 appendNextHistoryBatch 合并卡片一致：
    /// 只取相邻且 thread 相同的问 AI 记录，同一话题中间夹了听写就是两张卡，删除 / 复制各管各的
    private func askThreadIndices(containing index: Int) -> [Int] {
        guard allHistoryEntries.indices.contains(index) else { return [] }
        let e = allHistoryEntries[index]
        guard e.isAsk, let t = e.thread else { return [index] }
        func same(_ k: Int) -> Bool { allHistoryEntries[k].isAsk && allHistoryEntries[k].thread == t }
        var lo = index, hi = index
        while lo > 0, same(lo - 1) { lo -= 1 }
        while hi + 1 < allHistoryEntries.count, same(hi + 1) { hi += 1 }
        return Array(lo...hi)
    }

    @objc private func copyAskAnswer(_ sender: NSButton) {
        guard allHistoryEntries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AnswerPanel.plainText(fromMarkdown: allHistoryEntries[sender.tag].output), forType: .string)
    }

    @objc private func showAskHistoryActions(_ sender: NSButton) {
        let i = sender.tag
        guard allHistoryEntries.indices.contains(i) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = i
            menu.addItem(it)
        }
        add("复制问题", #selector(copyAskQuestion(_:)))
        add("复制整段对话", #selector(copyAskThread(_:)))
        menu.addItem(.separator())
        add("删除这段对话", #selector(deleteAskThread(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func copyAskQuestion(_ sender: NSMenuItem) {
        guard allHistoryEntries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allHistoryEntries[sender.tag].asr, forType: .string)
    }

    @objc private func copyAskThread(_ sender: NSMenuItem) {
        let turns = askThreadIndices(containing: sender.tag).reversed().map { allHistoryEntries[$0] }
        guard !turns.isEmpty else { return }
        let text = turns.map { "问：\($0.asr)\n\n\(AnswerPanel.plainText(fromMarkdown: $0.output))" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func deleteAskThread(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }   // 同 deleteHistoryEntry
        let indices = askThreadIndices(containing: sender.tag)
        guard !indices.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = indices.count > 1 ? "删除这段对话？" : "删除这条问答？"
        alert.informativeText = indices.count > 1 ? "这段对话共 \(indices.count) 轮，会一起删除，无法恢复。" : "无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for i in indices { _ = historyStore.deleteEntry(matching: allHistoryEntries[i]) }
        rebuildSidebar()
        invalidate(.history)
    }

    /// 填充某条卡片右侧操作区：处理中显示转圈+文案，否则显示「复制输出」「···」。
    private func fillHistoryActions(_ actions: NSStackView, index: Int, processing: Bool) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if processing {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 15).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 15).isActive = true
            spinner.startAnimation(nil)
            let working = label(historyProcessingLabel, size: 12, weight: .medium, color: theme.accent)
            working.setContentHuggingPriority(.required, for: .horizontal)
            actions.addArrangedSubview(spinner)
            actions.addArrangedSubview(working)
        } else {
            let copy = VPButton(title: "复制输出", style: .secondary, size: .small,
                                theme: theme, target: self, action: #selector(copyHistoryOutput(_:)))
            copy.tag = index

            let more = VPButton(title: "···", style: .icon, size: .small,
                                theme: theme, target: self, action: #selector(showHistoryActions(_:)))
            more.tag = index

            for v in [copy, more] {
                v.setContentHuggingPriority(.required, for: .horizontal)
                v.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            actions.addArrangedSubview(copy)
            actions.addArrangedSubview(more)
        }
    }

    /// 开始就地处理：只更新那条卡片（转圈 + 正文暗显），不重建整页、不跳动。
    func beginInlineProcessing(index: Int, label labelText: String) {
        processingIndex = index
        historyProcessingLabel = labelText
        if let actions = cardActionContainers[index] {
            fillHistoryActions(actions, index: index, processing: true)
        }
        cardOutputLabels[index]?.textColor = theme.text3
    }

    /// 这条记录是否还在原来的下标上。处理要跑几秒，期间删了别的记录会重建页面、下标整体错位，
    /// 结束时先按这个确认，不对就整页重建，不往别的卡上写
    func historyEntry(_ entry: AIPolisher.PolishLog, isAt index: Int) -> Bool {
        guard allHistoryEntries.indices.contains(index) else { return false }
        let e = allHistoryEntries[index]
        if let a = e.id, let b = entry.id, !a.isEmpty, !b.isEmpty { return a == b }
        return e.time == entry.time && e.app == entry.app && e.asr == entry.asr && e.output == entry.output
    }

    /// 结束就地处理：恢复按钮 + 用新输出刷新正文（重新润色用，结构不变）。newOutput 为 nil 表示文本不变。
    /// 只改内存里这一条，不整表重载：重载会把期间新增的记录插到最前，所有卡片的下标都对不上
    func endInlineProcessingRepolish(index: Int, entry: AIPolisher.PolishLog, newOutput: String?) {
        processingIndex = nil
        guard historyEntry(entry, isAt: index) else {
            invalidate(.history)
            return
        }
        if let newOutput {
            allHistoryEntries[index] = AIPolisher.PolishLog(
                time: entry.time, app: entry.app, asr: entry.asr, output: newOutput,
                duration_ms: entry.duration_ms, input_tokens: entry.input_tokens,
                output_tokens: entry.output_tokens, id: entry.id, audioFile: entry.audioFile,
                kind: entry.kind, thread: entry.thread)
            historyEntries = allHistoryEntries
            cardOutputLabels[index]?.stringValue = newOutput
        }
        cardOutputLabels[index]?.textColor = theme.text
        if let actions = cardActionContainers[index] {
            fillHistoryActions(actions, index: index, processing: false)
        }
    }

    @objc private func copyHistoryOutput(_ sender: NSButton) {
        guard historyEntries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyEntries[sender.tag].output, forType: .string)
    }
}
