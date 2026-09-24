import Cocoa
import Combine
import ObjectiveC
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 设置界面的单一数据源。
/// 值仍然存在 VoicePolishConfig（键名、读写 API 都不变），这里只做两件事：读出当前值、写入后广播。
/// 同一个设置在首页、探索页、设置页各有一个控件，控件建好时订阅这里的 @Published 属性，
/// 值变了就地改自己，不用 invalidate 重建整页（重建会打断开关动画、让页面跳动）。
///
/// 外部写入（菜单栏、HotkeyManager、AppDelegate 改了设置）只要照旧发 .voicePolishHotkeyDidChange，
/// 这里收到后重读一遍；切回 App 时也重读一遍，兜住手改 config.json 之类的情况。
/// 只在值真的变了时才赋值，订阅方不会收到重复的同一个值。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// 三套快捷键此刻的样子。显示名（「左 Option」）和撞键提示都取决于另外两套，所以放一起算、一起发
    struct Hotkeys: Equatable {
        /// nil = 不设置
        var recording: RecordingHotkeyShortcut?
        var screen: RecordingHotkeyShortcut?
        var plain: RecordingHotkeyShortcut?
        var recordingTitle: String
        var screenTitle: String
        var plainTitle: String
        var screenConflict: String?
        var plainConflict: String?
        /// 单击快捷键开始/停止录音
        var tapToggleEnabled: Bool

        static func load(from config: VoicePolishConfig = .shared) -> Hotkeys {
            let recording: RecordingHotkeyShortcut? = RecordingHotkeyShortcut.isDisabled(in: config)
                ? nil : RecordingHotkeyShortcut.current(in: config)
            return Hotkeys(
                recording: recording,
                screen: AskHotkey.screen.current(in: config),
                plain: AskHotkey.plain.current(in: config),
                recordingTitle: HotkeyArbiter.displayName(for: "recording", shortcut: recording, in: config),
                screenTitle: AskHotkey.screen.displayName(in: config),
                plainTitle: AskHotkey.plain.displayName(in: config),
                screenConflict: AskHotkey.screen.conflict(in: config),
                plainConflict: AskHotkey.plain.conflict(in: config),
                tapToggleEnabled: RecordingHotkeyBehavior.isTapToggleEnabled(in: config))
        }

        func shortcut(of hotkey: AskHotkey) -> RecordingHotkeyShortcut? {
            hotkey.prefix == AskHotkey.plain.prefix ? plain : screen
        }

        func title(of hotkey: AskHotkey) -> String {
            hotkey.prefix == AskHotkey.plain.prefix ? plainTitle : screenTitle
        }

        func conflict(of hotkey: AskHotkey) -> String? {
            hotkey.prefix == AskHotkey.plain.prefix ? plainConflict : screenConflict
        }
    }

    @Published private(set) var hotkeys: Hotkeys
    /// 联网回答下方附图
    @Published private(set) var askImagesEnabled: Bool
    /// 回答前先思考
    @Published private(set) var askThinkingEnabled: Bool
    @Published private(set) var askThinkingEffort: AskThinkingEffort

    private let config: VoicePolishConfig
    private var observers: [NSObjectProtocol] = []

    private init(config: VoicePolishConfig = .shared) {
        self.config = config
        hotkeys = Hotkeys.load(from: config)
        askImagesEnabled = ImageSearch.isEnabled
        askThinkingEnabled = AskThinkingSettings.isEnabled
        askThinkingEffort = AskThinkingSettings.effort

        let center = NotificationCenter.default
        // queue 传 nil：主线程发的通知同步处理，发通知的地方返回时各页按钮已经是新值
        observers.append(center.addObserver(forName: .voicePolishHotkeyDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.onMain { $0.reloadHotkeys() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        })
    }

    // MARK: 读

    /// 全部重读一遍（切回 App 时调用，兜住外部改了 config 的情况）
    func reload() {
        reloadHotkeys()
        update(\.askImagesEnabled, ImageSearch.isEnabled)
        update(\.askThinkingEnabled, AskThinkingSettings.isEnabled)
        update(\.askThinkingEffort, AskThinkingSettings.effort)
    }

    private func reloadHotkeys() {
        update(\.hotkeys, Hotkeys.load(from: config))
    }

    // MARK: 写

    /// 快捷键已经写进 config 之后调用：重读并通知所有人（HotkeyManager、菜单栏、本 store 自己）。
    /// 三套快捷键互相影响（撞键谁让谁、Option 只认左边），所以任何一套变了都整组重算
    func hotkeysDidChange() {
        NotificationCenter.default.post(name: .voicePolishHotkeyDidChange, object: nil)
        reloadHotkeys()   // 通知在后台线程发出时 observer 会异步重读，这里保证主线程调用方返回前已是新值
    }

    func setTapToggleEnabled(_ on: Bool) {
        config.save(bool: on, forKey: RecordingHotkeyBehavior.tapToggleConfigKey)
        hotkeysDidChange()   // HotkeyManager 要重读单击开关
    }

    func setAskImagesEnabled(_ on: Bool) {
        config.save(bool: on, forKey: ImageSearch.settingKey)
        update(\.askImagesEnabled, ImageSearch.isEnabled)
    }

    func setAskThinkingEnabled(_ on: Bool) {
        config.save(bool: on, forKey: AskThinkingSettings.enabledKey)
        update(\.askThinkingEnabled, AskThinkingSettings.isEnabled)
    }

    func setAskThinkingEffort(_ effort: AskThinkingEffort) {
        config.save(value: effort.rawValue, forKey: AskThinkingSettings.effortKey)
        update(\.askThinkingEffort, AskThinkingSettings.effort)
    }

    // MARK: 内部

    /// 值没变就不赋值：@Published 每次赋值都会发，哪怕是同一个值
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func onMain(_ work: @escaping (SettingsStore) -> Void) {
        if Thread.isMainThread { work(self) } else { DispatchQueue.main.async { work(self) } }
    }
}

// MARK: - 订阅挂在控件身上

private var settingsSubscriptionsKey: UInt8 = 0

/// 一个对象身上的全部订阅。对象释放时这个盒子跟着释放，里面的 AnyCancellable 自动取消订阅
private final class SubscriptionBag {
    var items: [AnyCancellable] = []
}

extension NSObjectProtocol where Self: NSObject {
    /// 订阅 publisher，每来一个值调 update(自己, 新值)。订阅时会先收到一次当前值。
    /// 订阅存在对象自己身上（关联对象），对象释放就自动取消；闭包里对象是弱引用，不会互相持有。
    /// 用 @Published 时拿到的是新值本身，这一刻 store 的属性还没改完，闭包里别回头读 store
    func subscribe<P: Publisher>(_ publisher: P, _ update: @escaping (Self, P.Output) -> Void) where P.Failure == Never {
        let cancellable = publisher.sink { [weak self] value in
            guard let self else { return }
            update(self, value)
        }
        let bag = (objc_getAssociatedObject(self, &settingsSubscriptionsKey) as? SubscriptionBag) ?? {
            let bag = SubscriptionBag()
            objc_setAssociatedObject(self, &settingsSubscriptionsKey, bag, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return bag
        }()
        bag.items.append(cancellable)
    }
}
