import XCTest
@testable import VoicePolishCore

/// 模拟「钥匙串读不到」（被锁 / 用户拒绝授权 / access group 出错）的后端。
private final class FailingSecretStore: SecretStoring {
    private(set) var setCalls = 0
    func get(_ account: String) -> String? { nil }
    func lookup(_ account: String) -> SecretLookup { .error("keychain locked") }
    @discardableResult func set(_ account: String, _ value: String?) -> Bool {
        setCalls += 1
        return true
    }
}

final class HistoryKeyLossTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepolish-history-keyloss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 读不到 ≠ 没有：此时绝不能生成并写入新密钥，否则旧记录永久变乱码。
    func testLookupErrorDoesNotRegenerateKey() {
        let store = FailingSecretStore()
        XCTAssertNil(HistoryCrypto.historyKey(secrets: store, logFile: tempDir.appendingPathComponent("x.jsonl")))
        XCTAssertEqual(store.setCalls, 0)
    }

    /// 确实没有密钥、但文件里已有加密记录 → 仍生成新密钥（否则历史永久瘫痪），并广播提醒。
    func testMissingKeyWithEncryptedRecordsRegeneratesAndNotifies() throws {
        let file = tempDir.appendingPathComponent("polish_log.jsonl")
        try "\(HistoryCrypto.linePrefix)AAAA\n\(HistoryCrypto.linePrefix)BBBB\n".write(to: file, atomically: true, encoding: .utf8)

        let notified = expectation(forNotification: HistoryCrypto.keyRegeneratedNotification, object: nil)
        let store = InMemorySecretStore()
        XCTAssertNotNil(HistoryCrypto.historyKey(secrets: store, logFile: file))
        XCTAssertNotNil(store.get(HistoryCrypto.keyAccount))
        wait(for: [notified], timeout: 2)
    }

    /// 首次使用（没有文件 / 文件里没有加密记录）→ 静默生成，不打扰用户。
    func testMissingKeyWithoutEncryptedRecordsStaysSilent() throws {
        var fired = false
        let token = NotificationCenter.default.addObserver(
            forName: HistoryCrypto.keyRegeneratedNotification, object: nil, queue: .main
        ) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(token) }

        let plainOnly = tempDir.appendingPathComponent("plain.jsonl")
        try "{\"not\":\"encrypted\"}\n".write(to: plainOnly, atomically: true, encoding: .utf8)

        XCTAssertNotNil(HistoryCrypto.historyKey(secrets: InMemorySecretStore(), logFile: tempDir.appendingPathComponent("missing.jsonl")))
        XCTAssertNotNil(HistoryCrypto.historyKey(secrets: InMemorySecretStore(), logFile: plainOnly))

        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertFalse(fired)
    }

    func testHistoryFileLockIsReentrant() {
        let value = HistoryFileLock.withLock {
            HistoryFileLock.withLock { 42 }
        }
        XCTAssertEqual(value, 42)
    }

    /// 并发「读-改-写」在锁内不丢更新（这正是 pipeline 追加 vs 设置窗重写会丢条的模式）。
    func testHistoryFileLockSerializesReadModifyWrite() throws {
        let file = tempDir.appendingPathComponent("counter.jsonl")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let group = DispatchGroup()
        let iterations = 200
        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                HistoryFileLock.withLock {
                    let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    try? (content + "line-\(i)\n").write(to: file, atomically: true, encoding: .utf8)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, iterations)
    }
}
