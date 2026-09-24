import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

@MainActor
final class TypefreeUpdateUserDriver: NSObject, SPUUserDriver {
    private weak var owner: AppDelegate?
    private var dialogController: TypefreeUpdateDialogController?
    private var userInitiatedCheck = false
    private var presentDetailsWhenReady = false
    private var autoInstallOnReady = false   // 用户主动更新：下载完直接安装重启（省二次点击）
    private var expectedDownloadLength: UInt64 = 0
    private var receivedDownloadLength: UInt64 = 0
    private var foundUpdateReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var installOnQuitHandler: (() -> Void)?
    private(set) var updateInfo: TypefreeUpdateInfo? {
        didSet {
            // 只在「状态」变化时广播：设置窗收到后会整个重建侧栏（含解密全部历史数行数）。
            // 下载进度每收到一块数据就更新一次，若也广播，几十 MB 的 DMG 下载期间
            // 会把设置窗主线程刷成转圈；进度由 refreshLiveDialog 单独刷到弹窗副标题。
            let changed: Bool
            switch (oldValue, updateInfo) {
            case (nil, nil): changed = false
            case let (old?, new?): changed = !new.sameState(as: old)
            default: changed = true
            }
            if changed {
                NotificationCenter.default.post(name: .typefreeUpdateStateDidChange, object: nil)
            }
        }
    }

    init(owner: AppDelegate) {
        self.owner = owner
        super.init()
    }

    func beginUserInitiatedCheck() {
        userInitiatedCheck = true
        presentDetailsWhenReady = false
    }

    func installPendingUpdate() {
        if let readyInstallReply {
            self.readyInstallReply = nil
            readyInstallReply(.install)
        } else if let installOnQuitHandler {
            self.installOnQuitHandler = nil
            installOnQuitHandler()
        } else if let foundUpdateReply {
            self.foundUpdateReply = nil
            foundUpdateReply(.install)
        } else if let url = updateInfo?.infoURL {
            NSWorkspace.shared.open(url)
        }
    }

    func presentUpdateDetails() {
        guard let info = updateInfo else {
            owner?.checkForUpdates(nil)
            return
        }

        let isError = info.errorMessage != nil
        let model = TypefreeUpdateDialogModel(
            badge: isError ? "ERROR" : "NEW",
            title: isError ? "更新检查遇到问题" : "发现新版本",
            subtitle: updateSummary(for: info),
            versionText: versionText(for: info),
            notesTitle: isError ? "错误信息" : "更新内容",
            notes: notesText(for: info),
            notesIsHTML: !isError,
            primaryTitle: primaryButtonTitle(for: info),
            secondaryTitle: (!info.isDownloading || info.isReadyToInstall) ? "稍后" : nil,
            primaryEnabled: true,
            isError: isError
        )
        showDialog(model: model) { [weak self] in
            guard let self else { return }
            if info.errorMessage != nil {
                self.owner?.checkForUpdates(nil)
            } else if info.isDownloading && !info.isReadyToInstall {
                return
            } else if info.infoURL != nil && self.readyInstallReply == nil && self.foundUpdateReply == nil && self.installOnQuitHandler == nil {
                if let url = info.infoURL { NSWorkspace.shared.open(url) }
            } else {
                self.installPendingUpdate()
            }
        }
    }

