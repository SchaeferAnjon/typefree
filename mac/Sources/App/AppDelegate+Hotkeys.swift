import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    func ensureHotkeyManager() {
        guard hotkeyManager == nil else { return }

        debugLog("Model ready, starting hotkey listener")
        hotkeyManager = HotkeyManager(
            onStart: { [weak self] in
                guard let self else { return false }
                // 键盘触发一律从第一帧就显示大胶囊（叉号 + 对勾），单击、长按统一，中途不变形（Ray 2026-09-11 拍板）。
                // 长按时松手照常结束、Esc 照常取消；鼠标长按说话仍是小胶囊，不受影响。
                self.overlayWindow.recordingControls = .cancelAndFinish
                return self.startRecording()
            },
            onStop: { [weak self] in
                // 问 AI 的录音只由问 AI 自己的快捷键、胶囊按钮或 Esc 结束，碰到听写键不能把问题提前发出去
                guard let self, !self.voiceQuestionMode else { return }
                self.stopRecordingAndProcess()
            },
            // 只认听写的录音，和问 AI 那边对称
            isRecording: { [weak self] in self?.isRecording == true && self?.voiceQuestionMode == false }
        )
        hotkeyManager.debugLog = { [weak self] msg in
            self?.debugLog("HK: \(msg)")
        }
        // 键盘触发的胶囊不再按单击/长按切换大小，这里不用改按钮
        hotkeyManager.onGestureClassified = { _ in }
        hotkeyManager.onCancel = { [weak self] in self?.cancelRecording() }
        // ⌘C、⇧ 打大写这类组合键：刚开的那一小段录音直接丢，不弹「已取消 · 撤销」
        hotkeyManager.onChordCancel = { [weak self] in self?.discardDictationSilently(reason: "chord") }
        ensureMouseHoldToTalkManager()
        // 「修饰键 + 点击」问 AI 已下线（要接管全系统鼠标点击），提问只走键盘快捷键
        ensureAskHotkeyManagers()
    }

    func resetHotkeyGestures() {
        hotkeyManager?.recordingDidLeaveActiveState()
        askHotkeyManagers.forEach { $0.recordingDidLeaveActiveState() }
    }

    // MARK: - 问 AI 的键盘快捷键

    /// 两套：看屏幕问（按下那一刻鼠标指在哪，截图上的标记就在哪）和纯提问（不截屏）。
    /// 手势和听写热键完全一样：按住说、松开结束；轻点一下锁定、再点一下结束；按住期间 Esc 取消。
    private func ensureAskHotkeyManagers() {
        guard askHotkeyManagers.isEmpty else { return }
        for (hotkey, captureScreen) in [(AskHotkey.screen, true), (AskHotkey.plain, false)] {
            let manager = HotkeyManager(
                profile: .ask(hotkey),
                onStart: { [weak self] in
                    guard let self else { return false }
                    // 鼠标此刻的位置（Quartz 全局坐标，原点左上），截图标记画在这里
                    let point = CGEvent(source: nil)?.location ?? .zero
                    return self.beginAskAtCursor(at: point, trigger: captureScreen ? "hotkey-screen" : "hotkey-plain",
                                                 captureScreen: captureScreen, viaHotkey: true)
                },
                onStop: { [weak self] in
                    guard let self, self.isRecording, self.voiceQuestionMode else { return }
                    self.stopRecordingAndAsk()
                },
                // 只认问 AI 的录音：听写录着的时候按问 AI 的键，不能把听写当成自己的给停了
                isRecording: { [weak self] in self?.isRecording == true && self?.voiceQuestionMode == true }
            )
            manager.debugLog = { [weak self] msg in self?.debugLog("AK[\(hotkey.prefix)]: \(msg)") }
            manager.onGestureClassified = { _ in }
            manager.onCancel = { [weak self] in
                guard let self, self.isRecording, self.voiceQuestionMode else { return }
                self.discardAskRecording()
            }
            askHotkeyManagers.append(manager)
            debugLog("AK[\(hotkey.prefix)]: shortcut=\(hotkey.displayName) active=\(hotkey.isActive)\(hotkey.conflict.map { " conflict=\($0)" } ?? "")")
        }
    }

    /// 鼠标长按说话：监听器常驻，开关状态在每次按下时读取，设置里切换立即生效、无需重建
    private func ensureMouseHoldToTalkManager() {
        guard mouseHoldToTalkManager == nil else { return }
        let manager = MouseHoldToTalkManager(
            onStart: { [weak self] in
                guard let self else { return false }
                self.overlayWindow.recordingControls = .hidden   // 松手即完成、拖开即取消，不需要按钮
                guard self.startRecording() else { return false }
                let hintKey = "MouseHoldCapsuleLockHintShownCount"
                let shown = UserDefaults.standard.integer(forKey: hintKey)
                if shown < 3 {
                    UserDefaults.standard.set(shown + 1, forKey: hintKey)
                    self.overlayWindow.showRecordingCaption("移近锁定", seconds: 1.8)
                }
                return true
            },
            onStop: { [weak self] in self?.stopRecordingAndProcess() },
            isRecording: { [weak self] in self?.isRecording == true }
        )
        manager.debugLog = { [weak self] msg in
            self?.debugLog("MH: \(msg)")
        }
        manager.onCancel = { [weak self] in self?.cancelRecording() }
        manager.onLock = { [weak self] in
            self?.overlayWindow.setRecordingLocked(true)
        }
        overlayWindow.onLockedDragStart = { [weak manager] point in
            manager?.beginLockedCapsuleDrag(at: point) ?? false
        }
        overlayWindow.onLockedDragUpdate = { [weak manager] point in
            manager?.updateLockedCapsuleDrag(at: point)
        }
        overlayWindow.onLockedDragEnd = { [weak manager] point in
            manager?.endLockedCapsuleDrag(at: point)
        }
        AnswerPanel.log = { [weak self] in self?.debugLog($0) }
        answerPanel.isAskPending = { [weak self] in self?.askAwaitingSpeech == true }
        answerPanel.onFollowUpStart = { [weak self] in
            // 上一轮还在出字时接不上话：等它答完再按住续聊
            guard let self, !self.isRecording, !self.isProcessing, !self.askInFlight else { return false }
            self.voiceQuestionMode = true
            self.voiceQuestionFollowUp = true
            self.overlayWindow.recordingControls = .hidden
            guard self.startRecording(feedback: false) else { self.voiceQuestionMode = false; self.voiceQuestionFollowUp = false; return false }
            // 在面板上续聊：屏幕上此刻就是那张面板，没必要再截一次
            self.pendingAskScreen?.cancel()
            self.pendingAskScreen = nil
            self.pendingAskScreenNote = nil
            self.askTiming.reset(trigger: "follow-up", mode: "panel")
            self.answerPanel.setRecording(true)
            return true
        }
        answerPanel.onFollowUpEnd = { [weak self] cancelled in
            guard let self else { return }
            self.answerPanel.setRecording(false)
            if cancelled { self.cancelRecording() } else { self.stopRecordingAndProcess() }
        }
        manager.onStartAsk = { [weak self] in
            guard let self else { return false }
            guard MouseHoldToTalkSettings.isAskEnabled else { return false }
            // 旧回答面板等用户开口再收起（feedAskSpeechDetector）：误触时什么都不动
            self.voiceQuestionFollowUp = false
            self.askContinuesThread = false
            self.voiceQuestionMode = true
            self.voiceQuestionAnchor = NSEvent.mouseLocation
            self.askAwaitingSpeech = true
            self.askSpeechDetector = AskSpeechDetector()
            self.overlayWindow.recordingControls = .hidden
            guard self.startRecording(feedback: false) else { self.voiceQuestionMode = false; self.askAwaitingSpeech = false; return false }
            // 空白处长按问 AI 也带屏幕内容，和指针问 AI 同一套逻辑
            self.askTiming.reset(trigger: "hold-blank", mode: "hold")
            self.startAskScreenCapture(at: CGEvent(source: nil)?.location ?? .zero)
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.aiPolisher.warmUpConnection() }
            return true
        }
        manager.onAbortAsk = { [weak self] in self?.discardAskRecording() }
        // 新手势演示盖在设置窗上时，「试一试」输入框要能按住说话：只对那个窗口放行
        manager.guideWindowNumber = { SettingsWindowController.shared?.guideWindowNumber }
        manager.capsuleCenterProvider = { [weak self] in self?.overlayWindow.capsuleCenterOnScreen }
        manager.capsuleFrameProvider = { [weak self] in self?.overlayWindow.capsuleFrameOnScreen }
        manager.onHoldGestureUpdate = { [weak self] gesture in
            self?.overlayWindow.setCancelArmed(gesture.armed)
        }
        manager.onHoldGestureEnded = { [weak self] _ in
            self?.overlayWindow.endCancelGesture()
            self?.overlayWindow.setRecordingLocked(false)
        }
        mouseHoldToTalkManager = manager
        debugLog("MH: listening=\(manager.isListening) enabled=\(MouseHoldToTalkSettings.isEnabled)")
    }
}
