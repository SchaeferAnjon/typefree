import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    /// 供引导窗口轮询读取的状态
    func onboardingHasAccessibility() -> Bool {
        textDelivery?.hasAccessibilityPermission() ?? false
    }

    func onboardingIsAPIConfigured() -> Bool {
        cloudTranscriber?.isConfigured() ?? false
    }

    func onboardingHasMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func onboardingMicrophoneDenied() -> Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    /// 引导里点"开启麦克风"：未决→弹系统授权框；已拒绝→打开系统设置。复用启动时同一逻辑。
    func onboardingRequestMicrophone() {
        requestMicrophonePermission()
    }

    func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(appDelegate: self)
        }
        onboardingController?.present()
    }

    func markOnboardingCompleted() {
        VoicePolishConfig.shared.save(bool: true, forKey: "onboarding_completed")
    }

    /// 引导窗口是否正在前台显示（用于避免重复弹辅助功能错误提示）
    var isOnboardingVisible: Bool {
        onboardingController?.isVisible ?? false
    }
}
