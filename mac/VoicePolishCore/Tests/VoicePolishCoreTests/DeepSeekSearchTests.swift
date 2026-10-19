import XCTest
@testable import VoicePolishCore

final class DeepSeekSearchTests: XCTestCase {
    func testParsesResultsAndFallsBackToSnippet() throws {
        let json = """
        {"results": [
          {"title": "A", "url": "https://a", "summary": "long A", "snippet": "short A", "date": "2026-10-18T08:00:00Z"},
          {"title": "B", "url": "https://b", "summary": "", "snippet": "short B", "date": null},
          {"title": "no url"}
        ]}
        """
        let results = try XCTUnwrap(DeepSeekSearch.parseResults(Data(json.utf8)))
        XCTAssertEqual(results.map(\.url), ["https://a", "https://b"], "没有 url 的跳过")
        XCTAssertEqual(results[0].summary, "long A")
        XCTAssertEqual(results[1].summary, "short B", "summary 为空时用 snippet")
        XCTAssertNil(results[1].date)
    }

    func testEmptyResultsIsNotAnError() {
        XCTAssertEqual(DeepSeekSearch.parseResults(Data(#"{"results": []}"#.utf8)), [])
        XCTAssertNil(DeepSeekSearch.parseResults(Data(#"{"error": "x"}"#.utf8)))
    }

    func testRequestBodyCapsQueryAt128Characters() {
        let body = DeepSeekSearch.requestBody(query: String(repeating: "字", count: 200))
        XCTAssertEqual((body["query"] as? String)?.count, 128)
        XCTAssertEqual(body["count"] as? Int, DeepSeekSearch.count)
    }

    func testPromptSectionTellsModelNotToFillGaps() {
        let r = DeepSeekSearch.Result(title: "T", url: "https://t", date: "2026-10-18T08:00:00Z", summary: "S")
        let section = DeepSeekSearch.promptSection(query: "q", results: [r])
        XCTAssertTrue(section.contains("[1] T（2026-10-18） https://t\nS"))
        XCTAssertTrue(section.contains("不要凭记忆补"))
        XCTAssertTrue(DeepSeekSearch.promptSection(query: "q", results: []).contains("没有找到结果"))
    }

    func testTimeSensitiveQuestionForcesSearchToolOnDeepSeekOnly() {
        let choice = AskSearch.forcedToolChoice(provider: "deepseek", question: "这个软件最新版本是多少", offered: true, thinking: false)
        XCTAssertEqual((choice?["function"] as? [String: Any])?["name"] as? String, AskSearch.toolName)
        XCTAssertNil(AskSearch.forcedToolChoice(provider: "deepseek", question: "这段代码什么意思", offered: true, thinking: false))
        XCTAssertNil(AskSearch.forcedToolChoice(provider: "deepseek", question: "最新版本", offered: true, thinking: true), "思考模式不强制")
        XCTAssertNil(AskSearch.forcedToolChoice(provider: "deepseek", question: "最新版本", offered: false, thinking: false), "没带工具不能强制")
        XCTAssertNil(AskSearch.forcedToolChoice(provider: "zhipu", question: "最新版本", offered: true, thinking: false))
    }
}
