import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 集中管理外部链接，换地址只改这里。
enum AppLinks {
    /// API key 图文教程页（官网教程，含火山 + 阿里完整图文步骤）。
    static let apiKeyGuideURL = "https://kdsz001.github.io/typefree/setup-guide.html"
    /// 购买页（官网定价板块：年付会员银行卡自动续费 / 微信一次性年卡，Paddle 结账，付款后邮件自动发授权码）。
    static let purchaseURL = "https://typefree.app/#pricing"
    /// 开源代码仓库（GPL-3.0，Mac 版源码在 mac/ 目录）。
    static let sourceCodeURL = "https://github.com/kdsz001/typefree"
    /// Sparkle 更新源；同时作为 App 内「更新历史」的数据源（含各版本日期与更新说明）。
    static let appcastURL = "https://typefree.app/appcast.xml"
}

/// 启动参数（mac/scripts/dev_run.sh 透传）：
/// - `-openPage <home|history|support|vocabulary|models|explore|settings|about>`：启动后打开主窗口并切到该页，正式版也认
/// - `-skipOnboarding`：不弹首次引导、新功能演示和系统授权框，只在开发版（Typefree Dev）生效
enum DevLaunchOptions {
    private static let arguments = ProcessInfo.processInfo.arguments

    static let openPage: SettingsWindowController.Page? = {
        guard let i = arguments.firstIndex(of: "-openPage"), i + 1 < arguments.count else { return nil }
        switch arguments[i + 1].lowercased() {
        case "home": return .home
        case "history": return .history
        case "support", "feedback": return .support
        case "vocabulary": return .vocabulary
        case "models", "model": return .model
        case "explore": return .explore
        case "settings": return .settings
        case "about": return .about
        default: return nil
        }
    }()

    static let skipOnboarding: Bool = AppIdentity.isDevBuild && arguments.contains("-skipOnboarding")
}

extension Bundle {
    /// 展示用版本号（CFBundleShortVersionString），取不到时为空串。
    var appVersionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

struct TypefreeUpdateInfo: Equatable {
    let title: String
    let displayVersion: String
    let buildVersion: String
    let releaseNotes: String
    let infoURL: URL?
    var isReadyToInstall: Bool
    var isDownloading: Bool
    var downloadProgress: Double = 0   // 0..1，下载进度（实时刷新对话框副标题用）
    var errorMessage: String?

