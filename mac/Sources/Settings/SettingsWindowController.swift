import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

protocol SettingsWindowDelegate: AnyObject {
    func currentProcessingMode() -> ProcessingMode
    func setProcessingMode(_ mode: ProcessingMode)
    func openAccessibilitySettings()
    func openMicrophoneSettings()
    func checkForUpdates(_ sender: Any?)
    func pendingUpdateInfo() -> TypefreeUpdateInfo?
    func showUpdateDetails(_ sender: Any?)
    /// 反馈页：最近一次录音时在用的软件名（定位「某个软件里不好用」）
    func recentTargetAppName() -> String?
    /// 反馈页：最近的调试日志片段（纯文本，随消息一起发给开发者）
    func debugLogTail() -> String
    /// 复用 App 的调试日志（同一个文件、同一套轮转），设置页的耗时诊断也写进去。
    func debugLog(_ message: String)
}

// MARK: - Window controller

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    enum Page: CaseIterable {
        case home
        case history
        case support
        case vocabulary
        case model
        case explore
        case settings
        case about

        var title: String {
            switch self {
            case .home: return "首页"
            case .history: return "历史记录"
            case .support: return "反馈"
            case .vocabulary: return "个人词库"
            case .model: return "模型"
            case .explore: return "探索"
            case .settings: return "设置"
            case .about: return "关于"
            }
        }

        var symbolName: String {
            switch self {
            case .home: return "house"
            case .history: return "clock.arrow.circlepath"
            case .support: return "bubble.left.and.bubble.right"
            case .vocabulary: return "book.closed"
            case .model: return "cpu"
            case .explore: return "sparkles"
            case .settings: return "gearshape"
            case .about: return "info.circle"
            }
        }
    }

    struct VocabularyEntry {
        var target: String
        var variants: [String]
        var category: String
        var source: String   // "auto" = 自动学习学到；其余视为手动添加

        var isAutoLearned: Bool { source == "auto" }
    }


    static var shared: SettingsWindowController?

    weak var settingsDelegate: SettingsWindowDelegate?
    let config = VoicePolishConfig.shared
    let historyStore = PolishHistoryStore()
    let audioStore = AudioClipStore.defaultStore()
    var historyAudioPlayer: AVAudioPlayer?
    var processingIndex: Int?               // 正在重新润色/转写的那条（行内转圈）
    var historyUpdateSheet: NSWindow?       // 「更新历史」面板
    weak var updateHistoryStack: NSStackView?
    var historyProcessingLabel: String = ""
    var cardActionContainers: [Int: NSStackView] = [:]  // 每条卡片右侧操作区，便于就地替换
    var cardOutputLabels: [Int: NSTextField] = [:]      // 每条卡片正文 label，便于就地刷新
    var cardViews: [Int: NSView] = [:]                  // 每条卡片整体视图，便于就地换整张卡（重转后不整页重建）
    var selectedPage: Page = .home
    private var sidebarRows: [Page: SidebarRow] = [:]
    private let sidebarContainer = NSView()
    private let contentHost = NSView()
    var historyEntries: [AIPolisher.PolishLog] = []
    var vocabularyEntries: [VocabularyEntry] = []
    weak var vocabQuickAddField: NSTextField?
    var variantPopover: NSPopover?
    weak var variantPopoverField: NSTextField?
    var variantPopoverEntryIndex: Int = -1
    var vocabFilter = 0   // 0=所有 1=自动学习 2=手动添加

    var bigASRAPIKeyField: NSSecureTextField?
    var bailianKeyField: NSSecureTextField?
    var asrVersionControl: VPSegmentedControl?
    var asrProviderControl: VPSegmentedControl?
    var asrKeyContainer: NSStackView?
    var asrGetKeyButton: NSButton?
    var dashscopeAPIKeyField: NSSecureTextField?
    var arkAPIKeyField: NSSecureTextField?
    var deepseekAPIKeyField: NSSecureTextField?
    var polishProviderControl: VPSegmentedControl?
    var polishKeyContainer: NSStackView?
    var polishGetKeyButton: NSButton?
    var asrTestResultLabel: NSTextField?
    var polishTestResultLabel: NSTextField?
    var licenseKeyField: NSTextField?       // 激活码输入框
    var licenseStatusLabel: NSTextField?    // 激活操作结果提示
    var healthExpandedOverride: Bool?       // nil=按状态默认（全绿折叠/有问题展开）
    var lastHealthExpanded = false          // 健康卡上次渲染时是否展开，点摘要行时取反它
    var asrTestButton: VPButton?
    var polishTestButton: VPButton?
    var autoLearnCheckbox: VPToggle?
    var outputLanguagePhraseFields: [String: NSTextField] = [:]
    var outputLanguageAddNameField: NSTextField?
    var outputLanguageAddPhrasesField: NSTextField?
    /// 「自定义触发词」是否展开（默认收起：普通用户只需要看到语言开关）
    var outputLanguageAdvancedExpanded = false
    var expandedExploreCards = Set<String>()
    var launchAtLoginCheckbox: VPToggle?
    weak var micPermissionSubLabel: NSTextField?
    weak var accessibilityPermissionSubLabel: NSTextField?
    /// 上次切回 App 时看到的权限和统计，用来判断这次要不要刷新页面
    private var lastExternalState: ExternalState?

    // History progressive loading
    var allHistoryEntries: [AIPolisher.PolishLog] = []
    var historyVisibleCount: Int = 0
    let historyBatchSize: Int = 8
    weak var historyContentStack: NSStackView?
    weak var historyFooter: NSView?
    private var historyFileMtime: Date?

    // Page cache (lazy build, isHidden swap)
    private var cachedScrolls: [Page: NSScrollView] = [:]
    var activeMicrophonePicker: MicrophonePickerSheet?

    let theme = VPTheme.automatic
    // 这几处原是写死的浅灰：浅色值保持原样，只给深色配对应颜色
    static let softFill = VPTheme.adaptive(light: NSColor(white: 0.94, alpha: 1), dark: VPTheme.dark.cardAlt)
    static let meterTrack = VPTheme.adaptive(light: NSColor(white: 0.88, alpha: 1), dark: NSColor(white: 1, alpha: 0.14))
    static let dropdownBorder = VPTheme.adaptive(light: NSColor.black.withAlphaComponent(0.16),
                                                         dark: NSColor.white.withAlphaComponent(0.16))

    static func show(delegate: SettingsWindowDelegate, initialPage: Page? = nil) {
        let controller: SettingsWindowController
        if let existing = shared {
            existing.settingsDelegate = delegate
            existing.reload()
            controller = existing
        } else {
            controller = SettingsWindowController(delegate: delegate)
            shared = controller
        }
        if let page = initialPage { controller.selectPage(page) }
        controller.clampWindowToMinSize()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 3.0 新手势演示没看完，就一直盖在正式页面上（关窗再开还在；看完才记为已看）
        if !WhatsNewGuide.hasSeen { controller.presentGuide(feature: .mouseHold, finishTitle: "开始使用") }
    }

    // MARK: - 新功能引导（盖在内容上）

    private var guideView: WhatsNewGuideView?

    /// 引导正盖在窗口上时返回窗口编号：鼠标长按说话的监听器平时忽略自家窗口，只对它放行（「试一试」输入框）
    var guideWindowNumber: Int? { guideView != nil ? window?.windowNumber : nil }

    func presentGuide(feature: WhatsNewGuide.Feature, finishTitle: String, onlyThisFeature: Bool = false) {
        guard let cv = window?.contentView else { return }
        if guideView == nil {
            let view = WhatsNewGuideView(frame: cv.bounds)
            view.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(view, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                view.topAnchor.constraint(equalTo: cv.topAnchor),
                view.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
            view.onFinish = { [weak self] in self?.dismissGuide() }
            guideView = view
        }
        guideView?.present(feature: feature, finishTitle: finishTitle, onlyThisFeature: onlyThisFeature)
    }

    private func dismissGuide() {
        WhatsNewGuide.markSeen()
        guideView?.tearDown()
        guideView?.removeFromSuperview()
        guideView = nil
    }

    init(delegate: SettingsWindowDelegate) {
        self.settingsDelegate = delegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Typefree"  // 仅供系统辅助功能/窗口菜单，标题栏不显示（侧栏已有带 logo 的名字，避免重复）
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 1040, height: 600)   // 1040 以下统计大数字会被挤，锁住下限
        window.isReleasedWhenClosed = false
        window.contentView = AppearanceObservingView()  // 自定义根视图，用于捕获日/夜模式切换
        super.init(window: window)
        window.delegate = self
        applyMainWindowAppearance()   // 先定外观再建页面，颜色第一次就按对的深浅上
        if !window.setFrameAutosaveName("VoicePolishSettingsWindow") {
            window.center()
        }
        clampWindowToMinSize()
        // macOS 26 上自定义 contentView 与窗口之间的宽度跟随（autoresizing 桥接）会丢失，
        // 布局引擎转而把 contentView 连同窗口压到内容的最小宽度（首页恰好 629，窗口随之变窄）。
        // 显式把 contentView 宽度钉回窗口内容区，窗口尺寸恢复由用户/frame 恢复控制。
        if let cv = window.contentView, let guide = window.contentLayoutGuide as? NSLayoutGuide {
            cv.widthAnchor.constraint(equalTo: guide.widthAnchor).isActive = true
        }
        setupShell()
        loadVocabularyEntries()
        rebuildSidebar()
        selectPage(.home)
        lastExternalState = ExternalState.current()
        refreshTrialStatusIfNeeded()
        // 系统切换外观只刷新颜色，保留输入框、滚动位置和展开状态。
        (window.contentView as? AppearanceObservingView)?.onAppearanceChange = { [weak self] in
            self?.applyTheme()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(termCorrectionsDidChangeExternally),
            name: .voicePolishTermCorrectionsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(microphoneSelectionDidChange),
            name: .voicePolishMicrophoneSelectionDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(microphoneSelectionDidChange),
            name: .voicePolishMicrophoneListDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStateDidChange),
            name: .typefreeUpdateStateDidChange,
            object: nil
        )
        // 用户去系统设置开权限再切回来时，健康卡/权限行的状态要跟着变
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionsMayHaveChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionsMayHaveChanged),
            name: .voicePolishAccessibilityGranted,
            object: nil
        )
        // 试用状态：每次切回 App 向服务器刷新一次（原先放在侧栏渲染里，会被反复触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // 会员状态（开通 / 续费 / 到期 / 创世标识）变化：刷新侧栏与关于页
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(membershipDidChange),
            name: LicenseManager.membershipDidChangeNotification,
            object: nil
        )
        // 「设置 → 外观」切换，或系统深浅切换（含「自动」模式天黑天亮）：重新套外观
        MainWindowAppearance.observeSystemChanges()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSettingDidChange),
            name: MainWindowAppearance.didChangeNotification,
            object: nil
        )
    }

    // MARK: - 外观（只管主窗口）

    /// 按「设置 → 外观」给主窗口设外观。只设这一个窗口（它弹出的子窗口、菜单会自动跟随），
    /// App 其余部分仍锁浅色。外观变化会触发 AppearanceObservingView → applyTheme 刷新全部颜色。
    private func applyMainWindowAppearance() {
        guard let window else { return }
        let appearance = MainWindowAppearance.resolve()
        MainWindowAppearance.applied = appearance
        guard window.appearance?.name != appearance.name else { return }
        window.appearance = appearance
        applyTheme()
    }

    @objc private func appearanceSettingDidChange() {
        applyMainWindowAppearance()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applyMainWindowAppearance()   // 兜底：万一漏了切换通知，用户回到窗口时补上
    }

    @objc private func appDidBecomeActive() {
        refreshTrialStatusIfNeeded()
    }

    @objc private func membershipDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildSidebar()
            self?.invalidate(.about)
        }
    }

    /// 试用中且未激活时向服务器刷新一次；成功后重绘侧栏让「今日用量 / 剩余天数」趋新。
    private func refreshTrialStatusIfNeeded() {
        guard TrialManager.shared.isInTrial, !LicenseManager.shared.isActivated else { return }
        TrialManager.shared.refreshFromServer { [weak self] ok in
            guard ok else { return }
            self?.rebuildSidebar()   // completion 已在主线程回调
        }
    }

    @objc private func updateStateDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildSidebar()
            self?.invalidate(.about)
        }
    }

    @objc private func permissionsMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshForExternalChanges()
        }
    }

    /// 切回 App 时首页和设置页要看的外部状态：两项权限 + 首页统计。和上次画页面时一样就什么都不做
    private struct ExternalState: Equatable {
        var micStatus: AVAuthorizationStatus
        var accessibility: Bool
        var statsDay: String
        var statsChars: Int
        var statsSessions: Int

        static func current() -> ExternalState {
            let total = InputStats.shared.allTimeTotal()
            return ExternalState(micStatus: AVCaptureDevice.authorizationStatus(for: .audio),
                                 accessibility: AXIsProcessTrusted(),
                                 statsDay: InputStats.shared.today().date,
                                 statsChars: total.chars,
                                 statsSessions: total.sessions)
        }
    }

    /// 权限变了：设置页权限卡就地改文字，侧栏底部麦克风状态重画，首页健康卡要换结构（折叠 / 展开）才重建。
    /// 只是统计变了（在别的 App 里说过话）：只重建首页，当前在首页时 invalidate 会保留滚动位置。
    private func refreshForExternalChanges() {
        let now = ExternalState.current()
        let before = lastExternalState
        lastExternalState = now
        guard let before, before != now else { return }
        if before.micStatus != now.micStatus { rebuildSidebar() }
        if before.micStatus != now.micStatus || before.accessibility != now.accessibility {
            updatePermissionsCardInPlace()
        }
        invalidate(.home)
    }

    @objc private func microphoneSelectionDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.invalidate(.settings, .home)
        }
    }

    @objc private func termCorrectionsDidChangeExternally() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loadVocabularyEntries()
            self.rebuildSidebar()
            self.invalidate(.vocabulary)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        // block 形式的观察者要按 token 单独移除，removeObserver(self) 管不到它
        if let o = supportObserver {
            NotificationCenter.default.removeObserver(o)
            supportObserver = nil
        }
        Self.shared = nil
    }

    /// 窗口可能被首次布局/frame 恢复等程序化路径压到 minSize 以下（minSize 只挡手动拖拽），统一补回下限
    func clampWindowToMinSize() {
        guard let window else { return }
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            var frame = window.frame
            frame.size.width = max(frame.size.width, window.minSize.width)
            frame.size.height = max(frame.size.height, window.minSize.height)
            window.setFrame(frame, display: true)
        }
    }


    // MARK: - Shell

    private func setupShell() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true
        cv.layer?.setAppearanceBackground(theme.bg)

        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.wantsLayer = true
        cv.addSubview(sidebarContainer)

        let divider = NSBox()
        divider.boxType = .custom
        divider.fillColor = theme.sep
        divider.borderWidth = 0
        divider.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(divider)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true
        cv.addSubview(contentHost)

        NSLayoutConstraint.activate([
            sidebarContainer.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: cv.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            sidebarContainer.widthAnchor.constraint(equalToConstant: 178),
            divider.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: cv.topAnchor),
            divider.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            contentHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: cv.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        applyTheme()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyTheme()
    }

    private func applyTheme() {
        guard let cv = window?.contentView else { return }
        cv.layer?.setAppearanceBackground(theme.bg)
        sidebarContainer.layer?.setAppearanceBackground(theme.sidebarBg)
        contentHost.layer?.setAppearanceBackground(theme.bg)
        window?.backgroundColor = theme.bg
        (cv as? AppearanceObservingView)?.refreshAppearance()
    }

    // MARK: - Sidebar

    func rebuildSidebar() {
        sidebarContainer.subviews.forEach { $0.removeFromSuperview() }
        sidebarContainer.layer?.setAppearanceBackground(theme.sidebarBg)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(stack)

        // Brand
        let brand = makeBrandHeader()
        stack.addArrangedSubview(brand)
        brand.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(14, after: brand)

        // Groups
        let historyCount = quickHistoryLineCount()
        let vocabCount = vocabularyEntries.count

        let unread = SupportChatService.shared.unreadCount
        let groups: [(String?, [(Page, String?)])] = [
            ("工作台", [(.home, nil), (.history, historyCount > 0 ? "\(historyCount)" : nil)]),
            // 「反馈」是往原作者的工单系统里提单：自编版的问题不该发给他，这一页不放
            ("配置", [(.vocabulary, vocabCount > 0 ? "\(vocabCount)" : nil), (.model, nil), (.explore, nil), (.settings, nil)]
                     + (AppBuild.isSelfBuilt ? [] : [(.support, unread > 0 ? "\(unread) 条新回复" : nil)])),
            (nil, [(.about, nil)]),
        ]

        sidebarRows.removeAll()
        for (gtitle, items) in groups {
            if let gt = gtitle {
                stack.addArrangedSubview(makeGroupTitle(gt))
                stack.arrangedSubviews.last!.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            for (page, count) in items {
                let row = SidebarRow(page: page, count: count)
                row.apply(theme: theme)
                row.isSelected = (page == selectedPage)
                row.onClick = { [weak self] in self?.selectPage($0) }
                sidebarRows[page] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        // spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spacer)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true

        // 底部方案卡：未激活 → 试用 / 试用到期 / 自带 Key；会员 → 只在快到期或已到期时提醒续费，平时不打扰
        let planCard: NSView? = LicenseManager.shared.isActivated ? makeSidebarMemberRenewalCard() : makeSidebarUpgradeButton()
        if let upgrade = planCard {
            stack.addArrangedSubview(upgrade)
            upgrade.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(10, after: upgrade)
        }

        // bottom status
        let bottom = makeSidebarStatus()
        stack.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor, constant: -10),
        ])
    }

    private func makeBrandHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        // 创世用户（3.0 前的付费/受赠用户，Ray 2026-09-14）：logo 放大到 40，右侧两行——名字 + 版本号、创世用户标签——
        // 整块与 logo 上下对齐。侧栏只有 178 点宽（可用 154），实测：名字 60、版本号 27、标签 54、NEW 34，两行都放得下
        let isGenesis = LicenseManager.shared.isGenesis
        let logo = makeWaveformMark(box: isGenesis ? 40 : 28, corner: isGenesis ? 11 : 8, boxColor: theme.accent, waveColor: theme.onAccent)

        let title = NSTextField(labelWithString: "Typefree")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = theme.text
        title.translatesAutoresizingMaskIntoConstraints = false

        // 版本号：常驻显示，点它看「更新历史」（用户想知道"我在用哪一版、都更新了什么"）
        let version = NSTextField(labelWithString: Bundle.main.appVersionString)
        version.font = .systemFont(ofSize: 11, weight: .medium)
        version.textColor = theme.text3
        version.translatesAutoresizingMaskIntoConstraints = false
        version.toolTip = "查看更新历史"

        header.addSubview(logo)
        header.addSubview(title)
        header.addSubview(version)

        var genesisTag: NSView?
        if isGenesis {
            let tag = makeTag("创世用户", bg: Self.softFill, fg: theme.text, size: 10)
            tag.toolTip = "3.0 之前就支持 Typefree 的用户，谢谢你一路同行"
            header.addSubview(tag)
            genesisTag = tag
        }

        var trailingView: NSView = version
        if let updateInfo = settingsDelegate?.pendingUpdateInfo(), updateInfo.errorMessage == nil {
            let badge = makeNewBadge()
            header.addSubview(badge)
            // 创世用户排版里，NEW 放到第二行标签后面（第一行放不下）
            let anchorView: NSView = genesisTag ?? version
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: anchorView.trailingAnchor, constant: 6),
                badge.centerYAnchor.constraint(equalTo: (genesisTag ?? title).centerYAnchor),
            ])
            trailingView = badge
            header.toolTip = "查看新版本"
            header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(updateBadgeTapped)))
        } else {
            // 没有待装新版时，整块 header 点击 = 看更新历史（点 logo/名字/版本号都行，命中区域更大）
            header.toolTip = "查看更新历史"
            header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showUpdateHistory)))
        }

        if let tag = genesisTag {
            NSLayoutConstraint.activate([
                logo.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
                logo.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                // 名字字形顶端贴 logo 上沿（14pt 字的大写高度起点在文字框下方约 4 点），标签底边贴 logo 下沿
                title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
                title.topAnchor.constraint(equalTo: logo.topAnchor, constant: -4),
                version.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
                version.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                tag.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                tag.bottomAnchor.constraint(equalTo: logo.bottomAnchor),
                trailingView.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -8),
                header.heightAnchor.constraint(equalToConstant: 58),
            ])
        } else {
            NSLayoutConstraint.activate([
                logo.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
                logo.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 9),
                title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                version.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 7),
                version.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
                trailingView.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -8),
                header.heightAnchor.constraint(equalToConstant: 42),
            ])
        }
        return header
    }

    private func makeNewBadge() -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.setAppearanceBackground(NSColor(hex: 0xE5484D))
        badge.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "NEW")
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)

        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 31),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor, constant: -0.5),
        ])
        return badge
    }

    @objc private func updateBadgeTapped() {
        settingsDelegate?.showUpdateDetails(nil)
    }

    private func makeGroupTitle(_ text: String) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = theme.text3
        lbl.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            lbl.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -12),
            lbl.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            lbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
        ])
        return wrap
    }

    private func makeSidebarStatus() -> NSView {
        let bottom = NSView()
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .custom
        line.fillColor = theme.sep
        line.borderWidth = 0
        line.translatesAutoresizingMaskIntoConstraints = false

        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.setAppearanceBackground((micOK ? theme.ok : theme.text3))
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: micOK ? "麦克风就绪" : "未授权麦克风")
        label.font = .systemFont(ofSize: 11)
        label.textColor = theme.text3
        label.translatesAutoresizingMaskIntoConstraints = false

        bottom.addSubview(line)
        bottom.addSubview(dot)
        bottom.addSubview(label)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -12),
            line.topAnchor.constraint(equalTo: bottom.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            dot.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: bottom.centerYAnchor, constant: 6),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 38),
        ])
        return bottom
    }

    // MARK: - Page switching

    func selectPage(_ page: Page) {
        // Auto-invalidate history if log file changed since last build
        if page == .history,
           let attrs = try? FileManager.default.attributesOfItem(atPath: historyStore.fileURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           mtime != historyFileMtime {
            historyFileMtime = mtime
            invalidate(.history)
        }

        selectedPage = page
        for (k, row) in sidebarRows {
            row.isSelected = (k == page)
        }

        // Lazy build on first entry
        if cachedScrolls[page] == nil {
            let scroll = buildScroll(for: page)
            cachedScrolls[page] = scroll
            contentHost.addSubview(scroll)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: contentHost.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }

        // Toggle visibility instead of destroy/rebuild
        for (k, scroll) in cachedScrolls {
            scroll.isHidden = (k != page)
        }

        if page == .support { supportChatView?.pageDidAppear() }
    }

    // MARK: - Page: Support（反馈工单）

    weak var supportChatView: SupportChatView?
    var supportObserver: NSObjectProtocol?

    private func buildScroll(for page: Page) -> NSScrollView {
        if page == .support { return buildSupportScroll() }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false // 隐藏主页面滚动条，仍可用滚轮和触控板滚动。
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        // 窗口是透明全尺寸标题栏，NSScrollView 会自动再加一段标题栏高度的顶部留白（约 38pt），
        // 叠上下面的 40 就成了近 80pt 的空档，页面看着头重脚轻。关掉自动留白，顶部只留和侧栏 logo 对齐的一段。
        scroll.automaticallyAdjustsContentInsets = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        switch page {
        case .home: buildHome(into: stack)
        case .history: buildHistory(into: stack)
        case .vocabulary: buildVocab(into: stack)
        case .model: buildModel(into: stack)
        case .explore: buildExplore(into: stack)
        case .settings: buildSettings(into: stack)
        case .about: buildAbout(into: stack)
        case .support: break   // 见 buildSupportScroll
        }

        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        scroll.documentView = doc

        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 56),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -56),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 36),   // 与侧栏品牌头（32）大致齐平
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -48),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
        ])

        // Only history page needs lazy-load scroll listener
        if page == .history {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollDidScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
        }

        return scroll
    }

    /// Drop the cached view for the given pages so they rebuild on next entry.
    /// If the currently-visible page is invalidated, rebuild it immediately.
    func invalidate(_ pages: Page...) {
        // 当前页重建后回到原来的滚动位置，否则在页面中间改个设置（或切回 App）就被弹回顶部
        var savedOrigin: NSPoint?
        for p in pages {
            if let scroll = cachedScrolls.removeValue(forKey: p) {
                if p == selectedPage { savedOrigin = scroll.contentView.bounds.origin }
                if p == .history {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSView.boundsDidChangeNotification,
                        object: scroll.contentView
                    )
                    historyContentStack = nil
                    historyFooter = nil
                }
                scroll.removeFromSuperview()
            }
        }
        if pages.contains(selectedPage) {
            selectPage(selectedPage)
            if let origin = savedOrigin, origin.y > 0, selectedPage != .support,
               let scroll = cachedScrolls[selectedPage] {
                contentHost.layoutSubtreeIfNeeded()
                let docHeight = scroll.documentView?.frame.height ?? 0
                let maxY = max(0, docHeight - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, maxY)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    /// Wipe all caches (e.g. on theme change) and rebuild the visible page.
    private func reload() {
        for (_, scroll) in cachedScrolls {
            scroll.removeFromSuperview()
        }
        cachedScrolls.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        historyContentStack = nil
        historyFooter = nil
        contentHost.layer?.setAppearanceBackground(theme.bg)
        selectPage(selectedPage)
    }

    @objc private func scrollDidScroll(_ note: Notification) {
        guard selectedPage == .history else { return }
        guard historyVisibleCount < allHistoryEntries.count else { return }
        guard let clip = note.object as? NSClipView else { return }
        let docHeight = clip.documentRect.height
        let viewportBottom = clip.bounds.origin.y + clip.bounds.height
        let distanceToBottom = docHeight - viewportBottom
        if distanceToBottom < 240 {
            appendNextHistoryBatch()
        }
    }

    var hotkeyMenuTarget: HotkeyMenuTarget = .recording

    // MARK: - 激活 / 升级卡片

    var upgradeSheet: NSWindow?

    /// 润色分段当前显示的服务商顺序（豆包默认隐藏，见 buildPolishCard）
    var polishSegProviders: [String] = ["qwen", "deepseek", "none"]

    /// 各「模型」分段建行时的预设（configKey → presets），点分段时按它存，不在这里另写一份
    var polishModelPresets: [String: [String]] = [:]
}
