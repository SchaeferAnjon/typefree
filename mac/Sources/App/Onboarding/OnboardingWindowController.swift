import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - Onboarding Window

/// 首次运行引导：欢迎 → 开启辅助功能（必做）→ 开启麦克风 → 全部就绪（试用期免配 API，直接开始用）。
/// 全部 UI 走 AppKit，避免新增源文件（项目源文件在 pbxproj 中显式列出）。
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    // 黑白清爽配色，与设置窗口一致；减少大面积灰底，保留绿色完成态。
    // 属性名保留（amber/badge… 只是历史命名，值已是中性灰，别"修"）。
    private enum Palette {
        static let accent = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255, alpha: 1)  // 近黑强调
        static let bg = NSColor.white
        static let card = NSColor.white
        static let text = NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255, alpha: 1)
        static let text2 = NSColor(srgbRed: 0x3F / 255, green: 0x3F / 255, blue: 0x43 / 255, alpha: 1)
        static let dotOff = NSColor(srgbRed: 0xE8 / 255, green: 0xE8 / 255, blue: 0xEA / 255, alpha: 1)
        static let amber = NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)   // 等待态文字＝中性灰
        static let green = NSColor(srgbRed: 0x2E / 255, green: 0x87 / 255, blue: 0x62 / 255, alpha: 1)   // 就绪绿（Mac 同款 #2E8762）
        // 图标徽章：轻量浅灰渐变
        static let badgeTop = NSColor(srgbRed: 0xF8 / 255, green: 0xF8 / 255, blue: 0xF9 / 255, alpha: 1)
        static let badgeBottom = NSColor(srgbRed: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF2 / 255, alpha: 1)
        // 绿色「完成」徽章渐变（保留：完成步骤的成功语义）
        static let badgeGreenTop = NSColor(srgbRed: 0xE4 / 255, green: 0xF5 / 255, blue: 0xEC / 255, alpha: 1)
        static let badgeGreenBottom = NSColor(srgbRed: 0xC9 / 255, green: 0xEB / 255, blue: 0xD8 / 255, alpha: 1)
        // 状态药丸底色：等待态＝轻浅灰；完成态＝浅绿（保留语义）
        static let pillAmberBg = NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF5 / 255, alpha: 1)
        static let pillGreenBg = NSColor(srgbRed: 0xE4 / 255, green: 0xF5 / 255, blue: 0xEC / 255, alpha: 1)
    }

    private weak var appDelegate: AppDelegate?

    private var window: NSWindow?
    private var pollTimer: Timer?
    private var step = 0
    private let stepCount = 4

    // 一次性自动推进的去抖标记
    private var didAutoAdvanceFromAccessibility = false
    private var didAutoAdvanceFromMic = false
    private var didAutoAdvanceFromAPI = false

    // 步骤内容容器（每次切步重建）
    private let stepDotsRow = NSStackView()
    private let contentBox = NSView()

    var isVisible: Bool { window?.isVisible ?? false }

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    // MARK: Presentation

    func present() {
        if window == nil { buildWindow() }
        step = 0
        didAutoAdvanceFromAccessibility = false
        didAutoAdvanceFromMic = false
        didAutoAdvanceFromAPI = false
        renderStep()
        startPolling()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Typefree"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.backgroundColor = Palette.bg

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 500))
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.bg.cgColor

        // 步骤指示点
        stepDotsRow.orientation = .horizontal
        stepDotsRow.spacing = 8
        stepDotsRow.translatesAutoresizingMaskIntoConstraints = false

        contentBox.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stepDotsRow)
        root.addSubview(contentBox)

        // 步骤点沉底（距底 ~22px），内容块在剩余空间内垂直+水平居中。
        NSLayoutConstraint.activate([
            stepDotsRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stepDotsRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),

            contentBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 44),
            contentBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -44),
            // 垂直居中于标题栏与步骤点之间的区域。
            contentBox.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            contentBox.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 48),
            contentBox.bottomAnchor.constraint(lessThanOrEqualTo: stepDotsRow.topAnchor, constant: -16),
        ])

        win.contentView = root
        window = win
    }

    // MARK: Step rendering

    private func renderStep() {
        rebuildDots()
        contentBox.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(stack)
        // stack 撑满 contentBox（contentBox 本身在窗口中垂直居中），保证内容块整体居中。
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentBox.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])

        switch step {
        case 0: buildWelcome(into: stack)
        case 1: buildAccessibility(into: stack)
        case 2: buildMicrophone(into: stack)
        default: buildDone(into: stack)
        }

        // 除欢迎页外，底部给一排导航：「← 上一步」+（非末步且条件满足）「下一步 →」。
        // 手动导航后关掉自动跳过，避免来回弹。
        if step > 0 {
            let nav = NSStackView()
            nav.orientation = .horizontal
            nav.spacing = 12
            nav.addArrangedSubview(makeTertiaryButton("← 上一步") { [weak self] in
                guard let self = self else { return }
                self.suspendAutoAdvance()
                self.goTo(step: self.step - 1)
            })

            // 末步（完成）用「开始使用」收尾，不放"下一步"；
            // 权限步必需授权，未授权时不放"下一步"（授权后会自动前进）。
            let isLastStep = (step >= stepCount - 1)
            if !isLastStep && currentStepSatisfied() {
                nav.addArrangedSubview(makeTertiaryButton("下一步 →") { [weak self] in
                    guard let self = self else { return }
                    self.suspendAutoAdvance()
                    self.goTo(step: self.step + 1)
                })
            }

            stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(nav)
        }
    }

    private func rebuildDots() {
        stepDotsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<stepCount {
            let dot = NSView()
            dot.wantsLayer = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            let active = (i == step)
            // 激活点为加长的橙色胶囊，其余为 7px 圆点。
            let height: CGFloat = 7
            let width: CGFloat = active ? 22 : 7
            dot.layer?.cornerRadius = height / 2
            dot.layer?.backgroundColor = (active ? Palette.accent : Palette.dotOff).cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: width),
                dot.heightAnchor.constraint(equalToConstant: height),
            ])
            stepDotsRow.addArrangedSubview(dot)
        }
    }

    // MARK: Step content builders

    private func buildWelcome(into stack: NSStackView) {
        stack.addArrangedSubview(makeBadge("🎙️"))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeTitle("欢迎使用 Typefree"))
        stack.addArrangedSubview(makeBody("按住快捷键说话，松手就贴上整理好的文字。简单几步就能开始。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makePrimaryButton("开始设置") { [weak self] in
            self?.goTo(step: 1)
        })
    }

    private func buildAccessibility(into stack: NSStackView) {
        stack.addArrangedSubview(makeBadge("🔑"))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeTitle("开启辅助功能"))
        stack.addArrangedSubview(makeBody("用于监听快捷键、把文字贴到光标处。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(makePrimaryButton("打开辅助功能设置") { [weak self] in
            self?.appDelegate?.openAccessibilitySettings()
        })

        let granted = appDelegate?.onboardingHasAccessibility() ?? false
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeStatusPill(granted ? "✓ 已授权" : "等待授权…", done: granted))
        // 该步骤强制：未授权无法继续，没有跳过按钮。
    }

    private func buildMicrophone(into stack: NSStackView) {
        stack.addArrangedSubview(makeBadge("🎤"))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeTitle("开启麦克风"))
        stack.addArrangedSubview(makeBody("用来录下你的声音，再转成文字。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)

        let authorized = appDelegate?.onboardingHasMicrophone() ?? false
        if authorized {
            stack.addArrangedSubview(makeStatusPill("✓ 已授权", done: true))
        } else {
            // 已拒绝时系统弹窗弹不出来，只能去系统设置开；未决则可直接弹授权框。
            let denied = appDelegate?.onboardingMicrophoneDenied() ?? false
            stack.addArrangedSubview(makePrimaryButton(denied ? "去系统设置开启" : "开启麦克风") { [weak self] in
                self?.appDelegate?.onboardingRequestMicrophone()
            })
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(makeStatusPill(denied ? "已拒绝 · 点上面到系统设置开启" : "等待授权…", done: false))
        }
    }

    private func buildDone(into stack: NSStackView) {
        // 试用期内无需配置 API（走内置试用通道），所以最后一步统一报「就绪」、不催填 key，
        // 直接告诉用户按哪个热键开始。试用到期再到「设置 → 模型」填自己的 key（永久免费）。
        // 和设置页同一个写法：设成「不设置」时不写旧键，只认左边那颗时照实写「左 Option」
        let disabled = RecordingHotkeyShortcut.isDisabled
        let hotkey = HotkeyArbiter.displayName(for: "recording", shortcut: disabled ? nil : RecordingHotkeyShortcut.current)
        let howToStart = disabled
            ? "到「设置」里给听写选一个快捷键，然后按住它说话"
            : "按住 \(hotkey) 说话"
        stack.addArrangedSubview(makeBadge("✓", green: true))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews.last!)
        // 自编译的开源版没有试用通道：得先填 Key 才能用，别报「就绪」
        let selfBuilt = !TrialManager.shared.isTrialAvailable
        stack.addArrangedSubview(makeTitle(selfBuilt ? "还差一步" : "全部就绪"))
        stack.addArrangedSubview(makeBody(selfBuilt
            ? "这个版本不含试用通道。先到「设置 → 模型」填入自己的 API Key，然后\(howToStart)。"
            : "\(howToStart)，松手就贴上整理好的文字。"))
        stack.setCustomSpacing(30, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makePrimaryButton("开始使用") { [weak self] in
            self?.finish()
        })
    }

    // MARK: Navigation

    private func goTo(step newStep: Int) {
        guard newStep != step else { return }
        step = max(0, min(stepCount - 1, newStep))
        renderStep()
    }

    /// 用户手动前后翻页后，关掉所有自动跳过，避免又被自动弹走。
    private func suspendAutoAdvance() {
        didAutoAdvanceFromAccessibility = true
        didAutoAdvanceFromMic = true
        didAutoAdvanceFromAPI = true
    }

    /// 当前步的"前进条件"是否满足（权限步需对应权限已授权）。
    private func currentStepSatisfied() -> Bool {
        switch step {
        case 1: return appDelegate?.onboardingHasAccessibility() ?? false
        case 2: return appDelegate?.onboardingHasMicrophone() ?? false
        default: return true
        }
    }

    private func finish() {
        appDelegate?.markOnboardingCompleted()
        stopPolling()
        window?.orderOut(nil)
        // 一律进首页：新用户走试用、无需配 key，不再把人甩到「模型」页填 key。
        // （3.0 起首页会先盖一层新手势演示，看完才进正式页面）
        appDelegate?.showSettingsCenter()
    }

    // MARK: Auto-detect polling

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        guard isVisible else { return }
        switch step {
        case 1:
            if appDelegate?.onboardingHasAccessibility() == true {
                // 刷新状态（renderStep 会读到最新值显示「✓ 已授权」）
                if !didAutoAdvanceFromAccessibility {
                    didAutoAdvanceFromAccessibility = true
                    renderStep()  // 先翻成绿色已授权
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self = self, self.step == 1 else { return }
                        self.goTo(step: 2)
                    }
                }
            }
        case 2:
            if appDelegate?.onboardingHasMicrophone() == true {
                if !didAutoAdvanceFromMic {
                    didAutoAdvanceFromMic = true
                    renderStep()  // 先翻成绿色已授权
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self = self, self.step == 2 else { return }
                        self.goTo(step: 3)
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    // MARK: UI factory helpers

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    /// 圆角渐变图标徽章（~72×72，圆角 ~20，柔和阴影），中间放 emoji 字形。
    private func makeBadge(_ glyph: String, green: Bool = false) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer?.cornerRadius = 20
        badge.layer?.masksToBounds = false

        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        gradient.cornerRadius = 20
        // 145° 对角渐变（左上 → 右下）
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        if green {
            gradient.colors = [Palette.badgeGreenTop.cgColor, Palette.badgeGreenBottom.cgColor]
        } else {
            gradient.colors = [Palette.badgeTop.cgColor, Palette.badgeBottom.cgColor]
        }
        badge.layer?.addSublayer(gradient)

        // 柔和阴影（尺寸固定 72×72，可直接给出 shadowPath 让阴影呈圆角矩形）
        let shadowColor = green ? Palette.green : Palette.accent
        badge.layer?.shadowColor = shadowColor.cgColor
        badge.layer?.shadowOpacity = green ? 0.16 : 0.18
        badge.layer?.shadowRadius = 8
        badge.layer?.shadowOffset = CGSize(width: 0, height: 3)
        badge.layer?.shadowPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: 72, height: 72),
            cornerWidth: 20, cornerHeight: 20, transform: nil
        )

        let glyphLabel = NSTextField(labelWithString: glyph)
        glyphLabel.font = .systemFont(ofSize: 32)
        glyphLabel.textColor = green ? Palette.green : Palette.accent
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(glyphLabel)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 72),
            badge.heightAnchor.constraint(equalToConstant: 72),
            glyphLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyphLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        return badge
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 23, weight: .heavy)
        label.textColor = Palette.text
        label.alignment = .center
        return label
    }

    private func makeBody(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        // 行高放宽（~1.7），更舒展。
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = 1.7
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: Palette.text2,
            .paragraphStyle: style,
        ])
        label.attributedStringValue = attr
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        return label
    }

    /// 状态药丸：等待 = 琥珀底，完成 = 绿底。
    private func makeStatusPill(_ text: String, done: Bool) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer?.cornerRadius = 13
        pill.layer?.backgroundColor = (done ? Palette.pillGreenBg : Palette.pillAmberBg).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = done ? Palette.green : Palette.amber
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return pill
    }

    private func makePrimaryButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title) { action() }
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        button.heightAnchor.constraint(equalToConstant: 94).isActive = true
        // 暖橙主色填充 + 白色标题（.rounded 按钮的 contentTintColor 管不到标题，必须用 attributedTitle）
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.bezelColor = Palette.accent
        button.contentTintColor = .white
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        ])
        // 柔和阴影
        button.layer?.shadowColor = Palette.accent.cgColor
        button.layer?.shadowOpacity = 0.22
        button.layer?.shadowRadius = 6
        button.layer?.shadowOffset = CGSize(width: 0, height: 3)
        button.layer?.masksToBounds = false
        return button
    }

    private func makeTertiaryButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title) { action() }
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = Palette.text2
        let attr = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.text2,
            .font: NSFont.systemFont(ofSize: 13),
        ])
        button.attributedTitle = attr
        return button
    }

    private func makeLinkButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title) { action() }
        button.isBordered = false
        button.bezelStyle = .inline
        let attr = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.accent,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        button.attributedTitle = attr
        return button
    }
}