    /// 除下载进度外其余字段是否一致。进度只影响弹窗副标题，不算「状态」变化。
    func sameState(as other: TypefreeUpdateInfo?) -> Bool {
        guard var o = other else { return false }
        var s = self
        s.downloadProgress = 0
        o.downloadProgress = 0
        return s == o
    }
}

extension Notification.Name {
    static let typefreeUpdateStateDidChange = Notification.Name("typefreeUpdateStateDidChange")
}

class AppDelegate: NSObject, NSApplicationDelegate, SettingsWindowDelegate, SPUUpdaterDelegate {
    var statusBar: StatusBarController!
    var overlayWindow: OverlayWindow!
    var audioRecorder: AudioRecorder!
    var cloudTranscriber: CloudASRTranscriber!
    var aiPolisher: AIPolisher!
    var hotkeyManager: HotkeyManager!
    /// 问 AI 的两套键盘快捷键：看屏幕问、纯提问。和 hotkeyManager 同生命周期
    var askHotkeyManagers: [HotkeyManager] = []
    /// 鼠标长按说话（实验功能，默认关闭）；和 hotkeyManager 同生命周期，同样需要辅助功能权限
    var mouseHoldToTalkManager: MouseHoldToTalkManager?
    /// 本次输出应用了语音口令（如英文输出）：交付后提示一次
    var pendingOutputLanguageHint: String?
    /// 「长按问 AI」：本次录音不是输入而是提问
    var voiceQuestionMode = false
    /// 在回答面板上长按发起的续聊（带本话题上下文，追加在面板里）
    var voiceQuestionFollowUp = false
    /// 快捷键提问时回答浮窗还在屏幕上：这一问接着当前话题（带历史），而不是另起一个。
    /// 和 voiceQuestionFollowUp 的区别：那个是「按住浮窗说话」，录音状态画在浮窗里、不出胶囊。
    var askContinuesThread = false
    var voiceQuestionAnchor: NSPoint = .zero
    /// 鼠标长按问 AI：录音已开始、还没听到用户开口。开口前不接管鼠标：拖动 = 选字，悄悄撤销；
    /// 松手照常识别（没判断出开口不代表没说话），识别不出话才悄悄收起、不提示
    var askAwaitingSpeech = false
    /// 「开口」判定：每次录音按这次最安静的一帧现定过线值，换麦、换环境都自适应（见 AskSpeechDetector）
    var askSpeechDetector = AskSpeechDetector()
    /// 长按问 AI 这次录音的开始时刻：没判出开口就松手时，不足 1 秒的按住当误触丢掉
    var askRecordingStartedAt: Date?
    /// 这一轮提问附带的屏幕内容。触发瞬间就开始截，和用户说话并行：
    /// 等语音识别出文字时图早已就绪，截图对总耗时的贡献基本是 0
    var pendingAskScreen: PendingAskScreen?
    /// 这一轮提问的分段耗时，收尾时写一行日志，回头看就知道慢在哪
    var askTiming = AskTiming()
    /// 这次没能带屏幕内容的原因（要显示在回答面板里，不能静默）
    var pendingAskScreenNote: String?
    /// 屏幕录制权限只引导一次，别每次触发都弹
    var didPromptForScreenCapture = false
    /// 首字迟迟不来时在面板里提示「网络较慢」，不让用户干等
    var askSlowHintWork: DispatchWorkItem?
    /// 第几轮提问：回答在面板里流式出字时录音不再被占住，旧回答的回调按这个编号丢掉，不写进新一轮。
    /// 面板开始显示新一轮（startThread / appendQuestion）时加一
    var askRound = 0
    /// 有一轮回答还在路上。这期间新提问一律另起话题，面板上按住续聊先不接（上一轮还没答完，接不上）
    var askInFlight = false
    let answerPanel = AnswerPanel()
    var textDelivery: TextDelivery!
    var pipeline: VoicePolishPipeline!

    /// Sparkle 仍负责安全下载和安装；用户可见的更新入口由 Typefree 自己控制。
    lazy var updateUserDriver = TypefreeUpdateUserDriver(owner: self)
    lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updateUserDriver, delegate: self)

    var isRecording = false
    var isProcessing = false
    let debugLogQueue = DispatchQueue(label: "com.voicepolish.debug-log", qos: .utility)
    let debugLogMaxBytes: UInt64 = 2 * 1024 * 1024
    let debugLogPrivacyMigrationKey = "debugLogPrivacyMigrationV1"
    var didReportMissingAccessibility = false
    var didPromptForAccessibility = false
    var axPollTimer: Timer?  // 辅助功能未授权时轮询，授权后立即接管快捷键（无需重启）
    var trialMaxRecordingTimer: Timer?  // 试用录音封顶 5 分钟，到点自动停止转写已录内容
    var streamingSession: StreamingTranscriptionSession?  // 边录边发：录音中提交已说完的段落
    var streamingTimer: Timer?  // 录音中定时取样并 ingest
    var streamingEnabled: Bool {  // 隐藏开关，出问题可不发版关闭
        VoicePolishConfig.shared.bool(forKey: "streaming_asr_enabled", defaultValue: true)
    }
    var lastDeliveredText: String?
    /// 最近一次录音时前台的软件名（给反馈页当线索）
    var lastRecordingTargetApp: String?
    var supportPollTimer: Timer?
    var pendingPolishWarning: String?  // 润色失败原因（额度用尽等），在文字投递后提醒一次
    var pendingOverlayHide: DispatchWorkItem?  // 防止上一次错误的延时隐藏误杀新录音浮窗
    var cancelledSamples: [Float]?  // 误点叉号的录音暂存（撤销窗口期内可重新识别）
    var cancelledSamplesTimer: Timer?  // 撤销窗口到期后清暂存，不让大段音频常驻内存
    var processingMode: ProcessingMode = {
        ProcessingMode.migrateUserDefaultsIfNeeded()
        let raw = UserDefaults(suiteName: ProcessingMode.appGroupSuiteName)?
            .string(forKey: ProcessingMode.userDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ProcessingMode.userDefaultsKey)
            ?? ""
        let stored = ProcessingMode(rawValue: raw) ?? .cloudOnly
        // omni 已从 UI 下线：始终以云端直出运行（旧的 omni 设置按 cloudOnly 处理）
        return stored == .omni ? .cloudOnly : stored
    }()
    var isAutoTermCorrectionLearningEnabled: Bool {
        VoicePolishConfig.shared.bool(forKey: "term_corrections_auto_learn_enabled", defaultValue: true)
    }

