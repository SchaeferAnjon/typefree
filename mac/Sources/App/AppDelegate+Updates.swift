import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    /// 菜单栏「检查更新…」转发到 Sparkle。
    @objc func checkForUpdates(_ sender: Any?) {
        guard !AppBuild.isSelfBuilt, !AppIdentity.isDevBuild else { return }
        updateUserDriver.beginUserInitiatedCheck()
        updater.checkForUpdates()
    }

    func pendingUpdateInfo() -> TypefreeUpdateInfo? {
        updateUserDriver.updateInfo
    }

    func showUpdateDetails(_ sender: Any?) {
        updateUserDriver.presentUpdateDetails()
    }

    func installPendingUpdate() {
        updateUserDriver.installPendingUpdate()
    }

    /// Sparkle 即将为安装更新而重启本 App。此刻若有 sheet（如激活弹窗）开着，会阻止退出，
    /// 先把所有附着的模态 sheet 收掉，确保能顺利退出 → 替换 → 重启。
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        dismissAllAttachedSheets()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateUserDriver.captureInstallOnQuit(for: item, handler: immediateInstallHandler)
        return true
    }

    private func dismissAllAttachedSheets() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
    }
}
