import Cocoa
import ApplicationServices

/// 「指针此刻是否位于一个可编辑的文本输入框上」的判定结果。
/// - editable：明确是输入框，可以自动开始录音
/// - notEditable：明确不是（按钮、列表、正文只读区……）
/// - unknown：拿不到证据（App 不暴露内容、命中失败、只命中大容器……）；一律不触发
enum TextInputVerdict {
    case editable(String)
    /// 指针差几个点没按在输入框上（吸附）：点击落在框外，App 未必把焦点给它，开始录音时要主动放进去
    case editableNearby(String, AXUIElement)
    /// 不是输入框，但也不是能点的东西（正文、空白、桌面）：可以进「长按问 AI」
    case askable(String)
    case notEditable(String)
    case unknown(String)

    var isEditable: Bool {
        switch self {
        case .editable, .editableNearby: return true
        default: return false
        }
    }

    var debugName: String {
        switch self {
        case .editable(let why), .editableNearby(let why, _): return "editable(\(why))"
        case .askable(let why): return "askable(\(why))"
        case .notEditable(let why): return "notEditable(\(why))"
        case .unknown(let why): return "unknown(\(why))"
        }
    }
}

/// 纯判定逻辑，不依赖 App 其他部分，便于用命令行工具对着真实 App 验证。
/// 坐标统一用辅助功能 / CGEvent 的屏幕坐标（主屏左上角为原点，向下为正）。
enum TextInputLocator {
    /// 严格意义上的输入框角色。其余角色（AXGroup 等）即使 AXValue 可写也不算——
    /// Chromium 类 App 里几乎所有 AXGroup 都声称 AXValue 可写，按那个判会全军误判。
    static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// 单次跨进程调用的超时；对方 App 无响应时不能拖住我们。
    static let messagingTimeout: Float = 0.4
    static let maxAncestorLevels = 25
    /// 向下找「更内层输入框」时的预算：只沿 frame 包含指针的分支下探，通常几十次调用就完。
    static let maxDescendantVisits = 500
    static let maxDescendantDepth = 10
    /// 「有没有内层输入框」的存在性扫描预算（不看位置）
    static let maxExistenceScanVisits = 160
    static let maxExistenceScanDepth = 8
    /// 找不到输入框祖先时，向上最多回退几层再向下找邻近输入框
    static let maxNeighborClimb = 4
    /// 输入框「吸附」距离：指针不在输入框上、但离它只差这么几个点（且不在按钮等可点的东西上），也算按在输入框上。
    /// Claude 的输入框圆角框比里面能打字的那一行高一圈，按在下沿几个点会被判成「不是输入框」进了问 AI（2026-09-11 实测 2～9pt）。
    static let inputSnapDistance: CGFloat = 12

    // MARK: - 入口

