import XCTest
@testable import VoicePolishCore

final class VocabularyMinerTests: XCTestCase {

    private func sample(_ text: String, day: String) -> VocabularyMiner.Sample {
        VocabularyMiner.Sample(text: text, day: day)
    }

    func testLearnsRecurringTermAcrossDays() {
        let samples = [
            sample("今天用 Wrangler 部署了服务", day: "2026-07-01"),
            sample("Wrangler 的配置有点绕", day: "2026-07-01"),
            sample("又跑了一次 Wrangler 命令", day: "2026-07-02"),
        ]
        let words = VocabularyMiner.newWords(from: samples, existingLowercased: [])
        XCTAssertEqual(words, ["Wrangler"])
    }

    func testIgnoresBelowRecordOrDayThreshold() {
        // 只出现 2 条记录
        let fewRecords = [
            sample("用 Zustand 管理状态", day: "2026-07-01"),
            sample("Zustand 挺好用", day: "2026-07-02"),
        ]
        XCTAssertTrue(VocabularyMiner.newWords(from: fewRecords, existingLowercased: []).isEmpty)

        // 3 条记录但同一天（一次长对话刷屏不算）
        let oneDay = [
            sample("Vite 构建", day: "2026-07-01"),
            sample("Vite 很快", day: "2026-07-01"),
            sample("Vite 配置", day: "2026-07-01"),
        ]
        XCTAssertTrue(VocabularyMiner.newWords(from: oneDay, existingLowercased: []).isEmpty)
    }

    func testIgnoresStopwordsExistingAndDismissed() {
        let samples = [
            sample("this is the GitHub repo and the Tailwind config", day: "2026-07-01"),
            sample("the GitHub action with Tailwind", day: "2026-07-02"),
            sample("GitHub 和 Tailwind 都要", day: "2026-07-03"),
        ]
        let words = VocabularyMiner.newWords(
            from: samples,
            existingLowercased: ["github"],
            dismissedLowercased: ["tailwind"]
        )
        // the/is/and/with 是停用词；GitHub 已有；Tailwind 被用户删过
        XCTAssertTrue(words.isEmpty)
    }

    func testPicksMajorityCasingAndPrefersUppercaseOnTie() {
        let majority = [
            sample("GitHub 上看看", day: "2026-07-01"),
            sample("GitHub 的 issue", day: "2026-07-02"),
            sample("github pages 部署", day: "2026-07-03"),
        ]
        XCTAssertEqual(VocabularyMiner.newWords(from: majority, existingLowercased: []), ["GitHub"])

        // 平票：Figma 1 次、figma 1 次 → 偏好带大写的写法
        XCTAssertEqual(VocabularyMiner.canonicalForm(of: ["Figma": 1, "figma": 1]), "Figma")
    }

    func testRespectsCapacityAndRanksByDaysThenCount() {
        // Alpha 跨 3 天；Beta 跨 2 天——容量 1 时应选 Alpha
        let samples = [
            sample("Alpha Beta", day: "2026-07-01"),
            sample("Alpha Beta", day: "2026-07-02"),
            sample("Alpha 单独出现", day: "2026-07-03"),
            sample("Beta 又来", day: "2026-07-02"),
        ]
        let words = VocabularyMiner.newWords(from: samples, existingLowercased: [], remainingCapacity: 1)
        XCTAssertEqual(words, ["Alpha"])
        XCTAssertTrue(VocabularyMiner.newWords(from: samples, existingLowercased: [], remainingCapacity: 0).isEmpty)
    }

    func testTokenizerHandlesCJKAdjacencyPunctuationAndConnectors() {
        let tokens = VocabularyMiner.latinTokens(in: "我用Cursor写代码，跑GPT-4和Node.js（还有C++）。", minLength: 2, maxLength: 24)
        XCTAssertEqual(tokens, ["Cursor", "GPT-4", "Node.js", "C++"])

        // 首尾连接符被裁掉；纯数字不算词
        let edge = VocabularyMiner.latinTokens(in: "-Swift- 2026 ..dots..", minLength: 2, maxLength: 24)
        XCTAssertEqual(edge, ["Swift", "dots"])
    }
}
