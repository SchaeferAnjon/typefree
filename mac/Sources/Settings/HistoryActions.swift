import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - 历史条目操作（播放 / 导出 / 重润色 / 重转写 / 删除）

    @objc func showHistoryActions(_ sender: NSButton) {
        let i = sender.tag
        guard allHistoryEntries.indices.contains(i) else { return }
        let hasAudio = audioStore.exists(allHistoryEntries[i].audioFile)
        let hasText = !allHistoryEntries[i].asr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ sel: Selector, enabled: Bool) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.tag = i
            it.isEnabled = enabled
            menu.addItem(it)
        }
        // 单一「重试」：有音频→完整重跑(识别+润色，也能救回识别失败的录音)；无音频但有文字→基于已有文字重新润色。
        // 润色用的是已识别的文字、不需要音频，所以"无音频有文字"也能重试；两者都没有（空/静音记录）则无从下手，禁用。
        // 合并 重新润色/重新转写 两个入口，符合"一个重试按钮"的直觉，用户不必理解两者区别。
        let retrySel: Selector = hasAudio ? #selector(retranscribeHistoryEntry(_:)) : #selector(repolishHistoryEntry(_:))
        add("重试", retrySel, enabled: hasAudio || hasText)
        let hasOutput = !allHistoryEntries[i].output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        add("编辑文字…", #selector(editHistoryEntry(_:)), enabled: hasOutput || hasText)
        menu.addItem(.separator())
        add("导出音频…", #selector(exportHistoryAudio(_:)), enabled: hasAudio)
        menu.addItem(.separator())
        add("删除这条", #selector(deleteHistoryEntry(_:)), enabled: true)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func playHistoryAudio(_ sender: NSMenuItem) {
        guard allHistoryEntries.indices.contains(sender.tag),
              let audioFile = allHistoryEntries[sender.tag].audioFile else { return }
        let url = audioStore.url(forFileName: audioFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentHistoryActionResult(success: false, message: "音频已不存在。"); return
        }
        do {
            guard let data = audioStore.loadData(fileName: audioFile) else {
                presentHistoryActionResult(success: false, message: "无法读取音频。")
                return
            }
            let player = try AVAudioPlayer(data: data)
            historyAudioPlayer = player
            player.play()
        } catch {
            presentHistoryActionResult(success: false, message: "无法播放音频。")
        }
    }

    @objc private func exportHistoryAudio(_ sender: NSMenuItem) {
        guard allHistoryEntries.indices.contains(sender.tag),
              let audioFile = allHistoryEntries[sender.tag].audioFile else { return }
        let src = audioStore.url(forFileName: audioFile)
        guard FileManager.default.fileExists(atPath: src.path) else {
            presentHistoryActionResult(success: false, message: "音频已不存在。"); return
        }
        guard let data = audioStore.loadData(fileName: audioFile) else {
            presentHistoryActionResult(success: false, message: "无法读取音频。")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Typefree-\(allHistoryEntries[sender.tag].time.replacingOccurrences(of: ":", with: "-")).m4a"
        panel.begin { resp in
            guard resp == .OK, let dst = panel.url else { return }
            try? FileManager.default.removeItem(at: dst)
            try? data.write(to: dst, options: .atomic)
        }
    }

    /// 就地编辑整理稿：保存进历史，并把"用户改了什么"静默喂给纠错学习——
    /// 这是自动学习最可靠的信号源（发生在自己 App 里，百分之百观察得到）。
    @objc private func editHistoryEntry(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }
        let index = sender.tag
        guard allHistoryEntries.indices.contains(index) else { return }
        let entry = allHistoryEntries[index]
        let polished = entry.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = polished.isEmpty ? entry.asr.trimmingCharacters(in: .whitespacesAndNewlines) : entry.output
        guard !original.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "编辑这条记录"
        alert.informativeText = "改动会保存进历史；改过的词会被自动学习，下次识别更准。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 416, height: 180))
        textView.string = original
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let edited = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty, edited != original else { return }

        guard historyStore.updateEntry(matching: entry, newASR: nil, newOutput: edited) else {
            presentHistoryActionResult(success: false, message: "保存失败，这条记录可能已被删除。")
            return
        }
        allHistoryEntries[index] = AIPolisher.PolishLog(
            time: entry.time, app: entry.app, asr: entry.asr, output: edited,
            duration_ms: entry.duration_ms, input_tokens: entry.input_tokens,
            output_tokens: entry.output_tokens, id: entry.id, audioFile: entry.audioFile,
            kind: entry.kind, thread: entry.thread)
        historyEntries = allHistoryEntries
        refreshHistoryCardInPlace(index: index)

        // 静默学习（受"自动学习"总开关控制），学到的词条出现在词库页"自动学习"分类里
        if config.bool(forKey: "term_corrections_auto_learn_enabled", defaultValue: true) {
            _ = HotWordsAutoLearner.shared.learnFromManualCorrection(original: original, corrected: edited)
        }
    }

    @objc private func repolishHistoryEntry(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }
        let index = sender.tag
        guard allHistoryEntries.indices.contains(index) else { return }
        let entry = allHistoryEntries[index]
        let polisher = AIPolisher()
        polisher.polishLogAppNameProvider = { entry.app }
        guard polisher.isPolishEnabled() else {
            presentHistoryActionResult(success: false, message: "「语音优化」当前为「不优化」，无法重新润色。先去「模型」里选一个润色模型。")
            return
        }
        beginInlineProcessing(index: index, label: "正在重新润色…")
        polisher.polishCloudASROutput(text: entry.asr) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let polished):
                    let newOutput = polished.isEmpty ? entry.asr : polished
                    _ = self.historyStore.updateEntry(matching: entry, newASR: nil, newOutput: newOutput)
                    self.endInlineProcessingRepolish(index: index, entry: entry, newOutput: newOutput)
                case .failure(let err):
                    self.endInlineProcessingRepolish(index: index, entry: entry, newOutput: nil)  // 恢复按钮（文本不变）
                    self.presentHistoryActionResult(success: false, message: "重新润色失败：\(err.localizedDescription)")
                }
            }
        }
    }

    /// 就地把某条历史卡换成按最新数据渲染的新卡——不整页重建，保住滚动位置与已加载批次。
    /// 用于重新转写完成后刷新那一条（会同时改原文+输出、结构可能变，故整张卡重建而非只改 label）。
    /// 找不到该卡（极少见）则兜底退回整页刷新。
    private func refreshHistoryCardInPlace(index: Int) {
        guard let stack = historyContentStack,
              let old = cardViews[index],
              let pos = stack.arrangedSubviews.firstIndex(of: old),
              allHistoryEntries.indices.contains(index) else {
            invalidate(.history)
            return
        }
        let fresh = makeHistoryCard(entry: allHistoryEntries[index], index: index)
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        stack.insertArrangedSubview(fresh, at: pos)
        fresh.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        cardViews[index] = fresh
    }

    @objc private func retranscribeHistoryEntry(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }
        let index = sender.tag
        guard allHistoryEntries.indices.contains(index) else { return }
        let entry = allHistoryEntries[index]
        guard let audioFile = entry.audioFile else {
            presentHistoryActionResult(success: false, message: "音频已不存在，无法重新转写。")
            return
        }
        // 先让转圈出现、再干重活：解密 + 解码 M4A 有明显耗时，放在主线程会把界面卡住，
        // 连转圈都出不来，用户以为"点了没反应"。
        beginInlineProcessing(index: index, label: "正在重新转写…")
        let log: (String) -> Void = { [weak self] m in
            self?.settingsDelegate?.debugLog(m)
        }
        let tStart = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let samples = self.audioStore.loadSamples(fileName: audioFile), !samples.isEmpty else {
                DispatchQueue.main.async {
                    self.endInlineProcessingRepolish(index: index, entry: entry, newOutput: nil)
                    self.presentHistoryActionResult(success: false, message: "音频已不存在，无法重新转写。")
                }
                return
            }
            let decodeMs = Int(Date().timeIntervalSince(tStart) * 1000)
            let audioSec = Double(samples.count) / 16000.0
            // 重试没有「边录边发」的抢跑，整段都要重识别，耗时随录音长度线性增长——
            // 这些数字就是用来判断慢在解码还是识别的。
            log(String(format: "History retry: 解码完成 %dms, 音频 %.1fs, 开始重新转写", decodeMs, audioSec))
            self.performRetranscribe(index: index, entry: entry, samples: samples, tStart: tStart, log: log)
        }
    }

    /// 重新转写的实际执行（已在后台线程；转圈此时已经在转）。
    /// 重新转写会改变原文+输出（结构可能变），完成后就地换卡；失败则恢复。
    /// 与主流水线一致走自动分段入口，长录音重试同样享受并行加速。
    private func performRetranscribe(index: Int, entry: AIPolisher.PolishLog, samples: [Float],
                                     tStart: Date, log: @escaping (String) -> Void) {
        let transcriber = CloudASRTranscriber()
        transcriber.debugLog = log        // 让分段/版本/预算等信息跟主流水线一样进日志
        let tASR = Date()
        transcriber.transcribeAuto(samples: samples, sampleRate: 16000, version: transcriber.currentVersion()) { [weak self] result in
            guard let self = self else { return }
            log(String(format: "History retry: 识别耗时 %.1fs", Date().timeIntervalSince(tASR)))
            switch result {
            case .failure(let err):
                log("History retry: 识别失败 \(err.localizedDescription)")
                DispatchQueue.main.async {
                    self.endInlineProcessingRepolish(index: index, entry: entry, newOutput: nil)
                    self.presentHistoryActionResult(success: false, message: "重新转写失败：\(err.localizedDescription)")
                }
            case .success(let rawText):
                let polisher = AIPolisher()
                polisher.debugLog = log
                polisher.polishLogAppNameProvider = { entry.app }
                let shouldPolish = polisher.isPolishEnabled() && polisher.meaningfulCharacterCount(in: rawText) > 10
                let tPolish = Date()
                let finish: (String) -> Void = { output in
                    // 与主流水线一致：最后过一遍术语纠正（替换词）
                    let corrected = polisher.applyConfiguredTermCorrections(to: output)
                    log(String(format: "History retry: 润色耗时 %.1fs, 全程 %.1fs, 输出 %d 字",
                               shouldPolish ? Date().timeIntervalSince(tPolish) : 0,
                               Date().timeIntervalSince(tStart), corrected.count))
                    DispatchQueue.main.async {
                        _ = self.historyStore.updateEntry(matching: entry, newASR: rawText, newOutput: corrected)
                        // 同步内存里这条，再就地换这张卡——不整页重建，保住用户的滚动位置与已加载批次。
                        self.processingIndex = nil
                        // 期间页面重建过、下标已不指向这条，就整页重建，不把新文字拼到别的记录上
                        guard self.historyEntry(entry, isAt: index) else {
                            self.invalidate(.history)
                            return
                        }
                        self.allHistoryEntries[index] = AIPolisher.PolishLog(
                            time: entry.time, app: entry.app, asr: rawText, output: corrected,
                            duration_ms: entry.duration_ms, input_tokens: entry.input_tokens,
                            output_tokens: entry.output_tokens, id: entry.id, audioFile: entry.audioFile,
                            kind: entry.kind, thread: entry.thread)
                        self.historyEntries = self.allHistoryEntries
                        self.refreshHistoryCardInPlace(index: index)
                    }
                }
                if shouldPolish {
                    polisher.polishCloudASROutput(text: rawText) { presult in
                        if case .success(let p) = presult, !p.isEmpty { finish(p) } else { finish(rawText) }
                    }
                } else {
                    finish(rawText)
                }
            }
        }
    }

    @objc private func deleteHistoryEntry(_ sender: NSMenuItem) {
        guard processingIndex == nil else { return }   // 有一条在重试时不重建页面，免得它结束时下标错位
        guard allHistoryEntries.indices.contains(sender.tag) else { return }
        let entry = allHistoryEntries[sender.tag]
        let alert = NSAlert()
        alert.messageText = "删除这条历史记录？"
        alert.informativeText = "会同时删除它的文字和音频，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = historyStore.deleteEntry(matching: entry)
        rebuildSidebar()
        invalidate(.history)
    }

    func presentHistoryActionResult(success: Bool, message: String) {
        let alert = NSAlert()
        alert.messageText = success ? "完成" : "未能完成"
        alert.informativeText = message
        alert.alertStyle = success ? .informational : .warning
        alert.addButton(withTitle: "好")
        if let window = window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            _ = alert.runModal()
        }
    }

    /// 点「导出…」：在按钮下方弹出时间范围菜单（tag 即天数，0=全部）。
    @objc func exportHistory(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, tag) in [("最近 7 天", 7), ("最近一个月", 30), ("全部", 0)] {
            let item = NSMenuItem(title: title, action: #selector(exportHistoryRange(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func exportHistoryRange(_ sender: NSMenuItem) {
        let retention: AIPolisher.HistoryRetention
        let rangeTag: String
        switch sender.tag {
        case 7: retention = .oneWeek; rangeTag = "最近7天"
        case 30: retention = .oneMonth; rangeTag = "最近一个月"
        default: retention = .forever; rangeTag = "全部"
        }
        guard let markdown = historyStore.exportAllAsMarkdown(retention: retention) else {
            presentHistoryActionResult(success: false, message: "所选时间范围内没有记录可导出。")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Typefree 转写记录 \(rangeTag) \(df.string(from: Date())).md"
        panel.message = "导出的文件是明文（未加密），请妥善保管。"
        panel.begin { [weak self] resp in
            guard resp == .OK, let dst = panel.url else { return }
            do {
                try markdown.write(to: dst, atomically: true, encoding: .utf8)
            } catch {
                self?.presentHistoryActionResult(success: false, message: "写入文件失败：\(error.localizedDescription)")
            }
        }
    }

    @objc func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空本地历史记录？"
        alert.informativeText = "这只会清空本机的历史文件，不会影响个人词库和 API 配置。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        historyStore.clear()
        rebuildSidebar()
        invalidate(.history)
    }

    /// 保存时长：一套逻辑同时管文字和音频——音频始终跟着文字存、按同一时长一起过期删除。
    func makeHistoryRetentionCard() -> NSView {
        let card = makeCard()

        let title = label("语音输入内容保存时长", size: 14, weight: .medium, color: theme.text)
        let sub = label("文字和音频一起保存。默认保存全部数据；改成较短时长后，过期的本地历史会自动删除。",
                        size: 12, weight: .regular, color: theme.text3)
        sub.maximumNumberOfLines = 0

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(sub)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let retentionBtn = VPButton(title: AIPolisher.currentHistoryRetention().title + "  ▾",
                                    style: .secondary, size: .regular,
                                    theme: theme, target: self, action: #selector(showRetentionMenu(_:)))
        retentionBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 18
        row.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(retentionBtn)

        mount(row, in: card)
        return card
    }

    @objc private func showRetentionMenu(_ sender: VPButton) {
        let menu = NSMenu()
        let current = AIPolisher.currentHistoryRetention()
        for retention in AIPolisher.HistoryRetention.allCases {
            let item = NSMenuItem(title: retention.title, action: #selector(retentionMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = retention.rawValue
            item.state = (retention == current) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func retentionMenuPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let retention = AIPolisher.HistoryRetention(rawValue: raw) else { return }

        config.save(value: retention.rawValue, forKey: AIPolisher.HistoryRetention.configKey)
        historyStore.pruneExpiredEntries()
        rebuildSidebar()
        invalidate(.history)   // 重建历史页 → 按钮按新 title 重新渲染
    }
}