    /// 3.0.1 起录音浮窗默认「墨黑·白波」（Ray 9-15：新装和升级的用户都统一用这个）。
    /// 升级用户做一次性重置——之前选过「彩色（Siri）」的也回到墨黑，想换回去在「设置 → 录音浮窗」里点一下就行。
    private func resetOverlayStyleToMonoOnce() {
        let flag = "overlayStyleResetToMonoV1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.removeObject(forKey: OverlayStyle.userDefaultsKey)   // 空 = 默认墨黑
        defaults.set(true, forKey: flag)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 用户关了「在 Dock 中显示」：在 Dock 图标出现前就切走，免得启动时闪一下
        DockIcon.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        removeLegacyPlaintextDebugLogIfNeeded()
        resetOverlayStyleToMonoOnce()
        debugLog("App launched")

        // 启动早期：把明文 config 残留的 API key 收敛进钥匙串（幂等、fail-closed）。
        VoicePolishConfig.shared.reconcileSecrets()

        // 首次启动（含老用户首次升到此版本）默认开启「开机自启动」：只自动登记这一次，
        // 之后完全尊重用户在设置开关 / 系统设置里的后续选择，不再自作主张。
        LaunchAtLogin.applyDefaultIfFirstLaunch()

        // 锁定浅色外观：仅做了「系统原生灰」浅色主题，夜间模式暂未打磨，
        // 强制全 App 用 aqua（自定义主题 + 原生控件都跟随），避免系统切暗色后样式糟糕。
        NSApp.appearance = NSAppearance(named: .aqua)

        // 补一个标准主菜单：没有它，Cmd+C/V/X/A 等编辑快捷键无法分发到输入框
        // （之前只能靠右键菜单粘贴）。
        setupMainMenu()

        // 自编版不接官方更新：一更新，自己的改动就被官方包盖掉了；开发版（Typefree Dev）同理
        if AppBuild.isSelfBuilt || AppIdentity.isDevBuild {
            debugLog("Self-built or dev build: Sparkle updater not started")
        } else {
            do {
                try updater.start()
                if updater.automaticallyChecksForUpdates,
                   updater.allowsAutomaticUpdates,
                   !updater.automaticallyDownloadsUpdates {
                    updater.automaticallyDownloadsUpdates = true
                }
                // Info.plist 中仍保持每天检查一次；这里不额外强制每次启动弹检查。
                debugLog("Sparkle updater started")
            } catch {
                debugLog("Sparkle updater failed: \(error.localizedDescription)")
            }
        }

        // 启动时只在「从未问过」时申请；已拒绝的不自动跳系统设置——
        // 配合开机自启，每次登录都被弹到「系统设置」体验极差，且用户无法关掉。
        // 已拒绝的用户在引导页 / 首页健康卡里点击时再跳（onboardingRequestMicrophone / openMicrophoneSettings）。
        // 开发版带 -skipOnboarding 启动：不弹任何系统授权框（麦克风 / 辅助功能），方便 agent 无人值守实测
        if DevLaunchOptions.skipOnboarding {
            debugLog("Dev launch: skipping onboarding and permission prompts")
            WhatsNewGuide.markSeen()
            didPromptForAccessibility = true
            didReportMissingAccessibility = true
        } else {
            requestMicrophonePermissionIfUndetermined()
        }

        // 授权联网复核：退款/被找回页重置的设备，几天内自动退出激活（没网照常用）
        LicenseManager.shared.startRevalidation(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)

        // 自动学习（风格画像；从成稿挖词默认停用）：启动后在后台低优先级跑一次，之后随投递节流触发
        AutoLearnScheduler.shared.debugLog = { [weak self] msg in self?.debugLog(msg) }
        AutoLearnScheduler.shared.scheduleLaunchRun()
        // 纠错学习：启动时整理一次候选（过期的、不像听错的清掉）
        HotWordsAutoLearner.shared.debugLog = { [weak self] msg in self?.debugLog(msg) }
        HotWordsAutoLearner.shared.pruneLearningCandidates()

        // Initialize components
        statusBar = StatusBarController(delegate: self)
        overlayWindow = OverlayWindow()
        overlayWindow.onCancelRecording = { [weak self] in self?.cancelRecording() }
        overlayWindow.onFinishRecording = { [weak self] in self?.stopRecordingAndProcess() }
        overlayWindow.onUndoCancel = { [weak self] in self?.redoCancelledRecording() }
        audioRecorder = AudioRecorder()
        audioRecorder.prepare()  // 只注册设备变更监听；引擎录音时才建，空闲不占系统音频设备
        cloudTranscriber = CloudASRTranscriber()
        cloudTranscriber.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        aiPolisher = AIPolisher()
        aiPolisher.polishLogAppNameProvider = { [weak self] in
            self?.currentFrontmostAppName() ?? "未知"
        }
        aiPolisher.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        textDelivery = TextDelivery()
        textDelivery.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        pipeline = VoicePolishPipeline(aiPolisher: aiPolisher, cloudTranscriber: cloudTranscriber)
        pipeline.debugLog = { [weak self] message in
            self?.debugLog(message)
        }
        pipeline.onStateChange = { [weak self] state in
            self?.handlePipelineState(state)
        }
        pipeline.onOutputLanguageApplied = { [weak self] language, command in
            // 口令触发的只提示前 3 次（教会用户口令生效了就退场；识别中胶囊的「→ EN」一直在）；默认语言不提示
            guard let command else { return }
            DispatchQueue.main.async {
                let key = "OutputLanguageHintShownCount"
                let shown = UserDefaults.standard.integer(forKey: key)
                guard shown < 3 else { return }
                UserDefaults.standard.set(shown + 1, forKey: key)
                self?.pendingOutputLanguageHint = "已按口令「\(command.matchedPhrase)」输出\(language.name)"
            }
        }
        pipeline.onPolishFailed = { [weak self] reason in
            DispatchQueue.main.async { self?.pendingPolishWarning = reason }
        }
        // 历史音频始终跟着文字一起保存（按同一保存时长过期删除）。纯本地、不上传。
        pipeline.audioSaver = { samples, id in
            AudioClipStore.defaultStore().save(samples: samples, id: id)
        }
        // 启动迁移历史加密，并在迁移后清理没有对应历史记录的音频文件。
        // 先挂观察者再启动迁移：迁移在后台读密钥，发现旧密钥丢失会广播这条通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyKeyWasRegenerated),
            name: HistoryCrypto.keyRegeneratedNotification,
            object: nil
        )
        migrateLocalHistoryEncryption()
        statusBar.setProcessingMode(processingMode)
        debugLog("Processing mode at launch: \(processingMode.debugName)")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // 首次运行展示引导。先于 updateAppReadiness() 呈现，
        // 这样辅助功能未授权时由引导负责索要权限，不会再额外弹独立的错误提示。
        if DevLaunchOptions.skipOnboarding {
            // 开发版无人值守启动：不弹引导，也不自动弹新功能演示
        } else if !VoicePolishConfig.shared.bool(forKey: "onboarding_completed") {
            debugLog("First run: presenting onboarding")
            showOnboarding()
        } else if !WhatsNewGuide.hasSeen, !UserDefaults.standard.bool(forKey: "WhatsNewGuideAutoShown_\(WhatsNewGuide.version)") {
            // 老用户升级到 3.0：第一次打开就把设置窗打开，新手势演示盖在上面，看完才进正式页面。
            // 只自动弹这一次：没看完就关掉的人，下次启动不再抢前台，从状态栏打开设置时仍会看到引导
            UserDefaults.standard.set(true, forKey: "WhatsNewGuideAutoShown_\(WhatsNewGuide.version)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.isOnboardingVisible else { return }
                self.debugLog("Presenting what's-new guide \(WhatsNewGuide.version)")
                self.showSettingsCenter()
            }
        }

