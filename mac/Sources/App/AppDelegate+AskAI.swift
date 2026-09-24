import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    /// 「长按问 AI」松手：只识别，不润色不粘贴，把识别出的问题交给 AI，答案弹在按下点附近。
    func stopRecordingAndAsk() {
        // 没判断出开口就松手：录了至少 1 秒且响到过过线值（离麦远时说话可能攒不够帧）才照常识别，
        // 识别不出话就悄悄收起，不弹「没听到问题」；太短或从头到尾没出声就是误触，静默丢弃
        let speechUnconfirmed = askAwaitingSpeech
        if speechUnconfirmed {
            let duration = askRecordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            guard duration >= 1.0, askSpeechDetector.peakReachedLine else {
                debugLog("ASK released before speech detected, \(String(format: "%.2f", duration))s (\(askSpeechDetector.summary)) → discard")
                discardAskRecording()
                return
            }
            debugLog("ASK released before speech detected (\(askSpeechDetector.summary)) → recognize anyway")
        }
        askRecordingStartedAt = nil
        askAwaitingSpeech = false
        voiceQuestionMode = false
        let followUp = voiceQuestionFollowUp
        voiceQuestionFollowUp = false
        let continuesThread = followUp || askContinuesThread
        askContinuesThread = false
        answerPanel.setRecording(false)
        trialMaxRecordingTimer?.invalidate()
        trialMaxRecordingTimer = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingSession = nil
        isRecording = false
        resetHotkeyGestures()
        mouseHoldToTalkManager?.recordingDidLeaveActiveState()
        isProcessing = true
        statusBar.setTitle("VP⏳")
        if followUp { answerPanel.setListening(.processing) } else { overlayWindow.show(state: .processing(message: "→ AI")) }
        let noSpeech: () -> Void = { [weak self] in
            guard let self else { return }
            self.finishAsk()
            if speechUnconfirmed { return }
            if followUp { self.answerPanel.setListening(.noSpeech) } else { self.overlayWindow.showHint("没听到问题", accent: .neutral) }
        }
        let transcribeStartedAt = Date()
        audioRecorder.stopRecording { [weak self] samples in
            guard let self else { return }
            guard let samples, samples.count > 16000 / 2 else {
                DispatchQueue.main.async { noSpeech() }
                return
            }
            self.cloudTranscriber.transcribe(samples: samples) { [weak self] result in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let raw):
                        let spoken = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "。．.，,！!？?；;"))
                        // 浮窗还在但想换话题：用「新话题」开头，这几个字不算进问题里
                        let (question, wantsNewThread) = AskThreading.stripNewThreadPrefix(spoken)
                        let continuesThread = continuesThread && !wantsNewThread
                        guard !question.isEmpty else { noSpeech(); return }
                        self.askTiming.transcribeMs = Int(Date().timeIntervalSince(transcribeStartedAt) * 1000)
                        self.debugLog("ASK question chars=\(question.count) followUp=\(followUp) continuesThread=\(continuesThread)")
                        self.overlayWindow.hide()
                        self.answerPanel.setListening(.idle)
                        // 带不带历史和追加还是新开话题用同一个判断：识别期间浮窗被关掉了就是新话题，不能带旧历史
                        let appending = continuesThread && self.answerPanel.isVisible && !self.askInFlight
                        let history = appending ? self.answerPanel.history : []
                        // 面板上换成这一轮之前先换编号：上一轮还在路上的回调从这一刻起就不能再写进面板
                        self.askRound += 1
                        let round = self.askRound
                        if appending { self.answerPanel.appendQuestion(question) } else { self.answerPanel.startThread(question: question) }
                        // 图只随当轮发：历史里只留文字，多轮追问不重复传图，历史文件里更不会有截图
                        self.resolveAskScreen { screen, note in
                            self.sendAsk(question: question, history: history, screen: screen,
                                         screenNote: note, round: round)
                        }
                    case .failure(let err):
                        // 没听到有效语音：安静地提示一次，不走红框 + 文字条的两段式报错
                        if case CloudASRTranscriber.TranscriptionError.noSpeech = err { noSpeech(); return }
                        self.finishAsk()
                        self.answerPanel.setListening(.idle)
                        let message = (err as? LocalizedError)?.errorDescription ?? "识别失败"
                        self.showError(message)
                    }
                }
            }
        }
    }

    /// 把问题（可能带屏幕内容）发给模型，逐字流进面板。
    /// screenNote 非空 = 这次没能带屏幕内容，原因直接写在面板上，不静默。
    private func sendAsk(question: String,
                         history: [(question: String, answer: String)],
                         screen: AIPolisher.AskScreenContext?,
                         screenNote: String?,
                         round: Int) {
        let askStarted = Date()
        let thread = answerPanel.threadID
        askInFlight = true
        // 问题已经发出，回答在面板里流式显示：放开录音，别让所有快捷键在回答的十几秒里都没反应
        finishAsk()
        if let screenNote { answerPanel.setNote(screenNote) }

        // 首字迟迟不来就在面板里说一声，别让用户盯着「正在思考…」干等
        askSlowHintWork?.cancel()
        let slowHint = DispatchWorkItem { [weak self] in
            guard let self, self.askRound == round else { return }
            // 已经有「没能带屏幕内容」的提示时接在后面，别把原因顶掉
            let slow = "网络较慢，还在等模型回答…"
            self.answerPanel.setNote(screenNote.map { $0 + " " + slow } ?? slow)
        }
        askSlowHintWork = slowHint
        DispatchQueue.main.asyncAfter(deadline: .now() + AskVision.slowHintAfter, execute: slowHint)

        aiPolisher.answer(question: question, history: history, screen: screen, onPartial: { [weak self] partial in
            guard let self, self.askRound == round else { return }
            self.askSlowHintWork?.cancel()
            self.answerPanel.updatePartial(partial)
        }, onImages: { [weak self] images in
            // 只挂在还是这一话题、这一轮的浮窗上；用户已经问了下一题就丢掉
            guard let self, self.askRound == round, self.answerPanel.threadID == thread else { return }
            self.answerPanel.setImages(images)
        }, onRouteNote: { [weak self] note in
            // 这一问转去联网了：「正在联网查…」→ 出字后换成「已联网查询」。
            // 已经有「没能看屏幕」的说明时不盖掉它，那条对用户更要紧
            guard let self, screenNote == nil else { return }
            DispatchQueue.main.async {
                guard self.askRound == round else { return }
                self.answerPanel.setNote(note)
            }
        }, onThinking: { [weak self] in
            // 模型真的开始吐思考内容（关思考没生效）会先沉默一阵：告诉用户它在想，不是卡住了
            guard let self, screenNote == nil, self.askRound == round else { return }
            self.answerPanel.setNote(AskVision.thinkingNotice)
        }, onStats: { [weak self] stats in
            guard let self, self.askRound == round else { return }
            self.askTiming.modelStats = stats
        }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                // 用户已经问了下一题（另起了话题）：旧回答只记历史，不碰面板
                guard self.askRound == round else {
                    if case .success(let answer) = result {
                        self.aiPolisher.writeAskLog(question: question, answer: answer, thread: thread,
                                                    durationMs: Int(Date().timeIntervalSince(askStarted) * 1000))
                    }
                    return
                }
                self.askInFlight = false
                self.askSlowHintWork?.cancel()
                self.askSlowHintWork = nil
                let totalMs = Int(Date().timeIntervalSince(self.askTiming.startedAt) * 1000)
                switch result {
                case .success(let answer):
                    self.debugLog("ASK answered chars=\(answer.count) \(self.askTiming.summary(totalMs: totalMs))")
                    self.answerPanel.finish(answer: answer)
                    self.aiPolisher.writeAskLog(question: question, answer: answer, thread: thread,
                                                durationMs: Int(Date().timeIntervalSince(askStarted) * 1000))
                case .failure(let err):
                    let reason = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                    self.debugLog("ASK failed: \(reason) \(self.askTiming.summary(totalMs: totalMs))")
                    self.answerPanel.fail("回答失败：\(reason)")
                }
            }
        }
    }

    private func finishAsk() {
        isProcessing = false
        statusBar.setTitle("VP")
        if overlayWindow.capsuleCenterOnScreen != nil { overlayWindow.hide() }
    }

    /// 鼠标长按问 AI 的开口判定：听到说话才真正进入提问（收起旧回答、接管鼠标）
    func feedAskSpeechDetector(_ level: Float) {
        guard isRecording, voiceQuestionMode else { askAwaitingSpeech = false; return }
        guard askSpeechDetector.feed(level) else { return }
        askAwaitingSpeech = false
        debugLog("ASK speech detected (level \(String(format: "%.2f", level)); \(askSpeechDetector.summary))")
        if !answerPanel.isPinned { answerPanel.hide() }
        // 开口确认了才弹胶囊；先于接管按键，拖开取消 / 下拉锁定要用胶囊位置
        overlayWindow.show(state: .recording)
        mouseHoldToTalkManager?.askSpeechDetected()
    }

    /// 鼠标长按问 AI 在判断出开口前被拖动（是在 App 里选字）：当作没发生过——
    /// 收起胶囊、丢掉录音，不提示「没听到问题」、不给撤销、不调识别
    func discardAskRecording() {
        guard isRecording, voiceQuestionMode else { return }
        debugLog("ASK discarded before speech (\(askSpeechDetector.summary))")
        pendingAskScreen?.cancel()
        pendingAskScreen = nil
        pendingAskScreenNote = nil
        askRecordingStartedAt = nil
        askAwaitingSpeech = false
        askContinuesThread = false
        voiceQuestionMode = false
        voiceQuestionFollowUp = false
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
        statusBar.setTitle("VP")
        overlayWindow.hide()
        audioRecorder.stopRecording { _ in }
    }

    // MARK: - 指针问 AI

    /// 指针问 AI 开始：point 是 Quartz 全局坐标（原点左上），截图和画标记都用它。
    /// trigger：日志里的触发方式。captureScreen=false 是纯提问，不截屏。
    /// viaHotkey：键盘快捷键触发，胶囊从第一帧就带叉号和对勾。听写正录着时拒绝，不去动它。
    func beginAskAtCursor(at point: CGPoint, trigger: String = "cursor",
                          captureScreen: Bool = true, viaHotkey: Bool = false) -> Bool {
        guard !isRecording, !isProcessing else {
            debugLog("AC: begin refused (recording=\(isRecording) processing=\(isProcessing))")
            return false
        }
        let mode = AskAtCursorSettings.listenMode
        askTiming.reset(trigger: trigger, mode: viaHotkey ? "hotkey" : mode.rawValue)
        voiceQuestionFollowUp = false
        // 回答浮窗还在屏幕上（展开、小条、钉住都算）且话题还新鲜：接着聊。浮窗没了就是新话题
        askContinuesThread = answerPanel.canContinueThread
        voiceQuestionMode = true
        // 点击是明确意图，不用再等「听到开口」：胶囊立刻出来，用户知道已经在听
        askAwaitingSpeech = false
        askSpeechDetector = AskSpeechDetector()
        // 点一下开始的模式里手已经松开了，胶囊上给叉号和对勾，别让用户只能靠再点一下结束
        // 键盘触发和听写热键一样，从第一帧就是带叉号和对勾的大胶囊
        overlayWindow.recordingControls = (viaHotkey || mode == .clickToggle) ? .cancelAndFinish : .hidden
        guard startRecording() else {
            voiceQuestionMode = false
            askContinuesThread = false
            debugLog("AC: startRecording refused")
            return false
        }
        if captureScreen {
            startAskScreenCapture(at: point)
        } else {
            pendingAskScreen?.cancel()
            pendingAskScreen = nil
            pendingAskScreenNote = nil
            askTiming.fallback = "plain"
        }
        // 用户说话那几秒里把 TLS 握手做掉，首字能早几百毫秒
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.aiPolisher.warmUpConnection() }
        debugLog("AC: begin trigger=\(trigger) mode=\(viaHotkey ? "hotkey" : mode.rawValue) at \(Int(point.x)),\(Int(point.y))")
        return true
    }

    /// 悄悄丢掉正在录的听写：不识别、不粘贴、不提示、不给撤销。
    /// 用在听写热键刚按下就接了别的键（⌘C 这类组合键）的时候，那一小段本来就不是想说的话。
    func discardDictationSilently(reason: String) {
        guard isRecording, !voiceQuestionMode else { return }
        debugLog("Dictation discarded silently (\(reason))")
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
        statusBar.setTitle("VP")
        overlayWindow.hide()
        audioRecorder.stopRecording { _ in }
    }

    /// 触发瞬间就截图，画标记、缩放、编码全在后台队列，和用户说话并行。
    /// 没权限 / 关了开关时不截，提问照常走纯文本，并把原因留给面板提示。
    func startAskScreenCapture(at point: CGPoint) {
        pendingAskScreen?.cancel()
        pendingAskScreen = nil
        pendingAskScreenNote = nil
        guard AskAtCursorSettings.isScreenshotEnabled else {
            askTiming.fallback = "off"
            return
        }
        if let reason = aiPolisher.screenContextUnavailableReason() {
            askTiming.fallback = "hosted"
            debugLog("AC: screen context unavailable (hosted channel)")
            pendingAskScreenNote = reason
            return
        }
        guard ScreenSnapshotCapturer.hasPermission else {
            askTiming.fallback = "noPermission"
            pendingAskScreenNote = ScreenSnapshotError.noPermission.userMessage
            if !didPromptForScreenCapture {
                didPromptForScreenCapture = true
                debugLog("AC: screen recording permission missing → prompting once")
                // 第一次调会弹系统授权框；之前拒过就直接返回 false，这时才帮用户打开系统设置
                if !ScreenSnapshotCapturer.requestPermission() {
                    ScreenSnapshotCapturer.openSettings()
                }
            }
            return
        }
        pendingAskScreenNote = nil
        let pending = PendingAskScreen()
        pendingAskScreen = pending
        ScreenSnapshotCapturer.capture(at: point) { [weak self, weak pending] result in
            pending?.complete(result)
            if case .failure(let error) = result {
                self?.debugLog("AC: capture failed (\(error.debugName))")
            }
        }
    }

    /// 取图：好了就用，没好就等一会儿，等不到 / 失败就退回纯文本并把原因交给面板
    private func resolveAskScreen(_ callback: @escaping (AIPolisher.AskScreenContext?, String?) -> Void) {
        guard let pending = pendingAskScreen else {
            // 原因只用一次，免得下一问还挂着上一问的「没法看屏幕」
            let note = pendingAskScreenNote
            pendingAskScreenNote = nil
            callback(nil, note)
            return
        }
        pendingAskScreen = nil
        pending.onReady(timeout: 2.5) { [weak self] result in
            guard let self else { callback(nil, nil); return }
            switch result {
            case .success(let snapshot):
                self.askTiming.captureMs = snapshot.captureMs
                self.askTiming.encodeMs = snapshot.encodeMs
                self.askTiming.screenKB = (snapshot.overviewJPEG.count + snapshot.closeUpJPEG.count) / 1024
                callback(AIPolisher.AskScreenContext(overviewJPEG: snapshot.overviewJPEG,
                                                     closeUpJPEG: snapshot.closeUpJPEG), nil)
            case .failure(let error):
                self.askTiming.fallback = error.debugName
                callback(nil, error.userMessage)
            case nil:
                self.askTiming.fallback = "slowCapture"
                self.debugLog("AC: screenshot not ready in time → text only")
                callback(nil, "截屏没赶上，这次只按语音回答。")
            }
        }
    }
}
