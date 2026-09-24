import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - Page: Settings

    func buildSettings(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 设置", title: "设置",
                                             sub: "管理启动、音频、快捷键和权限。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        let launchTitle = sectionTitle("启动")
        stack.addArrangedSubview(launchTitle)
        stack.setCustomSpacing(8, after: launchTitle)
        let launchCard = makeLaunchAtLoginCard()
        stack.addArrangedSubview(launchCard)
        stack.setCustomSpacing(24, after: launchCard)

        let appearanceTitle = sectionTitle("外观")
        stack.addArrangedSubview(appearanceTitle)
        stack.setCustomSpacing(8, after: appearanceTitle)
        let appearanceCard = makeAppearanceCard()
        stack.addArrangedSubview(appearanceCard)
        stack.setCustomSpacing(10, after: appearanceCard)
        let dockCard = makeDockIconCard()
        stack.addArrangedSubview(dockCard)
        stack.setCustomSpacing(24, after: dockCard)

        let audioTitle = sectionTitle("音频")
        stack.addArrangedSubview(audioTitle)
        stack.setCustomSpacing(8, after: audioTitle)
        let audioCard = makeAudioCard()
        stack.addArrangedSubview(audioCard)
        stack.setCustomSpacing(24, after: audioCard)

        let hotkeyTitle = sectionTitle("快捷键")
        stack.addArrangedSubview(hotkeyTitle)
        stack.setCustomSpacing(8, after: hotkeyTitle)
        let hotkeyKeysCard = makeHotkeyKeysCard()
        stack.addArrangedSubview(hotkeyKeysCard)
        stack.setCustomSpacing(10, after: hotkeyKeysCard)
        let hotkeyCard = makeHotkeyBehaviorCard()
        stack.addArrangedSubview(hotkeyCard)
        stack.setCustomSpacing(24, after: hotkeyCard)

        let askTitle = sectionTitle("问 AI")
        stack.addArrangedSubview(askTitle)
        stack.setCustomSpacing(8, after: askTitle)
        let askCard = makeAskThinkingCard()
        stack.addArrangedSubview(askCard)
        stack.setCustomSpacing(24, after: askCard)

        let overlayTitle = sectionTitle("录音浮窗")
        stack.addArrangedSubview(overlayTitle)
        stack.setCustomSpacing(8, after: overlayTitle)
        let overlayCard = makeOverlayStyleCard()
        stack.addArrangedSubview(overlayCard)
        stack.setCustomSpacing(24, after: overlayCard)

        // Permissions（个人词库自动学习开关已移至「个人词库」页）
        stack.addArrangedSubview(makePermissionsCard())
    }

    /// 录音浮窗样式选择：两张并排的「静态预览磁贴」，点哪张选哪张（替代原纯文字分段控件）。
    private func makeOverlayStyleCard() -> NSView {
        let card = makeCard()

        let styleLabel = label("颜色样式", size: 12.5, weight: .semibold, color: theme.text2)
        let colorTile = OverlayStyleTile(mono: false, title: "彩色（Siri）", theme: theme)
        let monoTile = OverlayStyleTile(mono: true, title: "墨黑 · 白波", theme: theme)
        let isMono = OverlayStyle.current == .mono
        colorTile.setSelected(!isMono)
        monoTile.setSelected(isMono)
        colorTile.onSelect = { [weak colorTile, weak monoTile] in
            UserDefaults.standard.set(OverlayStyle.colorful.rawValue, forKey: OverlayStyle.userDefaultsKey)
            colorTile?.setSelected(true); monoTile?.setSelected(false)
        }
        monoTile.onSelect = { [weak colorTile, weak monoTile] in
            UserDefaults.standard.set(OverlayStyle.mono.rawValue, forKey: OverlayStyle.userDefaultsKey)
            colorTile?.setSelected(false); monoTile?.setSelected(true)
        }
        for tile in [colorTile, monoTile] {
            tile.widthAnchor.constraint(equalToConstant: 176).isActive = true
        }

        let styleTiles = NSStackView(views: [colorTile, monoTile])
        styleTiles.orientation = .horizontal
        styleTiles.spacing = 12

        let controlsTitle = label("显示取消 / 完成按钮", size: 13, weight: .medium, color: theme.text)
        let controlsDesc = label("开启后，录音浮窗两侧会显示可点击按钮；关闭后恢复旧版完整声波胶囊。切换后下次录音生效。",
                                 size: 12, weight: .regular, color: theme.text3)
        controlsDesc.maximumNumberOfLines = 0
        controlsDesc.lineBreakMode = .byWordWrapping

        let controlsText = NSStackView()
        controlsText.orientation = .vertical
        controlsText.alignment = .leading
        controlsText.spacing = 2
        controlsText.addArrangedSubview(controlsTitle)
        controlsText.addArrangedSubview(controlsDesc)
        controlsText.setHuggingPriority(.defaultLow, for: .horizontal)
        controlsText.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        controlsDesc.widthAnchor.constraint(equalTo: controlsText.widthAnchor).isActive = true

        let controlsToggle = VPToggle(theme: theme, target: self, action: #selector(overlayControlsChanged(_:)))
        controlsToggle.setOn(OverlayControlsMode.current == .buttons, animated: false)
        controlsToggle.setContentHuggingPriority(.required, for: .horizontal)
        controlsToggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        let controlsRow = NSView()
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        controlsText.translatesAutoresizingMaskIntoConstraints = false
        controlsToggle.translatesAutoresizingMaskIntoConstraints = false
        controlsRow.addSubview(controlsText)
        controlsRow.addSubview(controlsToggle)
        NSLayoutConstraint.activate([
            controlsText.leadingAnchor.constraint(equalTo: controlsRow.leadingAnchor),
            controlsText.topAnchor.constraint(equalTo: controlsRow.topAnchor),
            controlsText.bottomAnchor.constraint(equalTo: controlsRow.bottomAnchor),
            controlsText.trailingAnchor.constraint(equalTo: controlsToggle.leadingAnchor, constant: -16),
            controlsToggle.trailingAnchor.constraint(equalTo: controlsRow.trailingAnchor),
            controlsToggle.centerYAnchor.constraint(equalTo: controlsRow.centerYAnchor)
        ])

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 12
        main.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        main.addArrangedSubview(styleLabel)
        main.addArrangedSubview(styleTiles)
        main.setCustomSpacing(16, after: styleTiles)
        main.addArrangedSubview(controlsRow)
        controlsRow.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -36).isActive = true

        mount(main, in: card)
        return card
    }

    private static let appearanceOptions: [MainWindowAppearance] = [.system, .light, .dark]

    /// 外观：主窗口和问 AI 面板跟随系统 / 浅色 / 深色。录音胶囊等其余窗口仍是浅色。
    private func makeAppearanceCard() -> NSView {
        let card = makeCard()

        let title = label("深色模式", size: 14, weight: .medium, color: theme.text)
        let desc = label("选「跟随系统」时，Mac 切到深色（包括晚上自动切换），主窗口和问 AI 面板也跟着变深。",
                         size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let seg = VPSegmentedControl(
            labels: ["跟随系统", "浅色", "深色"],
            trackBg: theme.cardAlt,
            trackBorder: theme.sep,
            selBg: theme.segSelBg,
            selBorder: theme.sep,
            selText: theme.text,
            normalText: theme.text2,
            target: self,
            action: #selector(mainWindowAppearanceChanged(_:)))
        seg.selectedSegment = Self.appearanceOptions.firstIndex(of: MainWindowAppearance.current) ?? 0
        seg.widthAnchor.constraint(equalToConstant: 270).isActive = true
        seg.setContentHuggingPriority(.required, for: .horizontal)
        seg.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(desc)
        layoutTextColumn(textStack, beside: seg)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(seg)

        mount(row, in: card)
        return card
    }

    private func makeDockIconCard() -> NSView {
        let card = makeCard()

        let title = label("在 Dock 中显示", size: 14, weight: .medium, color: theme.text)
        let desc = label("关闭后 Dock 和 ⌘Tab 里不再出现 Typefree，可从屏幕顶部菜单栏的图标打开。",
                         size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(dockIconChanged(_:)))
        toggle.setOn(DockIcon.isShown, animated: false)
        toggle.setAccessibilityLabel("在 Dock 中显示")

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

    @objc private func dockIconChanged(_ sender: VPToggle) {
        DockIcon.setShown(sender.isOn)
        // 切激活策略时系统会把本 App 挪到后台，把设置窗拉回前台，别让用户以为窗口没了
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func mainWindowAppearanceChanged(_ sender: VPSegmentedControl) {
        let option = Self.appearanceOptions[sender.selectedSegment]
        UserDefaults.standard.set(option.rawValue, forKey: MainWindowAppearance.userDefaultsKey)
        NotificationCenter.default.post(name: MainWindowAppearance.didChangeNotification, object: nil)   // 主窗口、问 AI 面板一起换
    }

    @objc private func overlayControlsChanged(_ sender: VPToggle) {
        let mode: OverlayControlsMode = sender.isOn ? .buttons : .classic
        UserDefaults.standard.set(mode.rawValue, forKey: OverlayControlsMode.userDefaultsKey)
    }

    private func makeLaunchAtLoginCard() -> NSView {
        let card = makeCard()

        let title = label("开机时自动启动", size: 14, weight: .medium, color: theme.text)
        let desc = label("登录后自动在后台打开 Typefree，不用每次手动启动。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(launchAtLoginChanged(_:)))
        toggle.setOn(LaunchAtLogin.isEnabled, animated: false)
        launchAtLoginCheckbox = toggle

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

    /// 设置页「快捷键」栏里的三个键：开始说话、看屏幕问 AI、只提问。和首页是同一套选择按钮
    private func makeHotkeyKeysCard() -> NSView {
        let card = makeCard()
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)

        let recordingPicker = makeHotkeyPickerButton(for: .recording, compact: true)
        recordingPicker.font = .systemFont(ofSize: 14, weight: .semibold)
        let rows: [NSView] = [
            makeAskCursorRow(title: "开始说话", desc: "听写：说的话整理好后粘贴到光标处。", control: recordingPicker),
            makeAskHotkeyRow(.screen, desc: "按下那一刻鼠标指在哪，AI 就重点看哪。回答浮窗还在时再按就是追问。"),
            makeAskHotkeyRow(.plain, desc: "不截屏，更快一点，屏幕上的内容也不会发出去。"),
        ]
        for row in rows {
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
        }
        mount(column, in: card)
        return card
    }

    private func makeHotkeyBehaviorCard() -> NSView {
        let card = makeCard()

        let title = label("单击快捷键开始/停止录音", size: 14, weight: .medium, color: theme.text)
        let desc = label("开启后，仍可长按录音；短按一次会保持录音，再短按一次结束。", size: 12, weight: .regular, color: theme.text3)
        desc.maximumNumberOfLines = 0

        let toggle = VPToggle(theme: theme, target: self, action: #selector(tapToggleChanged(_:)))
        toggle.setAccessibilityLabel("单击快捷键开始/停止录音")
        bindToggle(toggle, to: SettingsStore.shared.$hotkeys.map(\.tapToggleEnabled))

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

    private func makeAudioCard() -> NSView {
        let card = makeCard()
        let mgr = MicrophoneManager.shared

        let l = label("麦克风", size: 14, weight: .medium, color: theme.text)
        let s = label("选择录音用的麦克风。如果没有声音输入，可以试试切换。", size: 12, weight: .regular, color: theme.text3)
        s.maximumNumberOfLines = 0
        s.preferredMaxLayoutWidth = 320

        let currentLbl = label(mgr.displayName(), size: 13, weight: .regular, color: theme.text2)
        currentLbl.alignment = .right
        currentLbl.maximumNumberOfLines = 1
        currentLbl.lineBreakMode = .byTruncatingTail
        currentLbl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chevron = label("›", size: 18, weight: .regular, color: theme.text3)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(l)
        textStack.addArrangedSubview(s)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let rightStack = NSStackView()
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 6
        rightStack.addArrangedSubview(currentLbl)
        rightStack.addArrangedSubview(chevron)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(rightStack)

        let click = NSClickGestureRecognizer(target: self, action: #selector(openMicrophonePicker))
        row.addGestureRecognizer(click)

        mount(row, in: card)
        return card
    }

    @objc private func openMicrophonePicker() {
        guard let host = window else { return }
        let picker = MicrophonePickerSheet(theme: theme)
        activeMicrophonePicker = picker
        picker.present(over: host) { [weak self] in
            self?.invalidate(.settings)
            self?.activeMicrophonePicker = nil
        }
    }

    /// 权限行的说明文字，建卡和切回 App 就地刷新共用
    private func permissionSubTexts() -> (mic: String, accessibility: String) {
        (micStatusInfo().ok ? "已允许，可录音" : "未允许，请到系统设置开启",
         AXIsProcessTrusted() ? "已允许，可自动粘贴" : "未允许，只能复制到剪贴板")
    }

    func updatePermissionsCardInPlace() {
        let texts = permissionSubTexts()
        micPermissionSubLabel?.stringValue = texts.mic
        accessibilityPermissionSubLabel?.stringValue = texts.accessibility
    }

    private func makePermissionsCard() -> NSView {
        let card = makeCard()
        let texts = permissionSubTexts()
        let rows: [(String, String, Selector)] = [
            ("麦克风", texts.mic, #selector(openMicrophoneSettings)),
            ("辅助功能", texts.accessibility, #selector(openAccessibilitySettings)),
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for (i, r) in rows.enumerated() {
            let row = makePermissionRow(label: r.0, sub: r.1, action: r.2)
            stack.addArrangedSubview(row)
            let subLabel = row.subviews.compactMap { $0 as? NSStackView }.first?
                .arrangedSubviews.compactMap { $0 as? NSTextField }.last
            if i == 0 { micPermissionSubLabel = subLabel } else { accessibilityPermissionSubLabel = subLabel }
            if i < rows.count - 1 {
                stack.addArrangedSubview(makeHairline(insetH: 18))
            }
        }
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        mount(stack, in: card)
        return card
    }

    private func makePermissionRow(label labelText: String, sub: String, action: Selector) -> NSView {
        let l = label(labelText, size: 14, weight: .medium, color: theme.text)
        let s = label(sub, size: 12, weight: .regular, color: theme.text3)
        s.maximumNumberOfLines = 0
        s.lineBreakMode = .byWordWrapping
        let btn = VPButton(title: "系统设置 →", style: .secondary, size: .small,
                           theme: theme, target: self, action: action)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(l)
        textStack.addArrangedSubview(s)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        s.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        btn.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textStack)
        row.addSubview(btn)
        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -16),
            textStack.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -12),
            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            btn.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    @objc private func tapToggleChanged(_ sender: VPToggle) {
        SettingsStore.shared.setTapToggleEnabled(sender.isOn)   // 首页「长按或单击」和说明跟着换字
    }

    @objc private func launchAtLoginChanged(_ sender: VPToggle) {
        let ok = LaunchAtLogin.setEnabled(sender.isOn)
        // 以系统真实状态回填开关：万一注册/注销失败，开关自动弹回真实状态，不给用户错觉。
        if !ok {
            sender.setOn(LaunchAtLogin.isEnabled, animated: true)
        }
    }

    @objc private func openAccessibilitySettings() {
        settingsDelegate?.openAccessibilitySettings()
    }

    @objc private func openMicrophoneSettings() {
        settingsDelegate?.openMicrophoneSettings()
    }
}
