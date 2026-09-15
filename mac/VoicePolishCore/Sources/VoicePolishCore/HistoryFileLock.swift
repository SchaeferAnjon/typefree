import Foundation

/// 历史文件（polish_log.jsonl）的进程内串行锁。
///
/// 追加一条、按保留期裁剪、编辑/删除单条这些操作分别来自 pipeline 后台队列、
/// 设置窗主线程、自动学词队列，之前互不相知：整文件重写基于旧快照落盘时，
/// 刚追加进去的那条记录就没了。所有读-改-写都包进 `withLock`。
/// 同一线程内嵌套调用直接执行，不会死锁。
public enum HistoryFileLock {
    private static let queue = DispatchQueue(label: "com.voicepolish.history-file")
    private static let onQueueKey = DispatchSpecificKey<Bool>()
    private static let setup: Void = {
        queue.setSpecific(key: onQueueKey, value: true)
    }()

    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        _ = setup
        if DispatchQueue.getSpecific(key: onQueueKey) == true {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}
