import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    // MARK: - 反馈对话（SettingsWindowDelegate）

    func recentTargetAppName() -> String? { lastRecordingTargetApp }

    /// 开始过对话的设备每 5 分钟拉一次新回复；没开始过的一次网络请求都不发
    func startSupportPolling() {
        supportPollTimer?.invalidate()
        let timer = Timer(timeInterval: SupportChatService.pollInterval, repeats: true) { _ in
            guard SupportChatService.shared.hasThread else { return }
            SupportChatService.shared.sync()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        supportPollTimer = timer
        if SupportChatService.shared.hasThread {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { SupportChatService.shared.sync() }
        }
    }
}
