import XCTest
@testable import VoicePolishCore

final class AIPolisherTests: XCTestCase {

    // MARK: - 润色额度/业务错误提取（修静默跳过的 bug）

    func testExtractAPIErrorMessageFromCommonShapes() {
        // OpenAI/qwen 兼容：{"error":{"message":...}}，额度类 → 翻成中文并带 code
        XCTAssertEqual(
            AIPolisher.extractAPIErrorMessage(from: ["error": ["message": "Free allocated quota exceeded", "code": "insufficient_quota"]]),
            "账号欠费或免费额度已用完，请到服务商控制台检查（insufficient_quota）")
        // DashScope 欠费：顶层 code+message
        XCTAssertEqual(
            AIPolisher.extractAPIErrorMessage(from: ["code": "Arrearage", "message": "Access denied, please make sure your account has enough balance"]),
            "账号欠费或免费额度已用完，请到服务商控制台检查（Arrearage）")
        // error 为字符串：限流 → 中文
        XCTAssertEqual(AIPolisher.extractAPIErrorMessage(from: ["error": "rate limit exceeded"]), "请求太频繁或额度超限，稍后再试")
        // 只有 code：Key 错 → 中文
        XCTAssertEqual(AIPolisher.extractAPIErrorMessage(from: ["error": ["code": "InvalidApiKey"]]), "API Key 无效，请检查是否复制完整（InvalidApiKey）")
        // 认不出的错误：保留原话
        XCTAssertEqual(AIPolisher.extractAPIErrorMessage(from: ["error": ["message": "model qwen-x is not supported", "code": "invalid_parameter_error"]]),
                       "model qwen-x is not supported")
        // 正常响应（有 choices）→ 无错误可提取
        XCTAssertNil(AIPolisher.extractAPIErrorMessage(from: ["choices": [["message": ["content": "ok"]]]]))
        XCTAssertNil(AIPolisher.extractAPIErrorMessage(from: nil))
    }

    /// 2026-08-17 用真实 key 打服务商实测抓回来的原文，确保翻译命中
    func testFriendlyProviderErrorMatchesRealPayloads() {
        // 百炼 DashScope：Key 错（HTTP 401）
        XCTAssertEqual(
            AIPolisher.extractAPIErrorMessage(from: ["error": [
                "message": "Incorrect API key provided. For details, see: https://help.aliyun.com/zh/model-studio/error-code#apikey-error",
                "type": "invalid_request_error", "code": "invalid_api_key"]]),
            "API Key 无效，请检查是否复制完整（invalid_api_key）")
        // 百炼 DashScope：没带 Key（HTTP 401，code 为 null）
        XCTAssertEqual(
            AIPolisher.extractAPIErrorMessage(from: ["error": [
                "message": "You didn't provide an API key. You need to provide your API key in an Authorization header using Bearer auth (i.e. Authorization: Bearer YOUR_KEY). ",
                "type": "invalid_request_error", "code": NSNull()]]),
            "API Key 无效，请检查是否复制完整")
        // 火山 Ark：Key 错（HTTP 401）
        XCTAssertEqual(
            AIPolisher.extractAPIErrorMessage(from: ["error": [
                "code": "AuthenticationError",
                "message": "The API key format is incorrect. Request id: 0217869805600638c140f267f4351837af8462310b5bfee937427",
                "param": "", "type": "Unauthorized"]]),
            "API Key 无效，请检查是否复制完整（AuthenticationError）")
    }

    func testPolishErrorAPIErrorCarriesMessage() {
        let err = AIPolisher.PolishError.apiError("余额不足")
        XCTAssertEqual(err.errorDescription, "余额不足")
    }

    func testIsPolishDisabledOnlyForNone() {
        XCTAssertTrue(AIPolisher.isPolishDisabled(provider: "none"))
        XCTAssertTrue(AIPolisher.isPolishDisabled(provider: " None "))
        XCTAssertFalse(AIPolisher.isPolishDisabled(provider: "doubao"))
        XCTAssertFalse(AIPolisher.isPolishDisabled(provider: "qwen"))
        XCTAssertFalse(AIPolisher.isPolishDisabled(provider: nil))
        XCTAssertFalse(AIPolisher.isPolishDisabled(provider: ""))
    }

    func testCloudASRPolishPromptProtectsEnglishInputLanguage() {
        let prompt = AIPolisher.makeCloudASRPolishUserPrompt(
            for: "So, I just had a call with WeCare today, and it was good."
        )

        XCTAssertTrue(prompt.hasPrefix("Keep the original language. Do not translate."))
        XCTAssertTrue(prompt.contains("So, I just had a call with WeCare today"))
    }