        // 启动末尾主动调一次，注册 hotkey 并把状态栏置为 ready
        updateAppReadiness()
        startSupportPolling()

        // 没配 key 且未激活 → 自动进入/刷新免费试用（需 cloudTranscriber 已初始化）。
        maybeStartTrial()

        // 启动参数 -openPage <页名>：启动后直接打开主窗口并切到该页（开发实测用）
        if let page = DevLaunchOptions.openPage {
            debugLog("Launch argument: opening page \(page)")
            SettingsWindowController.show(delegate: self, initialPage: page)
        }
    }

    /// 没配 key 且未激活 → 自动进入/刷新免费试用（owner 出 API 费）。断网静默，不阻塞启动。
    private func maybeStartTrial() {
        guard !cloudTranscriber.isConfigured(), !LicenseManager.shared.isActivated else { return }
        TrialManager.shared.refreshFromServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        hotkeyManager?.stop()
        askHotkeyManagers.forEach { $0.stop() }
        askHotkeyManagers = []
        mouseHoldToTalkManager?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 在访达 / 启动台再次打开时，系统会把 App 改回普通前台 App（Dock 图标又出来）；用户关了就再切回去
        debugLog("reopen: policy=\(NSApp.activationPolicy().rawValue) showDock=\(DockIcon.isShown)")
        DockIcon.apply()
        DispatchQueue.main.async { DockIcon.apply() }
        if !flag {
            showSettingsCenter()
        }
        return true
    }

    /// 启动时把旧的明文历史文字/音频收敛成密文；失败时保留原文件，下次启动再试。
    private func migrateLocalHistoryEncryption() {
        DispatchQueue.global(qos: .utility).async {
            if let logFile = AIPolisher.historyLogFileURL() {
                _ = HistoryCrypto.migrateLogFile(at: logFile)
            }
            AudioClipStore.defaultStore().migrateAll()
            self.cleanupOrphanAudio()
        }
    }

    /// 启动时清理孤儿音频：删掉 audio/ 下没有对应历史记录的文件（防 ID 漂移残留）。
    private func cleanupOrphanAudio() {
        DispatchQueue.global(qos: .utility).async {
            guard let logFile = AIPolisher.historyLogFileURL() else { return }
            // 读文件 → 删孤儿音频 放同一把锁里：否则这期间刚追加的记录，其音频会被当孤儿删掉。
            HistoryFileLock.withLock {
                guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return }
                let enc = HistoryCrypto.defaultEncryptor()
                var keep = Set<String>()
                for line in content.split(separator: "\n") where !line.isEmpty {
                    let rawLine = String(line)
                    if HistoryCrypto.isEncryptedLine(rawLine),
                       HistoryCrypto.decodeLine(rawLine, enc: enc) == nil {
                        return
                    }
                    guard let log = HistoryCrypto.decodeLine(rawLine, enc: enc),
                          let audio = log.audioFile else { continue }
                    keep.insert(audio)
                }
                AudioClipStore.defaultStore().pruneOrphans(keeping: keep)
            }
        }
    }

    /// 历史加密密钥丢失（钥匙串被重置等）且旧记录仍在：告知用户一次，别让历史「悄悄消失」。
    @objc private func historyKeyWasRegenerated() {
        let alert = NSAlert()
        alert.messageText = "历史记录的加密密钥已丢失"
        alert.informativeText = "钥匙串里找不到之前用来加密历史记录的密钥（通常是钥匙串被重置或迁移过）。\n\n之前的历史记录无法再读取；从现在起的新记录会用新密钥正常保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    // MARK: - First-run Onboarding

    var onboardingController: OnboardingWindowController?

    var lastLearnedDescriptions: [String] = []
    var lastLearningSuggestionDescriptions: [String] = []

    func currentProcessingMode() -> ProcessingMode {
        processingMode
    }

    func setProcessingMode(_ mode: ProcessingMode) {
        guard processingMode != mode else { return }
        processingMode = mode
        if let group = UserDefaults(suiteName: ProcessingMode.appGroupSuiteName) {
            group.set(mode.rawValue, forKey: ProcessingMode.userDefaultsKey)
        }
        UserDefaults.standard.set(mode.rawValue, forKey: ProcessingMode.userDefaultsKey)
        statusBar?.setProcessingMode(mode)
        debugLog("Processing mode changed to \(mode.debugName)")
        updateAppReadiness()
    }

    @objc private func handleAppDidBecomeActive() {
        updateAccessibilityDependentFeatures()
    }
}
