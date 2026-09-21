import Cocoa
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension Notification.Name {
    /// 指针问 AI 的设置改了（开关、修饰键、倾听模式）：触发器重读配置
    static let voicePolishAskAtCursorDidChange = Notification.Name("VoicePolishAskAtCursorDidChange")
}

/// 指针问 AI：按住修饰键再点左键，指针在哪就问哪。
///
/// 和 MouseHoldToTalkManager 的根本区别是这里用 CGEventTap 的 defaultTap，能把事件吞掉。
/// 旁听式的 NSEvent 全局监听拦不住点击，所以老的「长按问 AI」只能挑空白处；
/// 这里既然能吞，按钮、链接、输入框、视频上就都能问，那一下点击不会传给底下的 App
/// （不然会点开链接，Option + 点击在浏览器里还会触发下载）。
///
/// 事件回调里只跑状态机（纯计算），真正的活儿一律 DispatchQueue.main.async 出去，
/// 回调本身不做任何跨进程调用，免得被系统按超时禁用。
final class AskAtCursorTrigger {
    /// 指针问 AI 开始：参数是触发点（Quartz 全局坐标，原点左上）。返回 false = 没开成，状态回退。
    var onBegin: ((CGPoint) -> Bool)?
    /// 结束录音并提问
    var onFinish: (() -> Void)?
    /// 丢掉这次录音，不提问（Esc）
    var onCancel: (() -> Void)?
    /// 此刻能不能开一次新的提问
    var canStart: (() -> Bool)?
    var debugLog: ((String) -> Void)?

    private var machine = AskCursorMachine(combo: AskAtCursorSettings.combo, mode: AskAtCursorSettings.listenMode)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var escMonitors: [Any] = []
    private var timeoutTimer: Timer?
    private var didLogTapFailure = false

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: .voicePolishAskAtCursorDidChange, object: nil)
    }

    /// 回调都接好之后再调，这样装不上事件拦截（没给辅助功能权限）也能记进日志
    func start() {
        applySettings()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        uninstallTap()
    }

    var isListening: Bool { eventTap != nil }

    func stop() {
        stopTimeout()
        removeEscMonitors()
        uninstallTap()
    }

    /// 录音被别的途径停掉（快捷键、菜单、出错）：状态机回位，但这一下按键剩下的事件还得吞掉，
    /// 否则松手会漏给底下的 App。
    func recordingDidLeaveActiveState() {
        guard machine.isActive else { return }
        debugLog?("recording ended elsewhere, resetting")
        machine.reset()
        stopTimeout()
        removeEscMonitors()
    }

    @objc private func settingsDidChange() {
        applySettings()
    }

    private func applySettings() {
        let enabled = AskAtCursorSettings.isEnabled
        machine = AskCursorMachine(combo: AskAtCursorSettings.combo, mode: AskAtCursorSettings.listenMode)
        stopTimeout()
        removeEscMonitors()
        if enabled {
            installTap()
        } else {
            uninstallTap()
        }
        debugLog?("settings: enabled=\(enabled) modifier=\(AskAtCursorSettings.combo.configValue) mode=\(AskAtCursorSettings.listenMode.rawValue) tap=\(eventTap != nil)")
    }

    // MARK: - 事件拦截

    private func installTap() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<AskAtCursorTrigger>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,     // 要能吞事件，不能用 listenOnly
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            if !didLogTapFailure {
                didLogTapFailure = true
                debugLog?("event tap create failed (check accessibility permission)")
            }
            return
        }
        didLogTapFailure = false
        // 挂在主 run loop：状态机只在主线程碰，canStart 读的也是主线程状态，不用加锁。
        // 回调里不做任何耗时的事，所以主线程繁忙导致超时禁用的概率很低；真被禁用了下面会重新启用。
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func uninstallTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统因回调超时 / 用户输入把 tap 关了：重新启用，否则功能从此静默失效
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            debugLog?("event tap re-enabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input"))")
            return nil
        }

        let input: AskCursorMachine.Input
        switch type {
        case .leftMouseDown:
            // 点在自己窗口上（设置窗、引导窗）不接管，免得设置页里按着修饰键点东西点不动
            if isOwnWindow(event) { return Unmanaged.passUnretained(event) }
            input = .mouseDown(modifiers: event.flags)
        case .leftMouseUp:
            input = .mouseUp
        case .leftMouseDragged:
            input = .mouseDragged
        case .rightMouseDown, .otherMouseDown:
            if isOwnWindow(event) { return Unmanaged.passUnretained(event) }
            input = .otherButtonDown
        case .rightMouseUp, .otherMouseUp:
            input = .mouseUp
        default:
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        let output = machine.handle(input, canStart: canStart?() ?? false)
        if output.action != .none {
            let action = output.action
            DispatchQueue.main.async { [weak self] in self?.perform(action, at: point) }
        }
        return output.swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// 只查进程内的窗口编号，不做跨进程调用，回调里够快
    private func isOwnWindow(_ event: CGEvent) -> Bool {
        let number = Int(event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        guard number != 0 else { return false }
        return NSApp.windows.contains { $0.windowNumber == number && $0.isVisible }
    }

    private func perform(_ action: AskCursorMachine.Action, at point: CGPoint) {
        switch action {
        case .none:
            break
        case .begin:
            startTimeout()
            installEscMonitors()
            guard onBegin?(point) == true else {
                debugLog?("begin refused by app")
                machine.reset()
                stopTimeout()
                removeEscMonitors()
                return
            }
        case .finish:
            stopTimeout()
            removeEscMonitors()
            onFinish?()
        case .cancel:
            stopTimeout()
            removeEscMonitors()
            onCancel?()
        }
    }

    // MARK: - Esc 取消与安全上限

    private func installEscMonitors() {
        guard escMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.feedEscape()
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            escMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            handler(event)
            return event
        }) {
            escMonitors.append(local)
        }
    }

    private func removeEscMonitors() {
        for monitor in escMonitors { NSEvent.removeMonitor(monitor) }
        escMonitors.removeAll()
    }

    private func feedEscape() {
        let output = machine.handle(.escape, canStart: false)
        if output.action != .none {
            debugLog?("Esc → \(output.action)")
            perform(output.action, at: .zero)
        }
    }

    /// 点击切换模式录着忘了结束：到点自动结束并提问，不会一直开着麦
    private func startTimeout() {
        stopTimeout()
        let timer = Timer(timeInterval: AskAtCursorSettings.maxListenSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            let output = self.machine.handle(.timeout, canStart: false)
            guard output.action != .none else { return }
            self.debugLog?("reached the \(Int(AskAtCursorSettings.maxListenSeconds))s cap → \(output.action)")
            self.perform(output.action, at: .zero)
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    private func stopTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}