    static func classify(point: CGPoint, pid: pid_t, bundleID: String?, debug: (String) -> Void = { _ in }) -> TextInputVerdict {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        if let bundleID, WeChatInputRegion.bundleIDs.contains(bundleID) {
            let verdict = WeChatInputRegion.verdict(point: point, app: app, debug: debug)
            debug("wechat rule → \(verdict.debugName)")
            return verdict
        }

        guard let hit = elementAtPosition(app, point) else {
            debug("hit-test failed at \(fmt(point)) pid=\(pid)")
            AccessibilityTreeRequester.requestIfNeeded(app: app, pid: pid, debug: debug)
            return .unknown("命中失败")
        }
        let hitRole = role(of: hit)
        debug("hit=\(hitRole) \(describeFrame(hit))")

        // 1) 沿祖先链找最近的输入框
        if let (level, container) = nearestTextInputAncestor(of: hit) {
            // 2) 它可能是一个包着很多编辑块的大容器（Notion 整页就是一个 AXTextArea），
            //    只信最内层、frame 真正包含指针的那个输入框。
            let (descendantsExist, inner, _) = innermostTextInput(within: container, containing: point)
            if let inner {
                return editableIfEnabled(inner, why: "祖先第\(level)层 \(role(of: container)) → 内层 \(role(of: inner))")
            }
            if descendantsExist {
                return .unknown("命中的是大容器 \(role(of: container))，指针不在任何内层编辑块上")
            }
            return editableIfEnabled(container, why: level == 0 ? "命中即输入框 \(role(of: container))" : "祖先第\(level)层 \(role(of: container))")
        }

        // 3) 没有输入框祖先：可能是层叠的遮罩/兄弟节点挡在输入框上面（飞书、ChatGPT 见过），
        //    向上回退几层，再沿 frame 包含指针的分支向下找。顺带记下离指针很近的输入框（吸附用）。
        var cursor = hit
        var nearInput: AXUIElement?
        for climb in 0...maxNeighborClimb {
            let (_, found, near) = innermostTextInput(within: cursor, containing: point, snap: inputSnapDistance)
            if let found {
                return editableIfEnabled(found, why: "上\(climb)层邻近子树 \(role(of: found))")
            }
            if nearInput == nil { nearInput = near }
            guard let parent = attribute(cursor, kAXParentAttribute) else { break }
            cursor = parent as! AXUIElement
        }

        // 只命中到窗口 / App 这种壳层 = 这个 App 基本没暴露内容，试着请求它建树（Electron 类会响应）。
        if hitRole == "AXWindow" || hitRole == "AXApplication" {
            AccessibilityTreeRequester.requestIfNeeded(app: app, pid: pid, debug: debug)
            return .unknown("只命中到 \(hitRole)，App 未暴露窗口内容")
        }
        if let interactive = interactiveAncestor(of: hit) {
            return .notEditable("命中 \(hitRole)，在可点击的 \(interactive) 上")
        }
        // 可点的东西（发送按钮等）先排除：长按开始录音时会给 App 合成一次「松开」，落在按钮上就等于点了它
        if let nearInput {
            let why = "命中 \(hitRole)，离 \(role(of: nearInput)) 不到 \(Int(inputSnapDistance))pt（吸附）"
            if let enabled = attribute(nearInput, kAXEnabledAttribute) as? Bool, enabled == false {
                return .notEditable("\(why) 但已禁用")
            }
            return .editableNearby(why, nearInput)
        }
        return .askable("命中 \(hitRole)，不可点击")
    }