    func captureInstallOnQuit(for item: SUAppcastItem, handler: @escaping () -> Void) {
        installOnQuitHandler = handler
        updateInfo = makeInfo(from: item, isReady: true, isDownloading: false)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiatedCheck = true
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let infoOnly = appcastItem.isInformationOnlyUpdate
        let shouldPresentDetails = userInitiatedCheck
        updateInfo = makeInfo(from: appcastItem, isReady: state.stage != .notDownloaded || infoOnly, isDownloading: state.stage == .notDownloaded && !infoOnly)

        if infoOnly {
            foundUpdateReply = { _ in reply(.dismiss) }
            if shouldPresentDetails { presentUpdateDetails() }
            userInitiatedCheck = false
            return
        }

        switch state.stage {
        case .notDownloaded:
            presentDetailsWhenReady = shouldPresentDetails
            if shouldPresentDetails {
                // 用户主动检查：立刻弹进度对话框，下载完自动安装并重启（省去干等 + 二次点击）。
                autoInstallOnReady = true
                updateInfo?.isDownloading = true
                reply(.install)
                presentUpdateDetails()
            } else {
                // 后台自动发现：静默下载/解包，就绪后只亮 NEW 徽章，等用户主动点。
                reply(.install)
            }
        case .downloaded, .installing:
            foundUpdateReply = reply
            updateInfo?.isReadyToInstall = true
            updateInfo?.isDownloading = false
            if shouldPresentDetails { presentUpdateDetails() }
        @unknown default:
            foundUpdateReply = reply
        }
        userInitiatedCheck = false
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard var info = updateInfo else { return }
        let text: String
        if let encodingName = downloadData.textEncodingName,
           let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)) as UInt?,
           let decoded = String(data: downloadData.data as Data, encoding: String.Encoding(rawValue: encoding)) {
            text = decoded
        } else {
            text = String(data: downloadData.data as Data, encoding: .utf8) ?? info.releaseNotes
        }
        info = TypefreeUpdateInfo(
            title: info.title,
            displayVersion: info.displayVersion,
            buildVersion: info.buildVersion,
            releaseNotes: text,
            infoURL: info.infoURL,
            isReadyToInstall: info.isReadyToInstall,
            isDownloading: info.isDownloading,
            downloadProgress: info.downloadProgress,
            errorMessage: info.errorMessage
        )
        updateInfo = info
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // appcast 里的内联说明仍可展示；外链失败不打断更新。
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        updateInfo = nil
        if userInitiatedCheck {
            let model = TypefreeUpdateDialogModel(
                badge: "OK",
                title: "已是最新版本",
                subtitle: "当前没有可安装的新版本。",
                versionText: currentVersionText(),
                notesTitle: "更新状态",
                notes: "Typefree 会每天自动检查一次；有新版本时，左上角才会显示 NEW。",
                notesIsHTML: false,
                primaryTitle: "好",
                secondaryTitle: nil,
                primaryEnabled: true,
                isError: false
            )
            showDialog(model: model) {}
        }
        userInitiatedCheck = false
        presentDetailsWhenReady = false
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        let message = (error as NSError).localizedDescription
        updateInfo = TypefreeUpdateInfo(
            title: "更新检查失败",
            displayVersion: "",
            buildVersion: "",
            releaseNotes: "",
            infoURL: nil,
            isReadyToInstall: false,
            isDownloading: false,
            errorMessage: message
        )
        if userInitiatedCheck {
            presentUpdateDetails()
        }
        userInitiatedCheck = false
        presentDetailsWhenReady = false
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedDownloadLength = 0
        receivedDownloadLength = 0
        if var info = updateInfo {
            info.isDownloading = true
            info.isReadyToInstall = false
            info.downloadProgress = 0
            updateInfo = info
        }
        refreshLiveDialog()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength += length
        if var info = updateInfo {   // 单次赋值只发一条状态通知
            if expectedDownloadLength > 0 {
                info.downloadProgress = min(1.0, Double(receivedDownloadLength) / Double(expectedDownloadLength))
            }
            info.isDownloading = true
            updateInfo = info
        }
        refreshLiveDialog()
    }

    func showDownloadDidStartExtractingUpdate() {
        if var info = updateInfo {
            info.isDownloading = true
            info.downloadProgress = 1.0
            updateInfo = info
        }
        refreshLiveDialog(extracting: true)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        updateInfo?.isDownloading = true
        refreshLiveDialog(extracting: true)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateInfo?.isDownloading = false
        updateInfo?.isReadyToInstall = true
        if autoInstallOnReady {
            // 用户主动更新：下载完直接安装并重启，不再让用户点第二次。
            autoInstallOnReady = false
            presentDetailsWhenReady = false
            userInitiatedCheck = false
            refreshLiveDialog(installing: true)
            reply(.install)
            return
        }
        readyInstallReply = reply
        if userInitiatedCheck || presentDetailsWhenReady {
            presentUpdateDetails()
            userInitiatedCheck = false
            presentDetailsWhenReady = false
        }
    }

    /// 实时刷新当前对话框副标题（下载中显示百分比，解包/安装显示对应状态）。对话框没开则无操作。
    private func refreshLiveDialog(installing: Bool = false, extracting: Bool = false) {
        guard let controller = dialogController, let info = updateInfo else { return }
        let text: String
        if installing {
            text = "下载完成，正在安装并重启…"
        } else if extracting {
            text = "下载完成，正在准备安装…"
        } else if info.isReadyToInstall {
            text = "版本 \(info.displayVersion) 已准备好，可以安装并重启。"
        } else if info.isDownloading {
            let pct = Int((info.downloadProgress * 100).rounded())
            text = info.downloadProgress > 0 ? "正在下载更新 \(pct)%…" : "正在开始下载…"
        } else {
            text = updateSummary(for: info)
        }
        controller.applyLiveState(subtitle: text)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        updateInfo?.isReadyToInstall = false
        updateInfo?.isDownloading = false
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        updateInfo = nil
    }

    func dismissUpdateInstallation() {
        // Sparkle may call this after aborting/finishing. Keep downloaded-update info visible
        // until install starts so the NEW badge does not blink away during a deferred install.
    }

    func showUpdateInFocus() {
        presentUpdateDetails()
    }

    private func makeInfo(from item: SUAppcastItem, isReady: Bool, isDownloading: Bool) -> TypefreeUpdateInfo {
        TypefreeUpdateInfo(
            title: item.title ?? "Typefree 新版本",
            displayVersion: item.displayVersionString,
            buildVersion: item.versionString,
            releaseNotes: Self.releaseNotes(from: item),
            infoURL: item.infoURL,
            isReadyToInstall: isReady,
            isDownloading: isDownloading,
            errorMessage: nil
        )
    }

    private func updateSummary(for info: TypefreeUpdateInfo) -> String {
        if let error = info.errorMessage { return error }
        if info.isReadyToInstall {
            return "版本 \(info.displayVersion) 已准备好，可以安装并重启。"
        }
        if info.isDownloading {
            let pct = Int((info.downloadProgress * 100).rounded())
            return info.downloadProgress > 0
                ? "正在下载更新 \(pct)%，下载完成后会自动安装并重启。"
                : "正在下载更新，下载完成后会自动安装并重启。"
        }
        return "发现版本 \(info.displayVersion)。"
    }

    private func primaryButtonTitle(for info: TypefreeUpdateInfo) -> String {
        if info.errorMessage != nil { return "重新检查" }
        if info.infoURL != nil && readyInstallReply == nil && foundUpdateReply == nil && installOnQuitHandler == nil {
            return "查看详情"
        }
        if info.isDownloading && !info.isReadyToInstall { return "稍后" }
        return info.isReadyToInstall ? "安装并重启" : "后台下载中"
    }

    private func showDialog(model: TypefreeUpdateDialogModel,
                            onPrimary: @escaping () -> Void,
                            onSecondary: @escaping () -> Void = {}) {
        dialogController?.close()
        let controller = TypefreeUpdateDialogController(
            model: model,
            onPrimary: onPrimary,
            onSecondary: onSecondary,
            onClose: { [weak self] in
                guard let self else { return }
                self.dialogController = nil
                // 用户在下载中关掉进度窗（点「稍后」）→ 转为后台温和模式，不再自动重启，只留 NEW 徽章。
                if self.updateInfo?.isReadyToInstall == false, self.updateInfo?.isDownloading == true {
                    self.autoInstallOnReady = false
                    self.presentDetailsWhenReady = false
                }
            }
        )
        dialogController = controller
        controller.show()
    }

    private func versionText(for info: TypefreeUpdateInfo) -> String {
        if info.displayVersion.isEmpty {
            return currentVersionText()
        }
        if info.buildVersion.isEmpty || info.buildVersion == info.displayVersion {
            return "版本 \(info.displayVersion)"
        }
        return "版本 \(info.displayVersion)（\(info.buildVersion)）"
    }

    private func currentVersionText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "本地开发版"
        return "当前版本 \(version)"
    }

    private func notesText(for info: TypefreeUpdateInfo) -> String {
        if let error = info.errorMessage, !error.isEmpty {
            return error
        }
        let releaseNotes = info.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return releaseNotes.isEmpty ? "这次更新包含体验改进和问题修复。" : releaseNotes
    }

    private static func releaseNotes(from item: SUAppcastItem) -> String {
        if let desc = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc   // 保留 HTML 原文，弹窗用 ReleaseNotesRenderer 富文本渲染
        }
        if let url = item.releaseNotesURL {
            return "完整更新内容：\(url.absoluteString)"
        }
        return "这次更新包含体验改进和问题修复。"
    }

}
