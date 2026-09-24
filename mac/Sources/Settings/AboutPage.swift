import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    // MARK: - Page: About

    func buildAbout(into stack: NSStackView) {
        stack.addArrangedSubview(pageHeader(eyebrow: "TYPEFREE / 关于", title: "关于",
                                             sub: "语音转文字，并用 AI 帮你整理成可直接使用的文本。"))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Logo card
        let card = makeCard()

        let logoBox = makeWaveformMark(box: 64, corner: 16, boxColor: theme.accent, waveColor: theme.onAccent)

        let name = label("Typefree", size: 22, weight: .semibold, color: theme.text)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "本地开发版"
        let sub = label("\(version) · macOS 状态栏应用", size: 13, weight: .regular, color: theme.text3)

        let logoStack = NSStackView()
        logoStack.orientation = .vertical
        logoStack.alignment = .centerX
        logoStack.spacing = 12
        logoStack.edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 28, right: 16)
        logoStack.addArrangedSubview(logoBox)
        logoStack.addArrangedSubview(name)
        logoStack.addArrangedSubview(sub)
        logoStack.setCustomSpacing(4, after: name)

        if LicenseManager.shared.isActivated {
            let license = LicenseManager.shared
            var status = "✓ 已激活"
            if license.isMember {
                status = license.isMemberExpired() ? "会员已到期" : "✓ 会员 · 有效期至 \(license.memberExpiresDay ?? "—")"
            }
            let actLbl = label(license.isGenesis ? "\(status) · 创世用户" : status, size: 12, weight: .regular, color: theme.text3)
            logoStack.addArrangedSubview(actLbl)
            logoStack.setCustomSpacing(12, after: sub)
        }

        let hasPendingUpdate: Bool
        if let updateInfo = settingsDelegate?.pendingUpdateInfo(), updateInfo.errorMessage == nil {
            hasPendingUpdate = true
        } else {
            hasPendingUpdate = false
        }
        if AppBuild.isSelfBuilt {
            // 自编版：不接官方更新（一更新改动就被官方包盖掉），把这件事写明白，别放一个点了会出事的按钮
            let note = label("自编版 · 基于官方 \(Bundle.main.appVersionString) 源码修改，不接收官方自动更新。\n要更新：在源码目录拉取上游改动、重新构建。",
                             size: 12, weight: .regular, color: theme.text3)
            note.alignment = .center
            note.maximumNumberOfLines = 0
            logoStack.addArrangedSubview(note)
            mount(logoStack, in: card)
            stack.addArrangedSubview(card)
            return
        }
        let updateButton = VPButton(title: hasPendingUpdate ? "查看新版本" : "检查更新…", style: .secondary, size: .regular,
                                    theme: theme, target: self, action: #selector(checkForUpdatesTapped(_:)))
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        logoStack.addArrangedSubview(updateButton)
        logoStack.setCustomSpacing(14, after: LicenseManager.shared.isActivated ? logoStack.arrangedSubviews[3] : sub)

        mount(logoStack, in: card)
        stack.addArrangedSubview(card)
    }

    @objc private func checkForUpdatesTapped(_ sender: NSButton) {
        if let updateInfo = settingsDelegate?.pendingUpdateInfo(), updateInfo.errorMessage == nil {
            settingsDelegate?.showUpdateDetails(sender)
        } else {
            settingsDelegate?.checkForUpdates(sender)
        }
    }
}