    /// 能点的东西：按钮、链接、图片、菜单、列表行、Dock 图标……或者任何带「按下」动作的元素。
    /// 向上看 4 层，因为按钮里往往包着一个 AXStaticText。
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXImage", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXSlider", "AXScrollBar", "AXDisclosureTriangle", "AXTab",
        "AXRow", "AXCell", "AXDockItem", "AXIncrementor", "AXColorWell", "AXValueIndicator",
        "AXMenu", "AXHandle", "AXTabGroup",
    ]

    /// 「带 AXPress 动作」只有在元素体积像按钮/链接时才算可点击：网页 App（Claude、Notion 这类）
    /// 会给整块消息区、整个面板都挂点击响应，按面积一刀切会把整页判成不可问。
    static let maxPressableWidth: CGFloat = 520
    static let maxPressableHeight: CGFloat = 160

    static func interactiveAncestor(of el: AXUIElement) -> String? {
        var cur = el
        for level in 0...4 {
            let r = role(of: cur)
            if interactiveRoles.contains(r) { return r }
            if level <= 2 {
                var names: CFArray?
                if AXUIElementCopyActionNames(cur, &names) == .success, let list = names as? [String], list.contains("AXPress") {
                    let f = frame(of: cur) ?? .zero
                    if f.width <= maxPressableWidth && f.height <= maxPressableHeight {
                        return "\(r)(可按下 \(Int(f.width))x\(Int(f.height)))"
                    }
                }
            }
            guard let parent = attribute(cur, kAXParentAttribute) else { return nil }
            cur = parent as! AXUIElement
        }
        return nil
    }

    /// Chromium 类 App 的命中查询是「先给粗略答案、后台再算精确、下次再问才准」，
    /// 按下后先问一次让它开始算，到阈值时再问一次拿准确结果。
    static func warmUp(point: CGPoint, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        _ = elementAtPosition(app, point)
    }

    // MARK: - 判定细节

    private static func editableIfEnabled(_ el: AXUIElement, why: String) -> TextInputVerdict {
        if let enabled = attribute(el, kAXEnabledAttribute) as? Bool, enabled == false {
            return .notEditable("\(why) 但已禁用")
        }
        return .editable(why)
    }

    static func nearestTextInputAncestor(of el: AXUIElement) -> (Int, AXUIElement)? {
        var cur = el
        for level in 0...maxAncestorLevels {
            if isTextInput(cur) { return (level, cur) }
            guard let parent = attribute(cur, kAXParentAttribute) else { return nil }
            cur = parent as! AXUIElement
        }
        return nil
    }

    /// 在 root 的子树里找 frame 包含 point 的最内层输入框。返回 (子树里是否存在任何输入框, 找到的最内层, 吸附候选)。
    /// 分两步：先不看位置、小预算地扫一遍「有没有内层输入框」（Notion 整页那个大容器里全是编辑块，
    /// 扫几十个节点就能碰到）；再只沿「frame 包含指针」的分支下探找包含指针的那个。
    /// frame 读不到的节点也下探（Chromium 偶尔不给 frame）。
    /// snap > 0 时下探范围放宽 snap 点，并返回不包含指针、但离指针 snap 点以内最近的输入框。
    static func innermostTextInput(within root: AXUIElement, containing point: CGPoint, snap: CGFloat = 0) -> (Bool, AXUIElement?, AXUIElement?) {
        var anyInput = false
        var scanQueue: [(AXUIElement, Int)] = children(of: root).map { ($0, 1) }
        var scanned = 0
        while !scanQueue.isEmpty && scanned < maxExistenceScanVisits {
            let (el, depth) = scanQueue.removeFirst()
            scanned += 1
            if isTextInput(el) { anyInput = true; break }
            guard depth < maxExistenceScanDepth else { continue }
            for c in children(of: el) { scanQueue.append((c, depth + 1)) }
        }

        var queue: [(AXUIElement, Int)] = children(of: root).map { ($0, 1) }
        var visited = 0
        var best: AXUIElement?
        var bestDepth = -1
        var near: AXUIElement?
        var nearDistance = CGFloat.greatestFiniteMagnitude
        while !queue.isEmpty && visited < maxDescendantVisits {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let f = frame(of: el)
            let contains = f.map { $0.insetBy(dx: -2, dy: -2).contains(point) } ?? true
            let reachable = f.map { $0.insetBy(dx: -2 - snap, dy: -2 - snap).contains(point) } ?? true
            if isTextInput(el) {
                anyInput = true
                if let f, f.width > 1, f.height > 1 {
                    if contains {
                        if depth > bestDepth {
                            best = el
                            bestDepth = depth
                        }
                    } else if snap > 0 {
                        let d = hypot(max(f.minX - point.x, 0, point.x - f.maxX), max(f.minY - point.y, 0, point.y - f.maxY))
                        if d <= snap, d < nearDistance {
                            near = el
                            nearDistance = d
                        }
                    }
                }
            }
            guard reachable, depth < maxDescendantDepth else { continue }
            for c in children(of: el) { queue.append((c, depth + 1)) }
        }
        return (anyInput, best, near)
    }

    // MARK: - AX 小工具

    static func isTextInput(_ el: AXUIElement) -> Bool { textInputRoles.contains(role(of: el)) }

    static func role(of el: AXUIElement) -> String { attribute(el, kAXRoleAttribute) as? String ?? "?" }

    static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func children(of el: AXUIElement) -> [AXUIElement] {
        guard let arr = attribute(el, kAXChildrenAttribute) as? NSArray else { return [] }
        return arr.map { $0 as! AXUIElement }
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        guard let p = attribute(el, kAXPositionAttribute), let s = attribute(el, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func elementAtPosition(_ app: AXUIElement, _ point: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &el)
        return err == .success ? el : nil
    }

    static func describeFrame(_ el: AXUIElement) -> String {
        guard let f = frame(of: el) else { return "(no frame)" }
        return String(format: "(%.0f,%.0f %.0fx%.0f)", f.origin.x, f.origin.y, f.width, f.height)
    }

    static func fmt(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
}

/// 微信（Qt 自绘）对辅助功能完全不暴露窗口内容，连命中和焦点都拿不到，只能按窗口位置估算：
/// 主窗口 = 左侧图标栏 + 聊天列表 + 右侧聊天面板；聊天面板底部是输入框，输入框下面一行是工具栏。
/// 只把「聊天面板 × 输入框区域」当输入框；工具栏（表情/发送）那一行和消息区都排除。
/// 这是针对微信当前布局的补丁，不是通用能力；分隔条被拖动过、微信改版时需要调整。
enum WeChatInputRegion {
    static let bundleIDs: Set<String> = ["com.tencent.xinWeChat"]
    static let mainWindowTitles: Set<String> = ["微信", "WeChat"]
    /// 图标栏(约 60) + 聊天列表(约 235) 的固定宽度，再留一点余量
    static let chatPaneLeftInset: CGFloat = 300
    /// 消息区与输入框之间的分隔条默认在窗口高度约 78% 处（2026-09 实测 4.1.x）
    static let inputTopRatio: CGFloat = 0.78
    /// 输入框底下的工具栏高度（表情、文件、截图、语音、发送）
    static let toolbarHeight: CGFloat = 50
    static let rightInset: CGFloat = 8
    /// 微信 4.x 会把公众号文章、小程序等面板嵌在主窗口右侧，和聊天面板同属一个窗口、系统分不开。
    /// 面板打开时聊天输入框只剩左边几百点宽，所以只认输入区域最左边这一段，避免把面板底部当成输入框。
    /// 代价：窗口很宽又没开面板时，只有输入框左半部分能触发。
    static let maxInputWidth: CGFloat = 480

    static func verdict(point: CGPoint, app: AXUIElement, debug: (String) -> Void) -> TextInputVerdict {
        guard let windows = TextInputLocator.attribute(app, kAXWindowsAttribute) as? NSArray else {
            return .unknown("微信：读不到窗口列表")
        }
        for item in windows {
            let window = item as! AXUIElement
            guard let f = TextInputLocator.frame(of: window), f.contains(point) else { continue }
            let title = TextInputLocator.attribute(window, kAXTitleAttribute) as? String ?? ""
            guard mainWindowTitles.contains(title) else {
                return .unknown("微信：非主窗口「\(title)」暂不支持")
            }
            let region = inputRegion(inWindow: f)
            debug("wechat window \(TextInputLocator.fmt(f.origin)) \(Int(f.width))x\(Int(f.height)) region=\(region)")
            if region.contains(point) {
                return .editable("微信主窗口底部输入区域")
            }
            // 聊天消息区域（输入框上方、聊天标题栏下方、聊天列表右侧）：当作可问 AI。
            // 看不出按在文字还是图片上，松手那下点击若落在图片/链接会把它打开——Ray 选择接受（2026-09-10）。
            if messageRegion(inWindow: f).contains(point) {
                return .askable("微信聊天消息区域")
            }
            return .notEditable("微信主窗口但不在输入区域")
        }
        return .unknown("微信：指针不在任何窗口内")
    }

    /// 聊天标题栏（联系人名那一行）高度
    static let chatHeaderHeight: CGFloat = 64

    static func messageRegion(inWindow f: CGRect) -> CGRect {
        let top = f.minY + chatHeaderHeight
        let bottom = f.minY + f.height * inputTopRatio
        let left = f.minX + chatPaneLeftInset
        let right = f.maxX - rightInset
        guard bottom > top, right > left else { return .null }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func inputRegion(inWindow f: CGRect) -> CGRect {
        let top = f.minY + f.height * inputTopRatio
        let bottom = f.maxY - toolbarHeight
        let left = f.minX + chatPaneLeftInset
        let right = min(f.maxX - rightInset, left + maxInputWidth)
        guard bottom > top, right > left else { return .null }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Electron / Chromium 类 App 可能默认不建辅助功能树（Notion 就是），对 App 元素设一次
/// AXManualAccessibility=true 它就会开始建树（约十几秒后可用；setter 有 2 秒防抖，勿重复设；
/// getter 读回 false 不代表失败）。对不支持的 App 设置会报错，无副作用。每个进程一分钟最多请求一次。
enum AccessibilityTreeRequester {
    private static var lastRequest: [pid_t: TimeInterval] = [:]
    private static let lock = NSLock()
    static let minInterval: TimeInterval = 60

    static func requestIfNeeded(app: AXUIElement, pid: pid_t, debug: (String) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let last = lastRequest[pid], now - last < minInterval {
            lock.unlock()
            return
        }
        lastRequest[pid] = now
        lock.unlock()
        let err = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        debug("requested accessibility tree from pid \(pid): \(err == .success ? "ok" : "err \(err.rawValue)")")
    }
}