    func testCloudASRPolishPromptProtectsMixedInputLanguage() {
        let prompt = AIPolisher.makeCloudASRPolishUserPrompt(
            for: "我今天和 WeCare 开了一个 call，然后她让我准备 SOW。"
        )

        XCTAssertTrue(prompt.hasPrefix("Keep the original language. Do not translate."))
        XCTAssertTrue(prompt.contains("我今天和 WeCare"))
    }

    func testCloudASRPolishPromptUsesChineseWrapperForChineseInput() {
        let prompt = AIPolisher.makeCloudASRPolishUserPrompt(
            for: "我觉得这个功能现在有点奇怪。"
        )

        XCTAssertTrue(prompt.hasPrefix("待整理文本："))
        XCTAssertFalse(prompt.contains("Do not translate"))
    }

    func testMakePolishLogEntryUsesInjectedAppName() {
        let polisher = AIPolisher()
        polisher.polishLogAppNameProvider = { "Finder" }

        let entry = polisher.makePolishLogEntry(
            asr: "原始转写",
            output: "整理结果",
            durationMs: 123,
            inputTokens: 45,
            outputTokens: 67
        )

        XCTAssertEqual(entry.app, "Finder")
        XCTAssertEqual(entry.asr, "原始转写")
        XCTAssertEqual(entry.output, "整理结果")
        XCTAssertEqual(entry.duration_ms, 123)
        XCTAssertEqual(entry.input_tokens, 45)
        XCTAssertEqual(entry.output_tokens, 67)
    }

    func testHistoryRetentionKeepsAllByDefault() {
        let old = AIPolisher.PolishLog(
            time: "2026-01-01 10:00:00",
            app: "Finder",
            asr: "old",
            output: "old",
            duration_ms: 1,
            input_tokens: 0,
            output_tokens: 0
        )

        XCTAssertTrue(AIPolisher.shouldKeepPolishLog(old, retention: .forever, now: fixedDate("2026-05-19 10:00:00")))
    }

    func testHistoryRetentionDropsEntriesOlderThanOneDay() {
        let now = fixedDate("2026-05-19 10:00:00")
        let recent = AIPolisher.PolishLog(
            time: "2026-05-18 10:00:00",
            app: "Finder",
            asr: "recent",
            output: "recent",
            duration_ms: 1,
            input_tokens: 0,
            output_tokens: 0
        )
        let old = AIPolisher.PolishLog(
            time: "2026-05-18 09:59:59",
            app: "Finder",
            asr: "old",
            output: "old",
            duration_ms: 1,
            input_tokens: 0,
            output_tokens: 0
        )

        XCTAssertTrue(AIPolisher.shouldKeepPolishLog(recent, retention: .oneDay, now: now))
        XCTAssertFalse(AIPolisher.shouldKeepPolishLog(old, retention: .oneDay, now: now))
    }

    func testHistoryRetentionOffKeepsNothing() {
        let now = fixedDate("2026-05-19 10:00:00")
        // 「不保存数据」：即便是此刻刚生成的记录也不应保留
        let justNow = AIPolisher.PolishLog(
            time: "2026-05-19 10:00:00",
            app: "Finder",
            asr: "now",
            output: "now",
            duration_ms: 1,
            input_tokens: 0,
            output_tokens: 0
        )

        XCTAssertFalse(AIPolisher.shouldKeepPolishLog(justNow, retention: .off, now: now))
    }

    func testPruneLogFileRewritesOnlyExpiredEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepolish-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("polish_log.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let encoder = JSONEncoder()
        let keep = AIPolisher.PolishLog(
            time: "2026-05-18 10:00:00",
            app: "Finder",
            asr: "keep",
            output: "keep",
            duration_ms: 1,
            input_tokens: 0,
            output_tokens: 0
        )
        let drop = AIPolisher.PolishLog(
            time: "2026-05-18 09:59:59",
            app: "Finder",
            asr: "drop",
            output: "drop",
            duration_ms: 1,
            input_tokens: 0,
            output_tokens: 0
        )
        let content = try [drop, keep]
            .map { try String(data: encoder.encode($0), encoding: .utf8).unwrap() }
            .joined(separator: "\n") + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let removed = AIPolisher.pruneLogFile(at: file, retention: .oneDay, now: fixedDate("2026-05-19 10:00:00"))
        let remaining = try String(contentsOf: file, encoding: .utf8)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(remaining.contains("drop"))
        XCTAssertTrue(remaining.contains("keep"))
    }

    private func fixedDate(_ raw: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)!
    }
}

private extension Optional {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        guard let value = self else {
            XCTFail("Expected non-nil optional", file: file, line: line)
            throw NSError(domain: "VoicePolishCoreTests", code: 1)
        }
        return value
    }
}
