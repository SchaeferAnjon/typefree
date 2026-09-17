import Cocoa
import UniformTypeIdentifiers
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 设置窗「反馈」页：工单式。三个画面——
/// ① 列表：全部 / 处理中 / 已结束，右上角「提交工单」；
/// ② 提交工单：类型 + 描述 + 截图 / 最后的转录；
/// ③ 工单详情：和开发者的对话；处理中可以继续发，已结束只读、底部引导「提交新工单」。
/// 发送时照旧自动带上系统版本、App 版本、最近使用的软件和最近的日志（界面上不再单独说明）。
final class SupportChatView: NSView, NSTextViewDelegate {
    /// 复用 App 的调试日志（粘贴 / 拖入 / 发送的诊断）
    static var log: ((String) -> Void)?

    struct Context {
        var latestTranscript: () -> (asr: String, output: String, audio: Data?)?
        var recentApp: () -> String?
        var logTail: () -> String
        var openSetupHint: (() -> Void)?
    }

    private enum Mode: Equatable { case list, new, detail(Int) }

    /// 右侧留给滚动条的空隙：滚动区铺满到最右，里面的内容和其它元素都往里收这么多，
    /// 浮着的滚动条就落在空隙里，不压气泡/卡片（设置窗那边把本视图右边多给了这么宽）
    static let scrollerGutter: CGFloat = 18
    private var gutter: CGFloat { Self.scrollerGutter }

    private let theme: VPTheme
    private let context: Context
    private let service = SupportChatService.shared
    private var observer: NSObjectProtocol?
    private var mode: Mode = .list
    private var filterIndex = 0                  // 0 全部 · 1 处理中 · 2 已结束

    // 当前画面
    private var screen: NSView?
    private var listStack: NSStackView?
    private var listEmpty: NSTextField?
    private var filterHolder: NSView?
    private var newCategory: SupportTicket.Category = .issue
    private var detailTicketId: Int?
    private var detailStatus: SupportTicket.Status?
    private var detailTitle: NSTextField?
    private var detailPillHolder: NSView?
    private var detailMeta: NSTextField?
    private var messagesScroll: NSScrollView?
    private var messagesDoc: SupportFlippedView?
    private var messagesStack: NSStackView?
    private var bottomHolder: NSView?

    // 输入区（提交表单和详情里的输入区同一时刻只有一个）
    private weak var textView: SupportTextView?
    private weak var placeholder: NSTextField?
    private weak var attachmentRow: NSStackView?
    private weak var attachTranscriptButton: VPButton?
    private weak var statusLabel: NSTextField?
    private weak var submitButton: VPButton?
    private var pendingImage: Data?             // 已转成 JPEG 的截图
    private var transcriptAttached = false      // 默认不带；用户点「附上最后的转录」才带

