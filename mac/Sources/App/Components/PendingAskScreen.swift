import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 提问附带的屏幕内容：触发瞬间开始截，用户说话时在后台画标记、缩放、编码。
/// 提问要发出去时图多半已经好了；万一还没好，onReady 会等一会儿，等不到就退回纯文本。
final class PendingAskScreen {
    private var result: Result<ScreenSnapshot, ScreenSnapshotError>?
    private var waiters: [(Result<ScreenSnapshot, ScreenSnapshotError>?) -> Void] = []
    private var cancelled = false

    func complete(_ value: Result<ScreenSnapshot, ScreenSnapshotError>) {
        guard result == nil, !cancelled else { return }
        result = value
        let pending = waiters
        waiters = []
        for waiter in pending { waiter(value) }
    }

    /// 图好了立刻回调；还没好就等，超过 timeout 还没来就回 nil（退回纯文本，不让用户干等）
    func onReady(timeout: TimeInterval, _ callback: @escaping (Result<ScreenSnapshot, ScreenSnapshotError>?) -> Void) {
        if let result { callback(result); return }
        var delivered = false
        let once: (Result<ScreenSnapshot, ScreenSnapshotError>?) -> Void = { value in
            guard !delivered else { return }
            delivered = true
            callback(value)
        }
        waiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once(nil) }
    }

    func cancel() {
        cancelled = true
        waiters.removeAll()
    }
}
