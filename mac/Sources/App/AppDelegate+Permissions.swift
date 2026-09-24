import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    func requestMicrophonePermissionIfUndetermined() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    /// 用户主动点击（引导页「开启麦克风」）：未决→弹系统授权框；已拒绝→打开系统设置。
    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied, .restricted:
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        default:
            break
        }
    }

    /// 录音前看麦克风权限：拒绝过时引擎照样能开，但只录到静音，最后什么都不发生，用户不知道为什么。
    /// 没决定过就弹系统授权框，这一次先不录；拒绝过就说清楚并打开系统设置里的麦克风页。
    func hasMicrophonePermission(showFeedback: Bool) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return false
        case .denied, .restricted:
            debugLog("Microphone permission denied; recording refused")
            if showFeedback {
                overlayWindow.showHint("麦克风权限未开启 · 请在「系统设置 → 隐私与安全性 → 麦克风」里打开 Typefree")
                openMicrophoneSettings()
            }
            return false
        @unknown default:
            return true
        }
    }

    func canStartRecording(showFeedback: Bool) -> Bool {
        if isProcessing { return false }

        if processingMode.usesCloudTranscription && !cloudTranscriber.isConfigured() {
            if !LicenseManager.shared.isActivated {
                if TrialManager.shared.isInTrial {
                    // 7 天总额用完 = 试用结束（服务器会 429），别再上传音频白跑一趟
                    if TrialManager.shared.isTotalExhausted {
                        TrialManager.shared.refreshFromServer()   // 服务器可能调高/重置过额度，对一次账，下次按就能用
                        if showFeedback {
                            overlayWindow.showHint("试用额度已用完（7 天共 \(TrialManager.formatChars(TrialManager.shared.totalLimit)) 字）· 开通会员，或填自己的 Key 不限量")
                        }
                        return false
                    }
                    // 试用中：当日额度（缓存值，服务器才是权威）没满就放行；放行后不再走下面的免费额度检查。
                    if TrialManager.shared.usedToday >= TrialManager.shared.dailyLimit {
                        TrialManager.shared.refreshFromServer()   // 缓存可能旧了，顺手对一次账
                        if showFeedback {
                            overlayWindow.showHint("今日试用额度已用完（剩 \(TrialManager.shared.daysLeft) 天）· 开通会员或填自己的 Key 不限量")
                        }
                        return false
                    }
                    return true
                }
                if TrialManager.shared.trialExpired {
                    if showFeedback {
                        overlayWindow.showHint("试用已结束 · 开通会员，或在「设置 → 模型」填自己的 Key")
                    }
                    return false
                }
                if !TrialManager.shared.isTrialAvailable {
                    // 自己编译的开源版没有试用通道（试用地址不进公开仓库）：直接引导填 Key。
                    if showFeedback {
                        overlayWindow.showHint("请先在「设置 → 模型」里填入 API Key")
                    }
                    return false
                }
                // 试用还没拉到（首启刷新中 / 断网）→ 触发一次刷新并提示稍候。
                TrialManager.shared.refreshFromServer()
                if showFeedback {
                    overlayWindow.showHint("正在准备免费试用，请稍候…")
                }
                return false
            }
            // 已激活：年付会员走托管通道；老买断/赠送码需要自己的 Key
            let license = LicenseManager.shared
            if license.isMember && TrialManager.shared.isTrialAvailable {
                if license.isMemberExpired() {
                    if showFeedback {
                        overlayWindow.showHint("会员已到期 · 续费，或在「设置 → 模型」填自己的 Key")
                    }
                    return false
                }
                if license.hasActiveMembership() { return true }
                // 会员有效但手里还没有可用令牌（刚转成会员 / 很久没联网）→ 立刻复核一次；联不上就说清楚是网络
                license.revalidateNow { [weak self] ok in
                    guard let self, !ok, showFeedback else { return }
                    self.overlayWindow.showHint("无法连接激活服务，请检查网络后再试")
                }
                if showFeedback {
                    overlayWindow.showHint("正在验证会员状态，请稍候…")
                }
                return false
            }
            if showFeedback {
                overlayWindow.showHint("请先在「设置 → 模型」里填入 API key")
                debugLog("Cloud ASR unavailable: \(cloudTranscriber.missingConfigurationHint())")
            }
            return false
        }

        // 2026-09-14 起自带 Key 不再限每周字数（开源后限制形同虚设，且自带 Key 不花我们的钱）。
        return true
    }

    func updateAppReadiness() {
        updateAccessibilityDependentFeatures()

        if !isRecording && !isProcessing {
            statusBar.setTitle("VP")
        }
    }

    func updateAccessibilityDependentFeatures() {
        guard let textDelivery = textDelivery else { return }

        let hasAccessibility = textDelivery.hasAccessibilityPermission()
        debugLog("Accessibility trusted=\(hasAccessibility)")

        guard hasAccessibility else {
            hotkeyManager?.stop()
            hotkeyManager = nil
            askHotkeyManagers.forEach { $0.stop() }
            askHotkeyManagers = []
            mouseHoldToTalkManager?.stop()
            mouseHoldToTalkManager = nil
            startAccessibilityWatcher()
            if !isRecording && !isProcessing {
                statusBar.setTitle("VP!")
            }
            // 引导窗口正在前台时，由引导负责索要辅助功能权限，避免重复弹窗/提示
            if isOnboardingVisible {
                debugLog("Accessibility not granted yet; onboarding owns the prompt")
                return
            }
            if !didPromptForAccessibility {
                _ = textDelivery.hasAccessibilityPermission(promptIfNeeded: true)
                didPromptForAccessibility = true
            }
            if !didReportMissingAccessibility {
                debugLog("Accessibility not granted yet; skipping global hotkey listener")
                showError("请授予辅助功能权限以启用快捷键")
                didReportMissingAccessibility = true
            }
            return
        }

        didPromptForAccessibility = false
        didReportMissingAccessibility = false
        ensureHotkeyManager()
    }

    /// 辅助功能未授权时每 2 秒检测一次；用户在系统设置里一打开就立刻接管快捷键，
    /// 不用重启 App（事件监听是授权后新建的，能直接生效）。
    private func startAccessibilityWatcher() {
        guard axPollTimer == nil else { return }
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self,
                  self.textDelivery?.hasAccessibilityPermission() == true else { return }
            self.axPollTimer?.invalidate()
            self.axPollTimer = nil
            self.debugLog("Accessibility granted while running; enabling hotkey without restart")
            self.updateAppReadiness()
            NotificationCenter.default.post(name: .voicePolishAccessibilityGranted, object: nil)
            // 引导窗口在场时由引导自己反馈，不重复弹提示
            if !self.isOnboardingVisible {
                self.overlayWindow.showHint("辅助功能已开启，现在可以用快捷键录音了", accent: .success)
            }
        }
    }

    func openAccessibilitySettings() {
        textDelivery?.openAccessibilitySettings()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