    init(theme: VPTheme, context: Context) {
        self.theme = theme
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL, .png, .tiff])
        show(.list)
        observer = NotificationCenter.default.addObserver(forName: SupportChatService.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        service.sync()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// 页面显示时：拉一次新回复；正看着某个工单就记已读；按钮按有没有转录可附刷新
    func pageDidAppear() {
        if case .detail(let id) = mode { service.markTicketSeen(id) }
        service.sync { [weak self] _ in
            guard let self, case .detail(let id) = self.mode else { return }
            self.service.markTicketSeen(id)
        }
        refreshAttachments()
    }

    // MARK: - 画面切换

    private func show(_ newMode: Mode) {
        mode = newMode
        screen?.removeFromSuperview()
        listStack = nil; listEmpty = nil; filterHolder = nil
        detailTicketId = nil; detailStatus = nil; detailTitle = nil; detailPillHolder = nil; detailMeta = nil
        messagesScroll = nil; messagesDoc = nil; messagesStack = nil; bottomHolder = nil
        clearInputRefs()

        let view: NSView
        switch newMode {
        case .list: view = buildList()
        case .new: view = buildNewForm()
        case .detail(let id): view = buildDetail(ticketId: id)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        screen = view
        switch newMode {
        case .list: reloadList()
        case .new: window?.makeFirstResponder(textView)
        case .detail(let id):
            reloadDetail()
            if window != nil { service.markTicketSeen(id) }
        }
    }

    /// 服务器 / 本机数据变了：只刷新内容，不动正在写的草稿
    func reload() {
        switch mode {
        case .list: reloadList()
        case .new: break
        case .detail: reloadDetail()
        }
    }

    // MARK: - ① 列表

    private func buildList() -> NSView {
        let root = NSView()

        let header = makeHeader(eyebrow: "TYPEFREE / 反馈", title: "反馈",
                                sub: "遇到问题或有建议，提交一个工单。开发者的回复会出现在对应工单里。")
        let newButton = VPButton(title: "提交工单", style: .primary, size: .regular, theme: theme,
                                 target: self, action: #selector(openNewForm))
        let filters = NSView()
        filters.translatesAutoresizingMaskIntoConstraints = false
        filterHolder = filters

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let doc = SupportFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        listStack = stack

        let empty = NSTextField(wrappingLabelWithString: "")
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = theme.text3
        empty.alignment = .center
        listEmpty = empty

        for v in [header, newButton, filters, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: newButton.leadingAnchor, constant: -16),
            newButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            newButton.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -2),

            filters.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filters.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            filters.heightAnchor.constraint(equalToConstant: 30),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -gutter),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),

            empty.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 80),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        return root
    }

    private func reloadList() {
        guard let stack = listStack, let filters = filterHolder else { return }
        let all = service.sortedTickets
        let openCount = all.filter { $0.status == .open }.count
        let closedCount = all.count - openCount

        // 分段控件的数字会变：整个换掉
        filters.subviews.forEach { $0.removeFromSuperview() }
        let seg = VPSegmentedControl(labels: ["全部 \(all.count)", "处理中 \(openCount)", "已结束 \(closedCount)"],
                                     trackBg: theme.cardAlt, trackBorder: theme.sep, selBg: theme.segSelBg,
                                     selBorder: theme.sep, selText: theme.text, normalText: theme.text2,
                                     target: self, action: #selector(filterChanged(_:)))
        seg.selectedSegment = filterIndex
        filters.addSubview(seg)
        NSLayoutConstraint.activate([
            seg.leadingAnchor.constraint(equalTo: filters.leadingAnchor),
            seg.trailingAnchor.constraint(equalTo: filters.trailingAnchor),
            seg.topAnchor.constraint(equalTo: filters.topAnchor),
            seg.bottomAnchor.constraint(equalTo: filters.bottomAnchor),
            seg.widthAnchor.constraint(equalToConstant: 300),
        ])

        let shown: [SupportTicket]
        switch filterIndex {
        case 1: shown = all.filter { $0.status == .open }
        case 2: shown = all.filter { $0.status == .closed }
        default: shown = all
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for t in shown {
            let card = makeTicketCard(t)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        listEmpty?.isHidden = !shown.isEmpty
        switch filterIndex {
        case 1: listEmpty?.stringValue = "没有处理中的工单。"
        case 2: listEmpty?.stringValue = "还没有已结束的工单。"
        default:
            listEmpty?.stringValue = service.hasThread && all.isEmpty
                ? "正在读取工单…"
                : "还没有工单。遇到问题或有建议，点右上角「提交工单」。"
        }
    }

    @objc private func filterChanged(_ sender: VPSegmentedControl) {
        filterIndex = sender.selectedSegment
        reloadList()
    }

    @objc private func openNewForm() { show(.new) }
    @objc private func backToList() { show(.list) }

    private func makeTicketCard(_ t: SupportTicket) -> NSView {
        let card = SupportClickableCard(theme: theme) { [weak self] in self?.show(.detail(t.id)) }

        let title = NSTextField(labelWithString: t.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = theme.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [makeStatusPill(t.status), title])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10

        let count = service.messages(inTicket: t.id).count
        let metaParts = ["#\(t.no)", t.category.label, Self.friendlyTime(t.createdAt)] + (count > 0 ? ["\(count) 条消息"] : [])
        let meta = label(metaParts.joined(separator: " · "), size: 12, color: theme.text3)

        let left = NSStackView(views: [topRow, meta])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 5
        left.setHuggingPriority(.defaultLow, for: .horizontal)

        let right = NSStackView()
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 10
        let unread = service.unreadCount(ticket: t.id)
        if unread > 0 {
            let badge = label("\(unread) 条新回复", size: 12, weight: .semibold, color: theme.danger)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            right.addArrangedSubview(badge)
        }
        if let img = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = theme.text3
            iv.setContentHuggingPriority(.required, for: .horizontal)
            right.addArrangedSubview(iv)
        }
        right.setHuggingPriority(.required, for: .horizontal)   // 右栏只占内容宽度，把多余宽度都留给标题
        right.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [left, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            left.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            left.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            {   // 左栏尽量撑满，标题放得下就别截
                let c = left.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -16)
                c.priority = .defaultHigh
                return c
            }(),
            right.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            right.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        card.setAccessibilityLabel("工单 #\(t.no) \(t.title)，\(t.status == .open ? "处理中" : "已结束")")
        return card
    }

    // MARK: - ② 提交工单

    private func buildNewForm() -> NSView {
        let root = NSView()
        let back = makeBackButton()
        let header = makeHeader(eyebrow: nil, title: "提交工单",
                                sub: "说清楚在哪个软件里、怎么操作时出的问题，处理起来最快。")

        let form = NSView()
        form.wantsLayer = true
        form.layer?.cornerRadius = 12
        form.layer?.borderWidth = 1
        form.layer?.setAppearanceBorder(theme.sep)
        form.layer?.setAppearanceBackground(theme.card)

        newCategory = .issue
        let seg = VPSegmentedControl(labels: SupportTicket.Category.allCases.map(\.label),
                                     trackBg: theme.cardAlt, trackBorder: theme.sep, selBg: theme.segSelBg,
                                     selBorder: theme.sep, selText: theme.text, normalText: theme.text2,
                                     target: self, action: #selector(categoryChanged(_:)))
        seg.selectedSegment = 0
        seg.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let (inputWrap, _) = makeInput(placeholder: "比如：在微信里按住鼠标说话，胶囊出来了但松手后没有出字…")
        let attachButtons = makeAttachButtons()
        let attachments = makeAttachmentRow()

        let sep = NSBox()
        sep.boxType = .separator

        let status = makeStatusLabel()
        let submit = VPButton(title: "提交", style: .primary, size: .regular, theme: theme,
                              target: self, action: #selector(submitTicket))
        submitButton = submit
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [status, spacer, submit])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let fields = NSStackView(views: [
            fieldLabel("类型"), seg,
            fieldLabel("描述"), inputWrap,
            fieldLabel("附件（可选）"), attachButtons, attachments,
            sep, footer,
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        fields.setCustomSpacing(18, after: seg)
        fields.setCustomSpacing(18, after: inputWrap)
        fields.setCustomSpacing(16, after: attachments)
        fields.setCustomSpacing(14, after: sep)
        fields.translatesAutoresizingMaskIntoConstraints = false
        form.addSubview(fields)

        for v in [back, header, form] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: -4),
            back.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -gutter),
            header.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 6),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            form.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            form.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            fields.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            fields.topAnchor.constraint(equalTo: form.topAnchor),
            fields.bottomAnchor.constraint(equalTo: form.bottomAnchor),
            inputWrap.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -40),
            inputWrap.heightAnchor.constraint(equalToConstant: 150),
            attachments.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -40),
            sep.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -40),
        ])
        refreshAttachments()
        return root
    }

    @objc private func categoryChanged(_ sender: VPSegmentedControl) {
        let all = SupportTicket.Category.allCases
        newCategory = all[max(0, min(all.count - 1, sender.selectedSegment))]
    }

    @objc private func submitTicket() {
        guard let textView else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showStatus("先描述一下遇到的问题", isError: true)
            return
        }
        let (asr, polished, audio) = transcriptParts()
        let hasAttachment = pendingImage != nil || audio != nil
        // 服务器规矩：新设备第一条只收文字（防伪造设备灌附件）→ 先建工单，附件紧跟着补一条
        let splitAttachments = !service.hasThread && hasAttachment
        let first = outgoing(text, image: splitAttachments ? nil : pendingImage, audio: splitAttachments ? nil : audio,
                             asr: splitAttachments ? nil : asr, polished: splitAttachments ? nil : polished)
        let followUp = outgoing("", image: pendingImage, audio: audio, asr: asr, polished: polished)
        let category = newCategory
        setSending(true, title: "提交中…")
        service.createTicket(category: category, first) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.setSending(false, title: "提交")
                self.showStatus(err.userMessage, isError: true)
            case .success(let created):
                guard splitAttachments || created.attachmentsDropped else {
                    self.show(.detail(created.ticket.id))
                    return
                }
                self.service.send(followUp, ticketId: created.ticket.id) { [weak self] r2 in
                    guard let self else { return }
                    self.show(.detail(created.ticket.id))
                    if case .failure(let err) = r2 {
                        self.showStatus("工单已提交，附件没发成功：\(err.userMessage)，可以在这里重新附上", isError: true)
                    }
                }
            }
        }
    }

    // MARK: - ③ 工单详情

    private func buildDetail(ticketId: Int) -> NSView {
        detailTicketId = ticketId
        let root = NSView()
        let back = makeBackButton()

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = theme.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailTitle = title
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        detailPillHolder = pill
        let titleRow = NSStackView(views: [title, pill])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        let meta = label("", size: 12, color: theme.text3)
        detailMeta = meta

        let sep = NSBox()
        sep.boxType = .separator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let doc = SupportFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        messagesScroll = scroll; messagesDoc = doc; messagesStack = stack

        let bottom = NSView()
        bottomHolder = bottom

        for v in [back, titleRow, meta, sep, scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: -4),
            back.topAnchor.constraint(equalTo: root.topAnchor),
            titleRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -gutter),
            titleRow.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 6),
            meta.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            meta.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 5),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            sep.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 14),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -16),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -gutter),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func reloadDetail() {
        guard let id = detailTicketId, let stack = messagesStack else { return }
        guard let t = service.ticket(id: id) else {
            // 工单还没同步下来（刚提交、或缓存被清）：先显示空，等同步
            detailTitle?.stringValue = "工单"
            return
        }
        detailTitle?.stringValue = t.title
        if let holder = detailPillHolder {
            holder.subviews.forEach { $0.removeFromSuperview() }
            let pill = makeStatusPill(t.status)
            pill.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                pill.topAnchor.constraint(equalTo: holder.topAnchor),
                pill.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
        }
        var meta = ["#\(t.no)", t.category.label, "\(Self.friendlyTime(t.createdAt)) 提交"]
        if t.status == .closed, let closed = t.closedAt, !closed.isEmpty { meta.append("\(Self.friendlyTime(closed)) 结束") }
        detailMeta?.stringValue = meta.joined(separator: " · ")

        let list = service.messages(inTicket: id)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for m in list {
            let row = makeBubbleRow(m)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if t.status == .closed {
            let when = t.closedAt.map { " · " + Self.localTime($0) } ?? ""
            let note = makeSystemNote("开发者已结束这个工单\(when)")
            stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if detailStatus != t.status {
            detailStatus = t.status
            rebuildBottom(for: t)
        }
        layoutSubtreeIfNeeded()
        scrollToBottom()
        if window != nil, isShownOnScreen { service.markTicketSeen(id) }
    }

    private var isShownOnScreen: Bool { window?.isVisible == true && !isHiddenOrHasHiddenAncestor }

    private func rebuildBottom(for t: SupportTicket) {
        guard let holder = bottomHolder else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        clearInputRefs()
        let content = t.status == .open ? makeComposer() : makeClosedBar()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        refreshAttachments()
    }

    private func makeComposer() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.setAppearanceBorder(theme.sep)
        card.layer?.setAppearanceBackground(theme.card)

        let attachments = makeAttachmentRow()
        let (inputWrap, _) = makeInput(placeholder: "补充说明，或回复开发者…")
        let buttons = makeAttachButtons()
        let status = makeStatusLabel()
        let send = VPButton(title: "发送", style: .primary, size: .regular, theme: theme,
                            target: self, action: #selector(sendReply))
        send.setContentHuggingPriority(.required, for: .horizontal)
        submitButton = send
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)   // 把「发送」顶到最右
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(status)
        buttons.addArrangedSubview(send)

        let form = NSStackView(views: [attachments, inputWrap, buttons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        form.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            form.topAnchor.constraint(equalTo: card.topAnchor),
            form.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            attachments.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
            inputWrap.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
            inputWrap.heightAnchor.constraint(equalToConstant: 64),
            buttons.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -32),
        ])
        return card
    }

    private func makeClosedBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.layer?.setAppearanceBackground(theme.cardAlt)
        let text = label("这个工单已结束，不能再回复。还有问题可以提交新工单。", size: 13, color: theme.text2)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = VPButton(title: "提交新工单", style: .secondary, size: .regular, theme: theme,
                              target: self, action: #selector(openNewForm))
        button.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [text, spacer, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    @objc private func sendReply() {
        guard let textView, let ticketId = detailTicketId else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || pendingImage != nil || transcriptAttached else {
            showStatus("写点内容或附上截图再发", isError: true)
            return
        }
        let (asr, polished, audio) = transcriptParts()
        setSending(true, title: "发送中…")
        service.send(outgoing(text, image: pendingImage, audio: audio, asr: asr, polished: polished), ticketId: ticketId) { [weak self] result in
            guard let self else { return }
            self.setSending(false, title: "发送")
            switch result {
            case .success:
                self.textView?.string = ""
                self.pendingImage = nil
                self.transcriptAttached = false      // 转录只随这一条发；下次要带得再点一次
                self.textDidChange(Notification(name: NSText.didChangeNotification))
                self.refreshAttachments()
                self.showStatus("已发送", isError: false)
            case .failure(let err):
                self.showStatus(err.userMessage, isError: true)
            }
        }
    }

    // MARK: - 消息气泡

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let scroll = messagesScroll, let doc = messagesDoc else { return }
            let h = doc.fittingSize.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, h - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func makeBubbleRow(_ m: SupportMessage) -> NSView {
        let mine = m.role == .user
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 14
        bubble.translatesAutoresizingMaskIntoConstraints = false
        if mine {
            bubble.layer?.setAppearanceBackground(theme.accent)
        } else {
            bubble.layer?.setAppearanceBackground(theme.card)
            bubble.layer?.borderWidth = 1
            bubble.layer?.setAppearanceBorder(theme.sep)
        }

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 9, left: 13, bottom: 9, right: 13)

        if !m.text.isEmpty {
            let t = NSTextField(wrappingLabelWithString: m.text)
            t.font = .systemFont(ofSize: 13.5)
            t.textColor = mine ? theme.onAccent : theme.text
            t.isSelectable = true
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            content.addArrangedSubview(t)
            t.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -26).isActive = true
        }
        if m.hasImage {
            if let url = service.imageURL(for: m), let image = NSImage(contentsOf: url) {
                let iv = SupportClickableImage(image: image, url: url)
                content.addArrangedSubview(iv)
                let ratio = max(image.size.width, 1) / max(image.size.height, 1)
                let w = min(320, max(120, image.size.width))
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(lessThanOrEqualToConstant: w),
                    iv.widthAnchor.constraint(equalTo: iv.heightAnchor, multiplier: ratio),
                    iv.heightAnchor.constraint(lessThanOrEqualToConstant: 240),
                ])
            } else {
                let t = NSTextField(labelWithString: "🖼 截图")
                t.font = .systemFont(ofSize: 12)
                t.textColor = mine ? theme.onAccent.withAlphaComponent(0.8) : theme.text3
                content.addArrangedSubview(t)
            }
        }
        if m.hasAudio {
            let t = NSTextField(labelWithString: "🎙 附带了最后一次录音")
            t.font = .systemFont(ofSize: 12)
            t.textColor = mine ? theme.onAccent.withAlphaComponent(0.8) : theme.text3
            content.addArrangedSubview(t)
        }
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            content.topAnchor.constraint(equalTo: bubble.topAnchor),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
        ])

        let time = NSTextField(labelWithString: Self.localTime(m.createdAt) + (mine ? "" : " · 开发者"))
        time.font = .systemFont(ofSize: 11)
        time.textColor = theme.text3

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = mine ? .trailing : .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(bubble)
        column.addArrangedSubview(time)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: row.topAnchor),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.72),
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            mine ? column.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4)
                 : column.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
        ])
        return row
    }

    private func makeSystemNote(_ text: String) -> NSView {
        let row = NSView()
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.setAppearanceBackground(theme.cardAlt)
        let l = label(text, size: 11.5, color: theme.text3)
        for v in [pill, l] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        pill.addSubview(l)
        row.addSubview(pill)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            l.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            l.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            pill.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            pill.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            pill.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    // MARK: - 输入区零件

    private func makeInput(placeholder text: String) -> (NSView, SupportTextView) {
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 8
        wrap.layer?.masksToBounds = true
        wrap.layer?.borderWidth = 1
        wrap.layer?.setAppearanceBorder(theme.sep)
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let tv = SupportTextView()
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = theme.text
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.autoresizingMask = [.width]
        tv.delegate = self
        tv.onPasteImage = { [weak self] image in self?.attach(image: image) }
        scroll.documentView = tv
        wrap.addSubview(scroll)
        let ph = NSTextField(labelWithString: text)
        ph.font = .systemFont(ofSize: 13)
        ph.textColor = theme.text3
        ph.lineBreakMode = .byTruncatingTail
        ph.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(ph)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
            ph.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            ph.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -12),
            ph.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 9),
        ])
        textView = tv
        placeholder = ph
        return (wrap, tv)
    }

    /// 「添加截图」「附上最后的转录」+ 提示；详情页会在后面再塞状态和发送按钮
    private func makeAttachButtons() -> NSStackView {
        let addImage = VPButton(title: "添加截图", style: .secondary, size: .small, theme: theme,
                                target: self, action: #selector(chooseImage))
        let transcript = VPButton(title: "附上最后的转录", style: .secondary, size: .small, theme: theme,
                                  target: self, action: #selector(attachTranscript))
        transcript.toolTip = "把最近一次识别的文字和录音一起发给开发者，方便查识别问题"
        attachTranscriptButton = transcript
        let hint = NSTextField(labelWithString: "也可以把截图拖进来或直接粘贴。")
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = theme.text3
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [addImage, transcript, hint])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func makeAttachmentRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        attachmentRow = row
        return row
    }

    private func makeStatusLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 12)
        l.textColor = theme.text3
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.isHidden = true
        statusLabel = l
        return l
    }

    private func refreshAttachments() {
        guard let row = attachmentRow else { return }
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let data = pendingImage, let image = NSImage(data: data) {
            let chip = makeChip(icon: nil, title: "截图 · \(Int(image.size.width))×\(Int(image.size.height))",
                                remove: #selector(removeImage))
            let thumb = NSImageView(image: image)
            thumb.imageScaling = .scaleProportionallyUpOrDown
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 4
            thumb.layer?.masksToBounds = true
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.widthAnchor.constraint(equalToConstant: 28).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 20).isActive = true
            chip.insertArrangedSubview(thumb, at: 0)
            row.addArrangedSubview(chip)
        }
        if transcriptAttached, let t = context.latestTranscript() {
            let preview = (t.output.isEmpty ? t.asr : t.output).split(whereSeparator: \.isNewline).joined(separator: " ")
            let brief = preview.count > 24 ? String(preview.prefix(24)) + "…" : preview
            row.addArrangedSubview(makeChip(icon: "waveform", title: "最后的转录：\(brief)", remove: #selector(removeTranscript)))
        }
        row.isHidden = row.arrangedSubviews.isEmpty
        // 已经附上了、或者根本没有转录可附，就不显示这个按钮
        attachTranscriptButton?.isHidden = transcriptAttached || context.latestTranscript() == nil
    }

    @objc private func attachTranscript() {
        guard context.latestTranscript() != nil else { return }
        transcriptAttached = true
        refreshAttachments()
    }

    private func makeChip(icon: String?, title: String, remove: Selector) -> NSStackView {
        let chip = NSStackView()
        chip.orientation = .horizontal
        chip.alignment = .centerY
        chip.spacing = 6
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 7
        chip.layer?.setAppearanceBackground(theme.cardAlt)
        chip.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 6)
        if let icon, let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = theme.text2
            chip.addArrangedSubview(iv)
        }
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12)
        t.textColor = theme.text2
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        t.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        chip.addArrangedSubview(t)
        let x = NSButton()
        x.bezelStyle = .regularSquare
        x.isBordered = false
        x.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除")
        x.contentTintColor = theme.text3
        x.target = self
        x.action = remove
        chip.addArrangedSubview(x)
        return chip
    }

    @objc private func removeImage() { pendingImage = nil; refreshAttachments() }
    @objc private func removeTranscript() { transcriptAttached = false; refreshAttachments() }

    /// 换画面 / 输入区被换掉：草稿和附件跟着清掉
    private func clearInputRefs() {
        textView = nil; placeholder = nil; attachmentRow = nil
        attachTranscriptButton = nil; statusLabel = nil; submitButton = nil
        pendingImage = nil
        transcriptAttached = false
    }

    /// 当前画面能不能收附件（列表页、已结束的工单不能）
    private var acceptsAttachments: Bool { textView != nil && attachmentRow != nil }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "选一张截图（PNG / JPG）"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        attach(image: image)
    }

    private func attach(image: NSImage) {
        guard acceptsAttachments else { return }
        SupportChatView.log?("support attach image \(Int(image.size.width))x\(Int(image.size.height))")
        guard let jpeg = SupportImageEncoder.jpegData(from: image) else {
            showStatus("这张图读不出来", isError: true)
            return
        }
        pendingImage = jpeg
        refreshAttachments()
        showStatus("", isError: false)
    }

    // 拖放
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { acceptsAttachments && hasImage(sender) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsAttachments else { return false }
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            attach(image: image); return true
        }
        if let image = NSImage(pasteboard: pb) { attach(image: image); return true }
        return false
    }
    private func hasImage(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) { return true }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    // MARK: - 发送小工具

    private func transcriptParts() -> (String?, String?, Data?) {
        guard transcriptAttached, let t = context.latestTranscript() else { return (nil, nil, nil) }
        return (t.asr, t.output, t.audio)
    }

    private func outgoing(_ text: String, image: Data?, audio: Data?, asr: String?, polished: String?) -> SupportChatService.Outgoing {
        SupportChatService.Outgoing(
            text: text, imageJPEG: image, audioM4A: audio,
            asrText: asr, polishedText: polished,
            recentApp: context.recentApp(), log: context.logTail(),
            deviceName: Host.current().localizedName ?? "",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
    }

    private func setSending(_ sending: Bool, title: String) {
        submitButton?.isEnabled = !sending
        submitButton?.title = title
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = isError ? theme.danger : theme.ok
        statusLabel?.isHidden = text.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        placeholder?.isHidden = !(textView?.string.isEmpty ?? true)
    }

    // MARK: - 通用零件

    private func makeHeader(eyebrow: String?, title: String, sub: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        if let eyebrow {
            let e = label(eyebrow, size: 11, weight: .medium, color: theme.text3)
            stack.addArrangedSubview(e)
            stack.setCustomSpacing(2, after: e)
        }
        let t = label(title, size: 28, weight: .semibold, color: theme.text)
        stack.addArrangedSubview(t)
        stack.setCustomSpacing(6, after: t)
        let s = label(sub, size: 13, color: theme.text2)
        s.maximumNumberOfLines = 0
        stack.addArrangedSubview(s)
        return stack
    }

    private func makeBackButton() -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(backToList))
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.attributedTitle = NSAttributedString(string: "‹ 全部工单", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.text3,
        ])
        return b
    }

    private func makeStatusPill(_ status: SupportTicket.Status) -> NSView {
        let color = status == .open ? theme.ok : theme.text3
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.layer?.setAppearanceBackground(status == .open ? theme.ok.withAlphaComponent(0.12) : theme.cardAlt)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.setAppearanceBackground(color)
        let text = label(status == .open ? "处理中" : "已结束", size: 11.5, weight: .semibold, color: color)
        for v in [dot, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
        ])
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        return pill
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        label(text, size: 12.5, weight: .semibold, color: theme.text2)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    /// 消息时间：今天只显示时刻，否则带日期
    private static func localTime(_ s: String) -> String {
        guard let date = parseDate(s) else { return s }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return out.string(from: date)
    }

    /// 列表/抬头里的时间：今天 17:47 / 9月16日 / 2025年9月16日
    private static func friendlyTime(_ s: String) -> String {
        guard let date = parseDate(s) else { return s }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) {
            out.dateFormat = "HH:mm"
            return "今天 " + out.string(from: date)
        }
        out.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return out.string(from: date)
    }
}

