import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - Page: Home

    func buildHome(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 首页", title: "首页",
                                             sub: "自然说话，清楚输入。这是你的语音工作台。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Hero
        let hero = makeHomeHero()
        stack.addArrangedSubview(hero)
        stack.setCustomSpacing(16, after: hero)

        // Stats
        let stats = InputStats.shared
        let today = stats.today()
        let week = stats.currentWeekTotal()
        let month = stats.currentMonthTotal()
        let allTime = stats.allTimeTotal()
        let statsGrid = makeStatsGrid([
            ("今日", today.charCount, "\(today.sessionCount) 次会话"),
            ("本周", week.chars, "\(week.sessions) 次"),
            ("本月", month.chars, "\(month.sessions) 次"),
            ("累计", allTime.chars, "\(allTime.sessions) 次"),
        ])
        stack.addArrangedSubview(statsGrid)
        stack.setCustomSpacing(24, after: statsGrid)

        // 近 6 周一行圆点 + 连续天数（Ray 2026-09-15 选的方案三；不带标题）
        let rhythmCard = makeRhythmCard(stats: stats)
        stack.addArrangedSubview(rhythmCard)
        stack.setCustomSpacing(24, after: rhythmCard)

        let healthTitle = sectionTitle("配置健康")
        stack.addArrangedSubview(healthTitle)
        stack.setCustomSpacing(8, after: healthTitle)
        let healthCard = makeHealthCard()
        stack.addArrangedSubview(healthCard)
        // 反馈搬到侧栏「反馈」页（对话式，能附截图、能收到回复）
    }

    /// 「节律」卡片：一行墨点（RhythmStripView）+ 一排小标签（连续 / 最长 / 活跃天数 / 最常周几）
    private func makeRhythmCard(stats: InputStats) -> NSView {
        let card = makeCard()
        let rhythm = ActivityRhythm.compute(records: stats.allDailyRecords())

        let strip = RhythmStripView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.apply(days: rhythm.days, theme: theme)

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 6
        let okTag = makeTag("已连续 \(rhythm.currentStreak) 天", bg: RhythmStripView.accent.withAlphaComponent(0.12), fg: RhythmStripView.accent)
        chips.addArrangedSubview(okTag)
        chips.addArrangedSubview(makeSoftTag("最长连续 \(rhythm.bestStreak) 天"))
        chips.addArrangedSubview(makeSoftTag("活跃 \(rhythm.activeDays) 天"))
        if let w = rhythm.busiestWeekday {
            chips.addArrangedSubview(makeSoftTag("最常在\(ActivityRhythm.weekdayNames[w])用"))
        }

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        column.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        column.addArrangedSubview(strip)
        column.addArrangedSubview(chips)
        mount(column, in: card)
        strip.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        return card
    }

    private func makeHomeHero() -> NSView {
        let card = makeCard()

        // 「长按或单击」和下面那行说明跟着快捷键、单击开关变，订阅 store 就地改字
        let titlePrefix = label("", size: 24, weight: .semibold, color: theme.text)
        titlePrefix.subscribe(SettingsStore.shared.$hotkeys.map(\.tapToggleEnabled).removeDuplicates()) { view, tapToggle in
            view.stringValue = tapToggle ? "长按或单击" : "长按"
        }
        let titleSuffix = label("开始说话", size: 24, weight: .semibold, color: theme.text)
        let hotkeyPicker = makeHotkeyPickerButton(for: .recording)

        titlePrefix.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleSuffix.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.addArrangedSubview(titlePrefix)
        titleRow.addArrangedSubview(hotkeyPicker)
        titleRow.addArrangedSubview(titleSuffix)
        titleRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        let desc = label("", size: 13, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0
        desc.lineBreakMode = .byWordWrapping
        desc.subscribe(SettingsStore.shared.$hotkeys) { view, hotkeys in
            view.stringValue = hotkeys.recording == nil
                ? "没有设置听写快捷键。在输入框里按住鼠标说话仍然可用；提问用下面两个快捷键。"
                : hotkeys.tapToggleEnabled
                ? "\(hotkeys.recordingTitle) 长按时松开结束；单击时再次单击结束。结束后自动转写并粘贴。"
                : "\(hotkeys.recordingTitle) 松开后自动转写，并粘贴到当前光标位置。"
        }

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 6
        leftStack.addArrangedSubview(titleRow)
        leftStack.addArrangedSubview(desc)
        // 问 AI 的两个快捷键和「开始说话」放在一起：三个键在同一个地方看、同一个地方改
        leftStack.setCustomSpacing(14, after: desc)
        leftStack.addArrangedSubview(makeAskHotkeyHomeRow(.screen, suffix: "看着屏幕问 AI",
                                                          note: "鼠标指着哪，AI 就重点看哪。"))
        leftStack.addArrangedSubview(makeAskHotkeyHomeRow(.plain, suffix: "只提问，不看屏幕",
                                                          note: "不截屏，更快一点。"))

        // 三个鼠标 / 口令用法一眼看到（3.0 新功能），点哪个看哪个的演示
        let gestures = NSStackView()
        gestures.orientation = .horizontal
        gestures.alignment = .centerY
        gestures.spacing = 28
        gestures.addArrangedSubview(makeGestureHint(key: "输入框里按住鼠标", label: "说话", feature: .mouseHold))
        gestures.addArrangedSubview(makeGestureHint(key: "结尾说「用英文」", label: "翻译", feature: .translation))

        // 问 AI 的几个用法：不列出来没人知道有（追问、换话题、联网、取消）
        let askHints = NSStackView()
        askHints.orientation = .horizontal
        askHints.alignment = .centerY
        askHints.spacing = 28
        askHints.addArrangedSubview(makeGestureHint(key: "回答还在时再按快捷键", label: "追问", feature: nil))
        askHints.addArrangedSubview(makeGestureHint(key: "开头说「新话题」", label: "换话题", feature: nil))
        askHints.addArrangedSubview(makeGestureHint(key: "开头说「搜一下」", label: "联网查", feature: nil))
        askHints.addArrangedSubview(makeGestureHint(key: "说话时按 Esc", label: "取消", feature: nil))

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.distribution = .fill
        main.spacing = 14
        main.edgeInsets = NSEdgeInsets(top: 18, left: 28, bottom: 16, right: 28)
        main.addArrangedSubview(leftStack)
        let rule = makeHairline(insetH: 0)
        main.addArrangedSubview(rule)
        main.addArrangedSubview(gestures)
        main.addArrangedSubview(askHints)
        mount(main, in: card)
        rule.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -56).isActive = true
        return card
    }

    /// 首页快捷用法：键帽样式的动作 + 结果；整块可点，打开该功能的演示
    /// feature 为 nil = 这条用法没有演示动画，只是列出来让人知道有这个功能
    private func makeGestureHint(key: String, label text: String, feature: WhatsNewGuide.Feature?) -> NSView {
        let cap = NSView()
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 6
        cap.layer?.borderWidth = 1
        cap.layer?.setAppearanceBorder(theme.sep)
        cap.layer?.setAppearanceBackground(theme.cardAlt)
        let capLabel = label(key, size: 12, weight: .medium, color: theme.text)
        capLabel.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(capLabel)
        NSLayoutConstraint.activate([
            capLabel.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 9),
            capLabel.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -9),
            capLabel.topAnchor.constraint(equalTo: cap.topAnchor, constant: 4),
            capLabel.bottomAnchor.constraint(equalTo: cap.bottomAnchor, constant: -4),
        ])
        let arrow = label("→", size: 12, weight: .regular, color: theme.text3)
        let result = label(text, size: 13, weight: .medium, color: theme.text2)
        let row = NSStackView(views: [cap, arrow, result])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        if let feature {
            row.toolTip = "看演示"
            let click = NSClickGestureRecognizer(target: self, action: #selector(gestureHintTapped(_:)))
            row.addGestureRecognizer(click)
            row.identifier = NSUserInterfaceItemIdentifier("gesture-\(feature.rawValue)")
        }
        return row
    }

    @objc private func gestureHintTapped(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue, let raw = Int(id.replacingOccurrences(of: "gesture-", with: "")),
              let feature = WhatsNewGuide.Feature(rawValue: raw) else { return }
        presentGuide(feature: feature, finishTitle: "完成", onlyThisFeature: true)
    }

    /// 首页上的一行：「长按或单击 [快捷键 ▾] 看着屏幕问 AI」。点中间的按钮改键，和「开始说话」同一个菜单
    private func makeAskHotkeyHomeRow(_ hotkey: AskHotkey, suffix: String, note: String) -> NSView {
        let prefixLabel = label("长按或单击", size: 15, weight: .medium, color: theme.text)
        let suffixLabel = label(suffix, size: 15, weight: .medium, color: theme.text)
        let picker = makeHotkeyPickerButton(for: .ask(hotkey), compact: true)
        picker.font = .systemFont(ofSize: 14, weight: .semibold)
        let noteLabel = label(note, size: 12, weight: .regular, color: theme.text3)
        noteLabel.subscribe(SettingsStore.shared.$hotkeys.map { $0.conflict(of: hotkey) }.removeDuplicates()) { view, conflict in
            view.stringValue = conflict.map { "⚠️ \($0)，现在不会响应" } ?? note
        }
        for view in [prefixLabel, suffixLabel] { view.setContentCompressionResistancePriority(.required, for: .horizontal) }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(prefixLabel)
        row.addArrangedSubview(picker)
        row.addArrangedSubview(suffixLabel)
        row.addArrangedSubview(noteLabel)
        row.setCustomSpacing(14, after: suffixLabel)
        return row
    }

    private func makeStatsGrid(_ items: [(String, Int, String)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 10
        for item in items {
            row.addArrangedSubview(makeStatCard(label: item.0, value: item.1, sub: item.2))
        }
        return row
    }

    private func makeStatCard(label labelText: String, value: Int, sub subText: String) -> NSView {
        let card = makeCard()

        let eyebrow = label(labelText, size: 11, weight: .medium, color: theme.text3)
        let big = label(formatNumber(value), size: 30, weight: .bold, color: theme.text)
        big.font = monoFont(size: 30, weight: .bold)
        big.maximumNumberOfLines = 1          // 数字绝不换行（窄窗口下宁可整体缩小，不断成两行）
        big.lineBreakMode = .byClipping
        let unit = label("字", size: 13, weight: .regular, color: theme.text3)
        let sub = label(subText, size: 11, weight: .regular, color: theme.text3)

        let valueRow = NSStackView()
        valueRow.orientation = .horizontal
        valueRow.alignment = .lastBaseline
        valueRow.spacing = 3
        valueRow.addArrangedSubview(big)
        valueRow.addArrangedSubview(unit)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        stack.addArrangedSubview(eyebrow)
        stack.addArrangedSubview(valueRow)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(6, after: eyebrow)
        stack.setCustomSpacing(4, after: valueRow)

        mount(stack, in: card)
        return card
    }

    private func makeHealthCard() -> NSView {
        let card = makeCard()
        let micStatus = micStatusInfo()
        let accessOK = AXIsProcessTrusted()
        let asrOK = CloudASRTranscriber().isConfigured()
        let polishOK = isPolishConfigured()
        let polishOff = (config.string(forKey: "polish_provider") ?? "qwen") == "none"
        // 按真实走的通道显示：会员优先时填了 Key 也显示「会员」；没填 Key 时会员 / 试用都算「可用」
        func hostedRow(ownKey: Bool) -> (sub: String, tail: String)? {
            switch HostedRoute.current(ownKeyConfigured: ownKey) {
            case .member: return ("会员 · 免配置，用我们提供的", "会员")
            case .trial: return ("试用中 · 用我们提供的", "试用中")
            case .none: return nil
            }
        }
        let asrHosted = hostedRow(ownKey: asrOK)
        let polishHosted = hostedRow(ownKey: polishOK)

        let rows: [(String, String, Bool, String, Selector?)] = [
            ("麦克风", micStatus.sub, micStatus.ok, micStatus.tail,
             micStatus.ok ? nil : #selector(healthMicRowTapped)),
            ("辅助功能", accessOK ? "可自动粘贴" : "未开启只能复制到剪贴板，点击去系统设置开启",
             accessOK, accessOK ? "已允许" : "未允许",
             accessOK ? nil : #selector(healthAccessibilityRowTapped)),
            asrHosted != nil
                ? ("语音识别", asrHosted!.sub, true, asrHosted!.tail, nil)
                : asrOK
                    ? ("语音识别", "BigASR 可用", true, "已配置", nil)
                    : ("语音识别", "请填写 ASR Key", false, "未配置", nil),
            polishOff
                ? ("AI 润色", "已选「不优化」，直接输出识别原文", true, "已关闭", nil)
                : polishHosted != nil
                    ? ("AI 润色", polishHosted!.sub, true, polishHosted!.tail, nil)
                    : polishOK
                        ? ("AI 润色", "可整理文本", true, "已配置", nil)
                        : ("AI 润色", "请填写润色 Key", false, "未配置", nil),
        ]

        let allOK = rows.allSatisfy { $0.2 }
        let failCount = rows.filter { !$0.2 }.count
        // 全绿默认折叠（这块没信息量），有问题默认展开；用户可手动点开/收起。
        let expanded = healthExpandedOverride ?? !allOK
        lastHealthExpanded = expanded

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0

        stack.addArrangedSubview(makeHealthSummaryRow(allOK: allOK, failCount: failCount, expanded: expanded))
        if expanded {
            stack.addArrangedSubview(makeHairline(insetH: 18))
            for (i, r) in rows.enumerated() {
                stack.addArrangedSubview(makeHealthRow(label: r.0, sub: r.1, ok: r.2, tail: r.3, action: r.4))
                if i < rows.count - 1 {
                    stack.addArrangedSubview(makeHairline(insetH: 18))
                }
            }
        }
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        mount(stack, in: card)
        return card
    }

    /// 摘要行：全绿时绿点「配置就绪 · 一切正常」，有问题时红字「N 项需要处理」；点击切换展开。
    private func makeHealthSummaryRow(allOK: Bool, failCount: Int, expanded: Bool) -> NSView {
        let dot = circle(color: allOK ? theme.ok : theme.danger, size: 8)
        let l = label(allOK ? "配置就绪 · 一切正常" : "\(failCount) 项需要处理",
                      size: 13, weight: .medium, color: allOK ? theme.text : theme.danger)
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                                accessibilityDescription: expanded ? "收起" : "展开")
        chevron.contentTintColor = theme.text3
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let h = NSStackView()
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        h.addArrangedSubview(dot)
        h.addArrangedSubview(l)
        h.addArrangedSubview(spacer)
        h.addArrangedSubview(chevron)
        h.setCustomSpacing(12, after: dot)
        h.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleHealthExpanded)))
        return h
    }

    @objc private func toggleHealthExpanded() {
        // 以卡片上次实际画出来的状态为准取反，不另算一遍全绿（两套判断对不上时第一次点击没反应）
        healthExpandedOverride = !lastHealthExpanded
        invalidate(.home)
    }

    /// 麦克风：没问过 → 直接唤起系统授权弹窗；被拒过 → 系统不允许再弹，只能带用户去系统设置开。
    @objc private func healthMicRowTapped() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.invalidate(.home, .settings) }
            }
        case .denied, .restricted:
            settingsDelegate?.openMicrophoneSettings()
        default:
            break
        }
    }

    @objc private func healthAccessibilityRowTapped() {
        guard !AXIsProcessTrusted() else { return }
        settingsDelegate?.openAccessibilitySettings()
    }

    private func makeHealthRow(label labelText: String, sub: String, ok: Bool, tail: String,
                               action: Selector? = nil) -> NSView {
        let dot = circle(color: ok ? theme.ok : theme.danger, size: 8)
        let l = label(labelText, size: 13, weight: .medium, color: theme.text)
        let s = label(sub, size: 12, weight: .regular, color: theme.text2)
        let t = label(tail, size: 12, weight: .medium, color: ok ? theme.ok : theme.danger)

        l.setContentHuggingPriority(.required, for: .horizontal)
        s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        t.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let h = NSStackView()
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        h.addArrangedSubview(dot)
        h.addArrangedSubview(l)
        h.addArrangedSubview(s)
        h.addArrangedSubview(spacer)
        h.addArrangedSubview(t)
        h.setCustomSpacing(12, after: dot)
        h.setCustomSpacing(16, after: l)
        h.setCustomSpacing(12, after: s)
        h.setCustomSpacing(0, after: spacer)
        if let action = action {
            h.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
        }
        return h
    }

    func makeHairline(insetH: CGFloat) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.setAppearanceBackground(theme.sep)
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: insetH),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -insetH),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            wrap.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrap
    }

    func micStatusInfo() -> (ok: Bool, sub: String, tail: String) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return (true, "可录音", "已允许")
        case .denied: return (false, "被拒绝过，点击去系统设置开启", "已拒绝")
        case .restricted: return (false, "受系统限制", "受限")
        case .notDetermined: return (false, "点击申请麦克风权限", "待授权")
        @unknown default: return (false, "未知状态", "未知")
        }
    }
}
