import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    func currentFrontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
    }

    // MARK: - Recording Flow

    func toggleRecording() {
        if isProcessing { return }

        if isRecording {
            stopRecordingAndProcess()
        } else {
            guard canStartRecording(showFeedback: true) else { return }
            overlayWindow.recordingControls = .cancelAndFinish
            _ = startRecording()
        }
    }

    /// - Parameter feedback: 不能录（没配 Key / 试用到期 / 额度用完）时要不要弹提示胶囊。
    ///   问 AI 的长按、面板续聊传 false：默认开着的手势不该在空白处按住半秒就冒提示
    @discardableResult
    func startRecording(feedback: Bool = true) -> Bool {
        guard !isRecording else { return false }
        guard canStartRecording(showFeedback: feedback) else { return false }
        guard hasMicrophonePermission(showFeedback: feedback) else { return false }
        // 反馈页用：记下这次是在哪个软件里录的（定位「某个软件里不好用」）
        if let name = NSWorkspace.shared.frontmostApplication?.localizedName, name != "Typefree" {
            lastRecordingTargetApp = name
        }
        if isAutoTermCorrectionLearningEnabled {
            HotWordsAutoLearner.shared.finalizePendingLearning(reason: "next_recording")
        }
        // 开关中途被关掉时，上一轮的纠错监控也要停，不能等它超时后照样写词库
        HotWordsAutoLearner.shared.stopMonitoring()
        isRecording = true
        debugLog("START recording")
        statusBar.setTitle("VP●")

        pendingOverlayHide?.cancel()   // 取消上一轮错误浮窗的延时隐藏，避免误杀本次录音浮窗
        if !voiceQuestionMode, !answerPanel.isPinned { answerPanel.hide() }
        // 问 AI 模式：蓝色光环，不显示语言标签；否则显示默认输出语言标签（防止忘了开着）
        overlayWindow.askGlow = voiceQuestionMode
        overlayWindow.languageTag = voiceQuestionMode ? nil : OutputLanguage.defaultLanguage()?.tag
        // 面板上续聊：录音状态画在面板底栏里（音浪 + 识别中），不弹底部胶囊
        // 长按问 AI：等判断出开口再弹胶囊（feedAskSpeechDetector），误触时什么都不冒出来
        if !voiceQuestionFollowUp, !askAwaitingSpeech { overlayWindow.show(state: .recording) }
        if askAwaitingSpeech { askRecordingStartedAt = Date() }

        let errorMsg = audioRecorder.startRecording { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.voiceQuestionFollowUp { self.answerPanel.updateAudioLevel(level) } else { self.overlayWindow.updateAudioLevel(level) }
                if self.askAwaitingSpeech { self.feedAskSpeechDetector(level) }
            }
        }

        if let errorMsg = errorMsg {
            isRecording = false
            statusBar.setTitle("VP")
            showError("录音启动失败: \(errorMsg)")
            return false
        }
        // 托管通道录音封顶（owner 出识别费，防开着不动烧钱）：试用 5 分钟；会员 9 分 50 秒——服务器单条上限 10 分钟，
        // 编码会多出零点几秒，留点余量免得整段被拒。到点正常停下并转写已录内容。
        let hostedRoute = HostedRoute.current(ownKeyConfigured: cloudTranscriber.isConfigured())
        if hostedRoute != .none {
            let cap: TimeInterval = hostedRoute == .member ? 590 : 300
            trialMaxRecordingTimer?.invalidate()
            trialMaxRecordingTimer = Timer.scheduledTimer(withTimeInterval: cap, repeats: false) { [weak self] _ in
                guard let self = self, self.isRecording else { return }
                self.debugLog("Hosted recording reached \(Int(cap))s cap — auto-stopping")
                self.stopRecordingAndProcess()
            }
        }
        setupStreamingIfEligible()
        return true
    }

    /// 边录边发：cloudOnly 模式下建流式会话，并每 3s 取样一次提交已说完的段落。
    /// omni（音频直喂大模型）与关闭开关时不启用，退化为松手后整段识别。
    private func setupStreamingIfEligible() {
        streamingSession = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        guard streamingEnabled, !processingMode.usesOmniDirectAudio else { return }

        // 提交/尾巴都走同一识别版本（不跟随失败回退，保持简单）；试用/自带 key 路由由 transcribe 内部处理。
        let version = cloudTranscriber.currentVersion()
        let session = StreamingTranscriptionSession(chunkTranscriber: { [weak self] samples, done in
            self?.cloudTranscriber.transcribe(samples: samples, version: version, completion: done)
        }, tailTranscriber: { [weak self] samples, done in
            self?.cloudTranscriber.transcribeAuto(samples: samples, version: version, completion: done)
        })
        session.debugLog = { [weak self] msg in self?.debugLog(msg) }
        streamingSession = session
        // 每 2s 取样一次：提交更勤 → 松手时未提交的尾巴更小 → 松手后等待更短。
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // 在主线程取出会话再切后台：streamingSession 只在主线程读写，避免和收尾时置 nil 抢同一个属性
            guard let self = self, self.isRecording, let session = self.streamingSession else { return }
            let recorder: AudioRecorder = self.audioRecorder
            DispatchQueue.global(qos: .utility).async {
                session.ingest(snapshot: recorder.snapshotSamples())
            }
        }
    }

    func stopRecordingAndProcess() {
        debugLog("STOP recording called, isRecording=\(isRecording), isProcessing=\(isProcessing)")
        guard isRecording else {
            debugLog("STOP ignored: not recording")
            return
        }
        if voiceQuestionMode {
            stopRecordingAndAsk()
            return
        }
        trialMaxRecordingTimer?.invalidate()
        trialMaxRecordingTimer = nil
        isRecording = false
        resetHotkeyGestures()
        mouseHoldToTalkManager?.recordingDidLeaveActiveState()
        isProcessing = true
        statusBar.setTitle("VP⏳")
        let mode = processingMode

        // 收起流式取样定时器，取出本次会话（可能为 nil：omni / 开关关）。
        streamingTimer?.invalidate()
        streamingTimer = nil
        let session = streamingSession
        streamingSession = nil

        debugLog("Calling audioRecorder.stopRecording...")
        audioRecorder.stopRecording { [weak self] samples in
            guard let self = self else { return }
            self.debugLog("stopRecording callback: samples=\(samples?.count ?? -1)")
            guard let samples = samples, !samples.isEmpty else {
                self.debugLog("No audio samples!")
                DispatchQueue.main.async {
                    self.recordEmptyResult()
                }
                return
            }

            guard let session = session else {
                self.pipeline.process(samples: samples, mode: mode)  // omni / 未启用流式：原路径
                return
            }
            // 边录边发：松手时只剩尾巴要识别，先显示"识别中"，尾巴回来后走润色。
            DispatchQueue.main.async {
                self.handlePipelineState(.transcribing(message: mode.transcriptionOverlayMessage))
            }
            session.finish(finalSamples: samples) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let rawText):
                        self.debugLog("Streaming finish success (\(rawText.count) chars)")
                        self.pipeline.processTranscribedText(rawText, samples: samples, mode: mode)
                    case .failure(let error):
                        self.debugLog("Streaming finish failed: \(error) — fallback to batch")
                        self.pipeline.process(samples: samples, mode: mode)
                    }
                }
            }
        }
    }

    func cancelRecording() {
        debugLog("CANCEL recording called, isRecording=\(isRecording), isProcessing=\(isProcessing)")
        pendingAskScreen?.cancel()
        pendingAskScreen = nil
        pendingAskScreenNote = nil
        askAwaitingSpeech = false
        askRecordingStartedAt = nil
        askContinuesThread = false
        let wasAsk = voiceQuestionMode
        voiceQuestionMode = false
        let wasFollowUp = voiceQuestionFollowUp
        voiceQuestionFollowUp = false
        answerPanel.setRecording(false)
        guard isRecording else {
            debugLog("CANCEL ignored: not recording")
            return
        }

        trialMaxRecordingTimer?.invalidate()
        trialMaxRecordingTimer = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingSession = nil
        pendingOverlayHide?.cancel()
        pendingOverlayHide = nil
        isRecording = false
        resetHotkeyGestures()
        mouseHoldToTalkManager?.recordingDidLeaveActiveState()
        isProcessing = false
        statusBar.setTitle("VP")
        overlayWindow.hide()
        // 问 AI 的录音取消（叉号、拖开）：撤销走的是润色粘贴，会把问题当听写贴进当前 App，所以直接丢掉
        if wasAsk && !wasFollowUp {
            audioRecorder.stopRecording { _ in }
            return
        }
        // 误点保护：不直接丢录音，暂存并给一个「撤销」窗口；窗口过后自动清掉。
        audioRecorder.stopRecording { [weak self] samples in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let samples = samples, !samples.isEmpty else { return }   // 太短没采到内容：静默作罢
                // 面板续聊取消：不给「撤销」（撤销走的是润色粘贴，不是提问），面板底栏轻提示一下
                if wasFollowUp { self.answerPanel.setListening(.cancelled); return }
                self.cancelledSamples = samples
                self.cancelledSamplesTimer?.invalidate()
                self.cancelledSamplesTimer = Timer.scheduledTimer(withTimeInterval: OverlayWindow.cancelUndoSeconds, repeats: false) { [weak self] _ in
                    self?.cancelledSamples = nil
                }
                self.overlayWindow.showCancelledCapsule()
            }
        }
    }

    /// 误点了叉号 → 点「撤销」：用刚才暂存的录音重新识别，照常润色输出。
    func redoCancelledRecording() {
        guard let samples = cancelledSamples, !isRecording, !isProcessing else { return }
        cancelledSamples = nil
        cancelledSamplesTimer?.invalidate()
        cancelledSamplesTimer = nil
        debugLog("UNDO cancel: re-processing \(samples.count) samples")
        isProcessing = true
        statusBar.setTitle("VP⏳")
        pipeline.process(samples: samples, mode: processingMode)
    }

    /// 录音太短没采到音频 / 识别结果为空：不报红框、不粘贴，安静收起浮窗，
    /// 只在历史里留一条「无内容」记录（asr/output 均为空，复制不会带出占位字）。
    private func recordEmptyResult() {
        pendingOverlayHide?.cancel()
        pendingOverlayHide = nil
        isProcessing = false
        statusBar.setTitle("VP")
        overlayWindow.hide()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.aiPolisher.writePolishLog(asr: "", output: "", durationMs: 0)
        }
    }

    func showError(_ message: String) {
        pendingOverlayHide?.cancel()
        overlayWindow.show(state: .error(message: message))
        // 失败提示按文字长短停留 4~12 秒——长录音失败的提示要让用户看清、知道原因。
        let seconds = min(12.0, max(4.0, Double(message.count) * 0.2))
        // 红色胶囊本身不画文字，只闪 0.7 秒表示"失败了"，随后换成可读的文字条说明原因。
        // 之前只有无字红框，用户根本不知道是没开通服务、断网还是别的（用户反馈"红框没字"）。
        // 用 pendingOverlayHide 挂这个切换：期间若又开始录音会被取消，不会误把录音胶囊收掉。
        let work = DispatchWorkItem { [weak self] in
            self?.overlayWindow.showErrorHint(message, seconds: seconds)
        }
        pendingOverlayHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func doneMessage(for text: String, deliveryResult: TextDelivery.DeliveryResult) -> String {
        switch deliveryResult {
        case .pasted:
            return text
        case .copiedOnlyNeedsAccessibility:
            return text + "\n(已复制到剪贴板；授予辅助功能权限后可自动粘贴)"
        }
    }

    // MARK: - Pipeline State Handling

    func handlePipelineState(_ state: VoicePolishPipeline.State) {
        DispatchQueue.main.async {
            switch state {
            case .transcribing(let message):
                self.overlayWindow.show(state: .processing(message: message))

            case .polishing(let message):
                self.overlayWindow.show(state: .processing(message: message))

            case .done(let text):
                self.debugLog("Pipeline done received on main chars=\(text.count)")
                self.isProcessing = false
                self.statusBar.setTitle("VP")
                let frontmostAppName = self.currentFrontmostAppName()
                let deliveredText = TextDelivery.adjustedTextForDelivery(text, frontmostAppName: frontmostAppName)
                if deliveredText != text {
                    self.debugLog("Chat punctuation: removed trailing full stop")
                }
                self.lastDeliveredText = deliveredText

                if self.isAutoTermCorrectionLearningEnabled {
                    HotWordsAutoLearner.shared.prepareForDelivery()
                }
                self.overlayWindow.completeProgressOnly {
                    self.overlayWindow.hide()
                }
                let result = self.textDelivery.deliver(text: deliveredText)
                if let hint = self.pendingOutputLanguageHint {
                    self.pendingOutputLanguageHint = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.overlayWindow.showHint(hint, accent: .success)
                    }
                }
                switch result {
                case .pasted:
                    self.debugLog("TextDelivery: deliver returned pasted")
                case .copiedOnlyNeedsAccessibility:
                    self.debugLog("TextDelivery: deliver returned copiedOnlyNeedsAccessibility")
                }
                // quotaCharCount 只剩统计用途（每周字数限制已在 2026-09-14 取消）：仍按「未赞助 + 自带 Key」口径记，
                // 保持 input_stats.json 老字段兼容。
                let usedTrialProxy = self.processingMode.usesCloudTranscription
                    && !self.cloudTranscriber.isConfigured()
                    && TrialManager.shared.isInTrial
                let countsTowardQuota = !LicenseManager.shared.isActivated && !usedTrialProxy
                InputStats.shared.record(charCount: deliveredText.count,
                                         countsTowardFreeQuota: countsTowardQuota)
                AutoLearnScheduler.shared.noteRecordDelivered()

                // 润色失败（额度用尽/欠费等）：文字已照常输出，但明确提醒一次，别让额度耗尽被静默跳过。
                if let warning = self.pendingPolishWarning {
                    self.pendingPolishWarning = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let tip = warning.contains("额度") && !LicenseManager.shared.hasActiveMembership() ? " · 开通会员或填自己的 Key 不限量" : ""
                        self.overlayWindow.showHint("已输出未润色文字（润色失败：\(warning)）\(tip)")
                    }
                }

                if self.isAutoTermCorrectionLearningEnabled && result == .pasted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let learner = HotWordsAutoLearner.shared
                        learner.debugLog = { [weak self] msg in self?.debugLog(msg) }
                        learner.onLearned = { [weak self] descriptions in
                            self?.showLearningFeedback(descriptions)
                        }
                        learner.onLearningCandidate = { [weak self] descriptions in
                            self?.showLearningSuggestion(descriptions)
                        }
                        learner.startMonitoring(deliveredText: deliveredText)
                    }
                }

            case .error(let message):
                self.isProcessing = false
                self.statusBar.setTitle("VP")
                self.showError(message)

            case .empty:
                self.recordEmptyResult()
            }
        }
    }
}