// MARK: - 小件

/// 整张可点的卡片（工单列表）：悬停变浅灰
final class SupportClickableCard: NSView {
    private let onClick: () -> Void
    private let normal: NSColor
    private let hover: NSColor

    init(theme: VPTheme, onClick: @escaping () -> Void) {
        self.onClick = onClick
        normal = theme.card
        hover = theme.cardAlt
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.setAppearanceBorder(theme.sep)
        layer?.setAppearanceBackground(normal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { layer?.setAppearanceBackground(hover) }
    override func mouseExited(with event: NSEvent) { layer?.setAppearanceBackground(normal) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// 粘贴图片直接当截图附件（文字照常粘贴）
final class SupportTextView: NSTextView {
    var onPasteImage: ((NSImage) -> Void)?

    /// 剪贴板里是图（没有文字）→ 交给附件；否则照常粘贴文字。
    /// 纯文本 NSTextView 的 ⌘V 走的是 pasteAsPlainText:，不是 paste:，两个都拦。
    private func takeImageFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        let hasText = pb.string(forType: .string)?.isEmpty == false
        let image = hasText ? nil : NSImage(pasteboard: pb)
        SupportChatView.log?("support paste: types=\(pb.types?.map(\.rawValue).prefix(3) ?? []) hasText=\(hasText) image=\(image != nil)")
        guard let image else { return false }
        onPasteImage?(image)
        return true
    }
    override func paste(_ sender: Any?) {
        if takeImageFromPasteboard() { return }
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if takeImageFromPasteboard() { return }
        super.pasteAsPlainText(sender)
    }
    /// 兜底：菜单没把 ⌘V 送过来时（比如「粘贴」被判为不可用），自己认一下
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            SupportChatView.log?("support paste: keyDown ⌘V")
            if takeImageFromPasteboard() { return }
        }
        super.keyDown(with: event)
    }
    /// 空文本框也要把图当成可粘贴的东西（否则菜单里的「粘贴」是灰的、⌘V 直接被忽略）
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            let pb = NSPasteboard.general
            if NSImage.canInit(with: pb) { return true }
        }
        return super.validateUserInterfaceItem(item)
    }
}

final class SupportClickableImage: NSImageView {
    private let url: URL
    init(image: NSImage, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "点击查看大图"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { NSWorkspace.shared.open(url) }
}

private final class SupportFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 截图转码：任何来源的图都重画成 ≤1600px 的 JPEG，只保留像素——原文件里的元数据、附加内容一律不带走，
/// 服务器也只认这种格式。超过 1.5MB 逐档降质量。
enum SupportImageEncoder {
    static let maxDimension: CGFloat = 1600
    static let maxBytes = SupportChatService.maxImageBytes

    static func jpegData(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        for q in [0.8, 0.65, 0.5, 0.35] {
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: q]), data.count <= maxBytes {
                return data
            }
        }
        return nil
    }
}
