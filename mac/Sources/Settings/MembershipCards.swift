import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    /// 侧边栏底部额度升级卡片（仅未激活时显示，激活后消失）。
    /// 标题 + 今日额度进度条 + 说明 + 墨黑升级按钮；点击任意处弹出激活窗。
    func makeSidebarUpgradeButton() -> NSView? {
        // 填了自己识别 Key 的人：不管服务器有没有给他起试用，他走的是直连，显示自带 Key 卡
        if CloudASRTranscriber().isConfigured() && TrialManager.shared.isTrialAvailable {
            return makeSidebarUpgradeButtonBYOK()
        }
        if TrialManager.shared.isInTrial && !TrialManager.shared.isTotalExhausted {
            return makeSidebarUpgradeButtonTrial()
        } else if TrialManager.shared.trialExpired || TrialManager.shared.isTotalExhausted {
            return makeSidebarUpgradeButtonExpired()
        } else if TrialManager.shared.isTrialAvailable {
            return makeSidebarUpgradeButtonBYOK()
        }
        return nil   // 自己编译的开源版没有托管服务，不推会员
    }

    /// 侧边栏卡片——会员续费提醒：一次性年卡/赠送的会员 14 天内到期时出现；自动续费的到期前不打扰，
    /// 真到期（续费失败）才出现。整卡点击 → 定价页。
    func makeSidebarMemberRenewalCard() -> NSView? {
        let license = LicenseManager.shared
        guard license.isMember, TrialManager.shared.isTrialAvailable else { return nil }
        // 填了自己的 Key 且没选「优先走会员」的人（创世用户默认如此），会员到不到期都不影响使用，不催
        if CloudASRTranscriber().isConfigured() && !HostedRoute.memberFirst { return nil }
        let expired = license.isMemberExpired()
        let daysLeft = license.memberDaysLeft() ?? 0
        guard expired || (!license.memberAutoRenew && daysLeft <= 14) else { return nil }

        let card = makeUpgradeCard()
        let title = label(expired ? "会员已到期" : "会员还剩 \(daysLeft) 天", size: 13.5, weight: .semibold, color: theme.text)
        let sub = label(expired ? "续费后继续免配置使用；也可以在「模型」填入自己的 Key，永久免费。"
                                : "有效期至 \(license.memberExpiresDay ?? "—")。到期后可续费，或在「模型」填入自己的 Key。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0
        let btn = makeSolidButton(title: "续费 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    /// 侧边栏卡片——试用中状态。
    private func makeSidebarUpgradeButtonTrial() -> NSView {
        // 对用户只讲一个数：7 天总额。用服务器记的 totalUsed，
        // 而非 InputStats 的本地输入统计——后者含非试用使用，会显示超额。
        let used = TrialManager.shared.totalUsed
        let trialLimit = TrialManager.shared.displayTotalLimit
        let ratio = max(min(CGFloat(used) / CGFloat(trialLimit), 1), 0.001)
        let limitStr = TrialManager.formatChars(trialLimit)

        // 注意：这里不要向服务器刷新试用状态——本函数在每次 rebuildSidebar 时都会跑，
        // 而 rebuildSidebar 会被多种通知触发；刷新统一放在 App 激活时（appDidBecomeActive）做一次。

        let card = makeUpgradeCard()

        // 标题行：「免费试用中」（左）+ 「剩 N 天」（右）
        let titleLbl = label("免费试用中", size: 13.5, weight: .semibold, color: theme.text)
        let daysLbl = label("剩 \(TrialManager.shared.daysLeft) 天", size: 12, weight: .semibold, color: theme.text2)
        daysLbl.setContentHuggingPriority(.required, for: .horizontal)
        let titleSpacer = NSView()
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.addArrangedSubview(titleLbl)
        titleRow.addArrangedSubview(titleSpacer)
        titleRow.addArrangedSubview(daysLbl)

        // 数字行：已用 3,200 / 10,000 字
        let (numRow, track) = makeProgressNumRow(usedStr: TrialManager.formatChars(used), limitStr: limitStr, ratio: ratio)

        // 说明
        let sub = label("7 天共 \(limitStr) 字，用完或到期后可开通会员，或填自己的 Key 永久免费。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0

        // Ghost 按钮（白底 + 边框 + 深色文字）
        let btn = makeGhostButton(title: "查看方案 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(titleRow)
        stack.setCustomSpacing(9, after: titleRow)
        stack.addArrangedSubview(numRow)
        stack.setCustomSpacing(7, after: numRow)
        stack.addArrangedSubview(track)
        stack.setCustomSpacing(11, after: track)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            numRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            track.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    /// 侧边栏卡片——试用已结束状态。
    private func makeSidebarUpgradeButtonExpired() -> NSView {
        let card = makeUpgradeCard()

        // 额度先用完（还没满 7 天）和到期是两回事，分开说，免得用户以为「怎么没到 7 天就结束了」
        let quotaUsedUp = TrialManager.shared.isTotalExhausted && !TrialManager.shared.trialExpired
        let title = label(quotaUsedUp ? "免费试用额度已用完" : "免费试用已结束",
                          size: 13.5, weight: .semibold, color: theme.text)

        let lead = quotaUsedUp ? "7 天共 \(TrialManager.formatChars(TrialManager.shared.displayTotalLimit)) 字已用完。" : ""
        let sub = label(lead + "开通会员直接用；或在「模型」填入自己的 Key，永久免费。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0

        // 墨黑按钮 → 定价页（整张卡点击同去）：两条路都在那里
        let btn = makeSolidButton(title: "查看方案 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    /// 侧边栏卡片——自带 Key 状态。2026-09-14 起不再限每周字数，只留一个温和的会员入口；
    /// 已激活后整张卡不显示。
    private func makeSidebarUpgradeButtonBYOK() -> NSView {
        let card = makeUpgradeCard()

        let title = label("自带 Key · 永久免费", size: 13.5, weight: .semibold, color: theme.text)

        let sub = label("不限字数、不限时间。不想折腾 Key？开通会员，装好就能用。",
                        size: 11.5, weight: .regular, color: theme.text2)
        sub.maximumNumberOfLines = 0

        let btn = makeGhostButton(title: "了解会员 →")

        let stack = makeUpgradeStack(card: card)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(btn)
        NSLayoutConstraint.activate([
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            btn.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        finishUpgradeCard(card: card, stack: stack)
        return card
    }

    // MARK: Upgrade card helpers

    /// 创建卡片容器（圆角、边框、背景）。
    private func makeUpgradeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.setAppearanceBackground(theme.cardAlt)
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.setAppearanceBorder(theme.sep)
        return card
    }

    /// 创建卡片内的垂直 stack（14pt insets）。
    private func makeUpgradeStack(card: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return stack
    }

    /// 将 stack 嵌入 card 并绑定四边，同时挂上点击手势。
    private func finishUpgradeCard(card: NSView, stack: NSStackView, action: Selector = #selector(upgradeSidebarTapped)) {
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: action)
        card.addGestureRecognizer(click)
    }


    /// 进度数字行（已用 N / Limit 字 ⓘ）+ 进度条，返回两个视图。
    private func makeProgressNumRow(usedStr: String, limitStr: String, ratio: CGFloat)
        -> (numRow: NSStackView, track: NSView) {
        let prefix = label("已用", size: 11.5, weight: .regular, color: theme.text3)
        prefix.setContentHuggingPriority(.required, for: .horizontal)
        let num = label("\(usedStr) / \(limitStr)", size: 13, weight: .semibold, color: theme.text)
        num.setContentHuggingPriority(.required, for: .horizontal)
        let unit = label("字", size: 11.5, weight: .regular, color: theme.text3)
        unit.setContentHuggingPriority(.required, for: .horizontal)
        let info = NSImageView()
        info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "额度说明")
        info.contentTintColor = theme.text3
        info.toolTip = "试用 7 天内共 \(limitStr) 字，不按天重置；用完或满 7 天试用结束"
        info.translatesAutoresizingMaskIntoConstraints = false
        info.widthAnchor.constraint(equalToConstant: 13).isActive = true
        info.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let numSpacer = NSView()
        let numRow = NSStackView()
        numRow.orientation = .horizontal
        numRow.alignment = .centerY
        numRow.spacing = 4
        numRow.addArrangedSubview(prefix)
        numRow.addArrangedSubview(num)
        numRow.addArrangedSubview(unit)
        numRow.addArrangedSubview(numSpacer)
        numRow.addArrangedSubview(info)

        let track = NSView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true
        track.layer?.setAppearanceBackground(Self.meterTrack)
        track.layer?.cornerRadius = 3
        let fill = NSView()
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.setAppearanceBackground(theme.accent)
        fill.layer?.cornerRadius = 3
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: ratio),
        ])
        return (numRow, track)
    }

    /// 墨黑实心按钮。
    private func makeSolidButton(title: String) -> NSView {
        let btn = NSView()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.wantsLayer = true
        btn.layer?.setAppearanceBackground(theme.accent)
        btn.layer?.cornerRadius = 9
        let lbl = label(title, size: 13, weight: .semibold, color: theme.onAccent)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(lbl)
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 34),
            lbl.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])
        return btn
    }

    /// Ghost 按钮（白底 + sep 边框 + 深色文字）。
    private func makeGhostButton(title: String) -> NSView {
        let btn = NSView()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.wantsLayer = true
        btn.layer?.setAppearanceBackground(theme.card)
        btn.layer?.cornerRadius = 9
        btn.layer?.borderWidth = 1
        btn.layer?.setAppearanceBorder(theme.sep)
        let lbl = label(title, size: 13, weight: .semibold, color: theme.text)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(lbl)
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 34),
            lbl.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])
        return btn
    }

    @objc private func upgradeSidebarTapped() {
        showUpgradeSheet()
    }

    /// 弹出完整定价页（三种用法卡片 + FAQ + 保留授权码激活）。激活成功后窗口关闭、侧边栏按钮消失。
    private func showUpgradeSheet() {
        guard let host = window, upgradeSheet == nil else { return }

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheet.title = "Typefree"
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        upgradeSheet = sheet

        let cv = AppearanceObservingView()
        cv.wantsLayer = true
        cv.layer?.setAppearanceBackground(theme.bg)
        sheet.contentView = cv

        // 内容较高，整页放进可滚动容器，窗口再矮也能看全 FAQ。
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        cv.addSubview(scroll)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        // Header（居中标题 + 副标题）
        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 8
        let title = label("Typefree · 自然说话，清楚输入", size: 21, weight: .bold, color: theme.text)
        title.alignment = .center
        // 开源（Ray 2026-09-14：付费页要凸显开源）：软件本身开源免费，会员买的是免配置的服务
        let ossRow = NSStackView()
        ossRow.orientation = .horizontal
        ossRow.alignment = .centerY
        ossRow.spacing = 8
        ossRow.addArrangedSubview(makeDarkTag("开源"))
        ossRow.addArrangedSubview(label("软件开源、永久免费；会员买的是免配置的识别和润色服务", size: 13, weight: .regular, color: theme.text2))
        ossRow.addArrangedSubview(makeLinkButton(title: "查看源码 →", urlString: AppLinks.sourceCodeURL))
        headerStack.addArrangedSubview(title)
        headerStack.addArrangedSubview(ossRow)
        stack.addArrangedSubview(headerStack)
        stack.setCustomSpacing(28, after: headerStack)

        // 三张等高卡片
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.distribution = .fillEqually
        cards.spacing = 18
        cards.addArrangedSubview(makeTrialPricingCard())
        cards.addArrangedSubview(makeBuyPricingCard())
        cards.addArrangedSubview(makeBYOKPricingCard())
        stack.addArrangedSubview(cards)
        stack.setCustomSpacing(26, after: cards)

        // 激活行（次要：已经购买过 → 粘贴授权码激活）
        let activateBlock = makeActivateBlock()
        stack.addArrangedSubview(activateBlock)
        stack.setCustomSpacing(34, after: activateBlock)

        // FAQ
        let faq = makeFAQBlock()
        stack.addArrangedSubview(faq)

        scroll.documentView = doc

        // 右上角关闭按钮（Esc 同样可关）——sheet 没有系统红绿灯，必须自己给出口
        let closeBtn = NSButton()
        closeBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
        closeBtn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        closeBtn.isBordered = false
        closeBtn.contentTintColor = theme.text3
        closeBtn.target = self
        closeBtn.action = #selector(upgradeSheetCloseTapped)
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: cv.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // 内容整体居中，最宽 1000，左右各留 30 边距
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -44),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -30),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1000),
            headerStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cards.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activateBlock.widthAnchor.constraint(equalTo: stack.widthAnchor),
            faq.widthAnchor.constraint(equalTo: stack.widthAnchor),   // FAQ 用满三卡总宽，两列铺开
            closeBtn.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            closeBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
        ])

        host.beginSheet(sheet, completionHandler: nil)
    }

    // MARK: Pricing page pieces

    /// 软标签（浅灰底 + text2 文字），如「新用户」「自带 Key」「永久免费」。
    func makeSoftTag(_ text: String) -> NSView { makeTag(text, bg: Self.softFill, fg: theme.text3) }

    /// 深标签（强调色底 + onAccent 文字），如「推荐」。
    private func makeDarkTag(_ text: String) -> NSView { makeTag(text, bg: theme.accent, fg: theme.onAccent) }

    func makeTag(_ text: String, bg: NSColor, fg: NSColor, size: CGFloat = 11) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.setAppearanceBackground(bg)
        let l = label(text, size: size, weight: .semibold, color: fg)
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        let hPad: CGFloat = size < 11 ? 7 : 8
        let vPad: CGFloat = size < 11 ? 2.5 : 2
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: hPad),
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -hPad),
            l.topAnchor.constraint(equalTo: v.topAnchor, constant: vPad),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -vPad),
        ])
        return v
    }

    /// 卡片里的一条 ✓ 功能行；strongPrefix 加粗、muted 用浅色。
    private func makeFeatureRow(_ text: String, strongPrefix: String? = nil, muted: String? = nil) -> NSView {
        let check = label("✓", size: 13, weight: .semibold, color: theme.text)
        check.setContentHuggingPriority(.required, for: .horizontal)

        let body = NSTextField(labelWithString: "")
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isSelectable = false
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        let attr = NSMutableAttributedString()
        if let sp = strongPrefix {
            attr.append(NSAttributedString(string: sp, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: theme.text]))
        }
        attr.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: theme.text]))
        if let m = muted {
            attr.append(NSAttributedString(string: m, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: theme.text2]))
        }
        body.attributedStringValue = attr

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 9
        row.addArrangedSubview(check)
        row.addArrangedSubview(body)
        return row
    }

    /// 灰色「当前/禁用」按钮（浅灰底 + text3 文字，不可点击），对应设计稿 .btn.cur。
    private func makeCurrentButton(title: String) -> NSView {
        let btn = NSView()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.wantsLayer = true
        btn.layer?.setAppearanceBackground(Self.softFill)
        btn.layer?.cornerRadius = 9
        let lbl = label(title, size: 13, weight: .semibold, color: theme.text3)
        lbl.alignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(lbl)
        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 40),
            lbl.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
        ])
        return btn
    }

    /// 卡片外壳：圆角白卡，highlighted 时描 2px 近黑边。内部把传入的子视图竖排。
    private func makePricingCard(highlighted: Bool, content: (NSStackView) -> Void) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.setAppearanceBackground(theme.card)
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = highlighted ? 2 : 1
        card.layer?.setAppearanceBorder((highlighted ? theme.accent : theme.sep))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 22, bottom: 24, right: 22)
        content(stack)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        return card
    }

    /// 卡片名称行：名字 + 若干标签。
    private func makeCardNameRow(_ name: String, tags: [NSView]) -> NSView {
        let nameLbl = label(name, size: 17, weight: .semibold, color: theme.text)
        nameLbl.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(nameLbl)
        tags.forEach { row.addArrangedSubview($0) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    /// 卡①：免费试用（状态自适应按钮）。
    private func makeTrialPricingCard() -> NSView {
        makePricingCard(highlighted: false) { stack in
            let nameRow = makeCardNameRow("免费试用", tags: [makeSoftTag("新用户")])
            let price = makePriceRow(main: "免费", per: "· 7 天")
            let desc = label("下载即用，零配置", size: 13, weight: .regular, color: theme.text2)

            let btn: NSView
            if LicenseManager.shared.isActivated {
                btn = makeCurrentButton(title: "已激活 · 无需试用")
            } else if CloudASRTranscriber().isConfigured() && TrialManager.shared.isTrialAvailable {
                btn = makeCurrentButton(title: "已填自己的 Key · 无需试用")
            } else if TrialManager.shared.isTotalExhausted {
                btn = makeCurrentButton(title: "试用额度已用完")
            } else if TrialManager.shared.isInTrial {
                btn = makeCurrentButton(title: "试用中 · 剩 \(TrialManager.shared.daysLeft) 天")
            } else if TrialManager.shared.trialExpired {
                btn = makeCurrentButton(title: "试用已结束")
            } else if !TrialManager.shared.isTrialAvailable {
                btn = makeCurrentButton(title: "此版本不含试用")
            } else {
                btn = makeCurrentButton(title: "未开始")
            }

            stack.addArrangedSubview(nameRow)
            stack.setCustomSpacing(14, after: nameRow)
            stack.addArrangedSubview(price)
            stack.setCustomSpacing(6, after: price)
            stack.addArrangedSubview(desc)
            stack.setCustomSpacing(18, after: desc)
            stack.addArrangedSubview(btn)
            stack.setCustomSpacing(20, after: btn)
            for f in [
                makeFeatureRow("7 天共 \(TrialManager.formatChars(TrialManager.shared.displayTotalLimit)) 字"),
                makeFeatureRow("识别 + AI 润色，", muted: "费用我们承担"),
                makeFeatureRow("不用填 Key，按一下就出字"),
                makeFeatureRow("到期后可转下面两种"),
            ] {
                stack.addArrangedSubview(f)
                stack.setCustomSpacing(11, after: f)
            }
        }
    }

    /// 卡②：年付会员（高亮，墨黑实心按钮 → 官网付款页）。免配置：识别 / 润色 / 问 AI 走我们的托管服务。
    /// （2026-09-14 去掉赞助版：Paddle 禁止销售捐款/赞助类商品）
    private func makeBuyPricingCard() -> NSView {
        makePricingCard(highlighted: true) { stack in
            let nameRow = makeCardNameRow("会员", tags: [makeDarkTag("推荐"), makeSoftTag("免配置")])
            let price = makePriceRow(main: "¥188", per: "· 一年")
            let desc = label("不用申请任何 Key，装好就能用", size: 13, weight: .regular, color: theme.text2)
            desc.maximumNumberOfLines = 0

            let license = LicenseManager.shared
            let btn: NSView
            if !TrialManager.shared.isTrialAvailable {
                // 自己编译的开源版没有托管服务器地址，会员通道用不了（试用同理）
                btn = makeCurrentButton(title: "此版本不含会员服务")
            } else if license.isMember && !license.isMemberExpired() {
                btn = makeCurrentButton(title: "会员有效 · 至 \(license.memberExpiresDay ?? "—")")
            } else {
                let solid = makeSolidButton(title: license.isMember ? "续费 →" : "开通会员 →")
                let click = NSClickGestureRecognizer(target: self, action: #selector(pricingBuyTapped))
                solid.addGestureRecognizer(click)
                btn = solid
            }

            stack.addArrangedSubview(nameRow)
            stack.setCustomSpacing(14, after: nameRow)
            stack.addArrangedSubview(price)
            stack.setCustomSpacing(6, after: price)
            stack.addArrangedSubview(desc)
            stack.setCustomSpacing(18, after: desc)
            stack.addArrangedSubview(btn)
            stack.setCustomSpacing(20, after: btn)
            for f in [
                makeFeatureRow("识别 + 润色 + 问 AI 全包含"),   // 文字过长会把对勾挤没；「免配置」已在卡片标签里
                makeFeatureRow("银行卡自动续费，", muted: "或微信买一年"),
                makeFeatureRow("随时可取消自动续费"),
                makeFeatureRow("到期后仍可填自己的 Key 免费用"),
            ] {
                stack.addArrangedSubview(f)
                stack.setCustomSpacing(11, after: f)
            }
        }
    }

    /// 卡③：自带 Key·免费（ghost 按钮 → 模型页并关闭本页）。
    private func makeBYOKPricingCard() -> NSView {
        makePricingCard(highlighted: false) { stack in
            let nameRow = makeCardNameRow("自带 Key", tags: [makeSoftTag("永久免费")])
            let price = makePriceRow(main: "免费", per: "· 不限时间")
            let desc = label("填入你自己的 API Key", size: 13, weight: .regular, color: theme.text2)

            let ghost = makeGhostButton(title: "去配置 →")
            ghost.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pricingConfigureTapped)))

            stack.addArrangedSubview(nameRow)
            stack.setCustomSpacing(14, after: nameRow)
            stack.addArrangedSubview(price)
            stack.setCustomSpacing(6, after: price)
            stack.addArrangedSubview(desc)
            stack.setCustomSpacing(18, after: desc)
            stack.addArrangedSubview(ghost)
            stack.setCustomSpacing(20, after: ghost)
            for f in [
                makeFeatureRow("不限字数"),
                makeFeatureRow("永久免费，不限时间"),
                makeFeatureRow("费用走你自己的 Key"),
                makeFeatureRow("火山 / 千问 等主流厂商适配"),
            ] {
                stack.addArrangedSubview(f)
                stack.setCustomSpacing(11, after: f)
            }
        }
    }

    /// 价格行：大号主价 + 可选「· 7 天」后缀 + 可选划线原价。
    private func makePriceRow(main: String, per: String?, old: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        row.spacing = 8
        let mainLbl = label(main, size: 30, weight: .bold, color: theme.text)
        row.addArrangedSubview(mainLbl)
        if let per = per {
            row.addArrangedSubview(label(per, size: 14, weight: .regular, color: theme.text3))
        }
        if let old = old {
            let oldLbl = NSTextField(labelWithAttributedString: NSAttributedString(string: old, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: theme.text3,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]))
            oldLbl.isSelectable = false
            row.addArrangedSubview(oldLbl)
        }
        return row
    }

    @objc private func pricingBuyTapped() {
        if let url = URL(string: AppLinks.purchaseURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func pricingConfigureTapped() {
        closeUpgradeSheet()
        selectPage(.model)
    }

    /// 激活行：「已经购买过了？」+ 授权码输入框 + 激活按钮 + 错误提示（沿用既有激活逻辑）。
    private func makeActivateBlock() -> NSView {
        let prompt = label("已经购买过了？粘贴授权码激活", size: 13, weight: .regular, color: theme.text2)
        prompt.alignment = .center

        // 授权码输入框：透明 borderless 字段 + 圆角浅灰底容器（同词库/反馈输入框做法），
        // 去掉系统蓝聚焦环；文字左右内缩 12pt，和整页灰/墨黑统一。
        let field = NSTextField()
        field.placeholderString = "粘贴授权码（购买后邮件里的 TF-XXXX-…）"
        field.font = monoFont(size: 12, weight: .regular)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = theme.text
        field.translatesAutoresizingMaskIntoConstraints = false
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byTruncatingTail
        }
        licenseKeyField = field

        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = 9
        fieldWrap.layer?.borderWidth = 1
        fieldWrap.layer?.setAppearanceBorder(theme.sep)
        fieldWrap.layer?.setAppearanceBackground(theme.cardAlt)
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
        ])

        // 激活按钮：墨黑自绘（onAccent 白字），仍是 NSButton 子类——
        // activateLicenseTapped 依赖 sender(NSButton) 改 isEnabled/title，激活逻辑保持不变。
        let activateBtn = SolidLabelButton(title: "激活", color: theme.onAccent,
                                           target: self, action: #selector(activateLicenseTapped(_:)))
        activateBtn.layer?.setAppearanceBackground(theme.accent)
        activateBtn.keyEquivalent = "\r"

        let status = label("", size: 12, weight: .regular, color: theme.danger)
        status.alignment = .center
        status.isHidden = true
        licenseStatusLabel = status

        fieldWrap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        activateBtn.setContentHuggingPriority(.required, for: .horizontal)
        activateBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10
        inputRow.distribution = .fill
        inputRow.addArrangedSubview(fieldWrap)
        inputRow.addArrangedSubview(activateBtn)

        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .centerX
        block.spacing = 12
        block.translatesAutoresizingMaskIntoConstraints = false
        block.addArrangedSubview(prompt)
        block.addArrangedSubview(inputRow)
        block.addArrangedSubview(status)

        // 输入框 + 按钮一行，整行约 500 居中；输入框撑开，按钮固定宽，两者等高 40。
        NSLayoutConstraint.activate([
            inputRow.widthAnchor.constraint(equalToConstant: 500),
            fieldWrap.heightAnchor.constraint(equalToConstant: 40),
            activateBtn.heightAnchor.constraint(equalToConstant: 40),
            activateBtn.widthAnchor.constraint(equalToConstant: 84),
            status.widthAnchor.constraint(equalToConstant: 500),
        ])
        return block
    }

    /// FAQ 区块：标题 + 4 条问答，排成 2 行 × 2 列，整块用满上方三张卡的总宽。
    private func makeFAQBlock() -> NSView {
        let items: [(String, String)] = [
            ("可以一直免费用吗？",
             "可以。前 7 天我们请你免费体验（零配置）；到期后填入你自己的 API Key，永久免费，不限字数。"),
            ("会员和免费有什么区别？",
             "功能一样。免费需要你自己去厂商申请 API Key，费用走你自己的账户；会员不用配置，识别和润色走我们的服务。"),
            ("会员会自动扣费吗？",
             "用银行卡开通的每年自动续费，想停直接回复购买邮件即可取消；用微信买的是一次性一年，不会自动扣费。"),
            ("我的 API Key 安全吗？",
             "你的 Key 只保存在本机，绝不上传我们的服务器。"),
        ]

        // 单条问答：顶边分隔线 + 问题 + 自动换行的答案。
        func makeQA(_ q: String, _ a: String) -> NSView {
            let cell = NSStackView()
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 0
            let line = NSView()
            line.wantsLayer = true
            line.layer?.setAppearanceBackground(theme.sep)
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            let qLbl = label(q, size: 14, weight: .semibold, color: theme.text)
            qLbl.maximumNumberOfLines = 0
            let aLbl = label(a, size: 13, weight: .regular, color: theme.text2)
            aLbl.maximumNumberOfLines = 0
            cell.addArrangedSubview(line)
            cell.setCustomSpacing(14, after: line)
            cell.addArrangedSubview(qLbl)
            cell.setCustomSpacing(8, after: qLbl)
            cell.addArrangedSubview(aLbl)
            line.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            qLbl.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            aLbl.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            return cell
        }

        // 两两一行；列间 36 间距，列等宽（fillEqually）。
        func makeFAQRow(_ left: NSView, _ right: NSView) -> NSStackView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 36
            row.addArrangedSubview(left)
            row.addArrangedSubview(right)
            return row
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = label("常见问题", size: 16, weight: .semibold, color: theme.text)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(10, after: heading)

        let row1 = makeFAQRow(makeQA(items[0].0, items[0].1), makeQA(items[1].0, items[1].1))
        let row2 = makeFAQRow(makeQA(items[2].0, items[2].1), makeQA(items[3].0, items[3].1))
        stack.addArrangedSubview(row1)
        stack.setCustomSpacing(4, after: row1)
        stack.addArrangedSubview(row2)
        row1.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func upgradeSheetCloseTapped() {
        closeUpgradeSheet()
    }

    private func closeUpgradeSheet() {
        if let sheet = upgradeSheet {
            window?.endSheet(sheet)
            upgradeSheet = nil
        }
    }

    @objc private func activateLicenseTapped(_ sender: NSButton) {
        let key = licenseKeyField?.stringValue ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showLicenseStatus("请先粘贴授权码", isError: true)
            return
        }
        sender.isEnabled = false
        sender.title = "激活中…"
        showLicenseStatus("正在激活…", isError: false)

        let deviceName = Host.current().localizedName ?? "Mac"
        LicenseManager.shared.activate(key: key, instanceName: deviceName) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.closeUpgradeSheet()
                self.rebuildSidebar()                // 升级按钮消失
                self.invalidate(self.selectedPage)   // 刷新当前页（关于页会显示「已激活」小字）
            case .failure(let err):
                sender.isEnabled = true
                sender.title = "激活"
                self.showLicenseStatus(Self.licenseErrorText(err), isError: true)
            }
        }
    }

    private func showLicenseStatus(_ text: String, isError: Bool) {
        guard let label = licenseStatusLabel else { return }
        label.stringValue = text
        label.textColor = isError ? theme.danger : theme.text3
        label.isHidden = false
    }

    private static func licenseErrorText(_ err: LicenseManager.ActivationError) -> String {
        switch err {
        case .emptyKey:      return "请先粘贴授权码"
        case .invalidKey:    return "授权码无效，请检查是否复制完整"
        case .limitReached:  return "这个授权码已在另一台 Mac 上激活。换新机请到 typefree.app/recover 重置后再试。"
        case .network(let m): return "激活失败：\(m)"
        }
    }
}
