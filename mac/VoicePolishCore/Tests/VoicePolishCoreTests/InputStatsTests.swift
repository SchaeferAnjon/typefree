import XCTest
@testable import VoicePolishCore

final class InputStatsTests: XCTestCase {

    private var tmpURL: URL!
    private var stats: InputStats!

    override func setUp() {
        super.setUp()
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("input_stats_test_\(UUID().uuidString).json")
        stats = InputStats(fileURL: tmpURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
        super.tearDown()
    }

    private var todayStr: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    func testQuotaCharsTrackedSeparatelyFromTotal() {
        stats.record(charCount: 300, countsTowardFreeQuota: false)  // 试用期走代理的交付
        stats.record(charCount: 200, countsTowardFreeQuota: true)   // 自带 Key 的交付
        stats.record(charCount: 100, countsTowardFreeQuota: true)

        XCTAssertEqual(stats.today().charCount, 600, "总字数应包含全部交付")
        XCTAssertEqual(stats.today().sessionCount, 3)
        XCTAssertEqual(stats.currentWeekQuotaChars(), 300, "免费额度只统计自带 Key 的交付")
    }

    func testDefaultRecordDoesNotCountTowardQuota() {
        stats.record(charCount: 500)
        XCTAssertEqual(stats.today().charCount, 500)
        XCTAssertEqual(stats.currentWeekQuotaChars(), 0)
    }

    func testLegacyFileWithoutQuotaFieldDecodesAsZeroQuota() throws {
        // 旧版统计文件：没有 quotaCharCount 字段 → 总字数照常读、不占额度
        let legacy = "[{\"date\":\"\(todayStr)\",\"charCount\":1234,\"sessionCount\":3}]"
        try legacy.data(using: .utf8)!.write(to: tmpURL)

        XCTAssertEqual(stats.today().charCount, 1234, "旧记录总字数照常读出")
        XCTAssertEqual(stats.currentWeekQuotaChars(), 0, "旧记录不占额度")

        // 旧文件之上继续记账，两栏都应正确累加
        stats.record(charCount: 100, countsTowardFreeQuota: true)
        XCTAssertEqual(stats.today().charCount, 1334)
        XCTAssertEqual(stats.currentWeekQuotaChars(), 100)
    }
}
