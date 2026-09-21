import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import VoicePolishCore

/// 截图尺寸计算与请求体组装。图片键名写错过（GetNewWord 因为 imageUrl 而不是 image_url，
/// 图片半年没真正发出去过），所以这里逐个字段断言。
final class AskVisionTests: XCTestCase {

    // MARK: 缩放

    func testScaleNeverEnlarges() {
        XCTAssertEqual(AskVision.scale(pixelSize: CGSize(width: 800, height: 600), longEdge: 1000), 1)
        XCTAssertEqual(AskVision.scale(pixelSize: .zero, longEdge: 1000), 1)
    }

    func testScaleShrinksByTheLongEdge() {
        let scale = AskVision.scale(pixelSize: CGSize(width: 3024, height: 1964), longEdge: 1000)
        XCTAssertEqual(scale, 1000.0 / 3024.0, accuracy: 1e-9)
        XCTAssertEqual(3024 * scale, 1000, accuracy: 0.001)
    }

    // MARK: 裁剪框

    func testCloseUpIsCenteredOnTheCursor() {
        let rect = AskVision.closeUpRect(center: CGPoint(x: 1500, y: 1000),
                                         imagePixelSize: CGSize(width: 3024, height: 1964),
                                         pointSize: CGSize(width: 900, height: 700),
                                         scale: 2)
        XCTAssertEqual(rect.width, 1800)
        XCTAssertEqual(rect.height, 1400)
        XCTAssertEqual(rect.midX, 1500)
        XCTAssertEqual(rect.midY, 1000)
    }

    /// 贴边时整体平移回图内，尺寸不变：放大图永远是同一个清晰度
    func testCloseUpSlidesBackInsteadOfShrinkingAtTheEdge() {
        let size = CGSize(width: 3024, height: 1964)
        let topLeft = AskVision.closeUpRect(center: CGPoint(x: 5, y: 5), imagePixelSize: size,
                                            pointSize: CGSize(width: 900, height: 700), scale: 2)
        XCTAssertEqual(topLeft.origin, .zero)
        XCTAssertEqual(topLeft.size, CGSize(width: 1800, height: 1400))

        let bottomRight = AskVision.closeUpRect(center: CGPoint(x: 3020, y: 1960), imagePixelSize: size,
                                                pointSize: CGSize(width: 900, height: 700), scale: 2)
        XCTAssertEqual(bottomRight.maxX, size.width)
        XCTAssertEqual(bottomRight.maxY, size.height)
        XCTAssertEqual(bottomRight.size, CGSize(width: 1800, height: 1400))
    }

    /// 屏幕比裁剪框还小：取整张，不能算出负的原点
    func testCloseUpTakesTheWholeImageWhenItIsSmallerThanTheCrop() {
        let size = CGSize(width: 1280, height: 800)
        let rect = AskVision.closeUpRect(center: CGPoint(x: 640, y: 400), imagePixelSize: size,
                                         pointSize: CGSize(width: 900, height: 700), scale: 2)
        XCTAssertEqual(rect, CGRect(origin: .zero, size: size))
    }

    func testCloseUpAlwaysContainsTheCursor() {
        let size = CGSize(width: 3024, height: 1964)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 3024, y: 1964), CGPoint(x: 1, y: 1900), CGPoint(x: 3000, y: 10)] {
            let rect = AskVision.closeUpRect(center: point, imagePixelSize: size,
                                             pointSize: CGSize(width: 900, height: 700), scale: 2)
            XCTAssertTrue(rect.insetBy(dx: -1, dy: -1).contains(point), "\(point) 落在了裁剪框外")
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxX, size.width)
            XCTAssertLessThanOrEqual(rect.maxY, size.height)
        }
    }

    // MARK: 请求体

    func testImagePartUsesSnakeCaseKeysAndADataURL() throws {
        let part = AskVision.imagePart(Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(part["type"] as? String, "image_url")
        let wrapper = try XCTUnwrap(part["image_url"] as? [String: Any])
        let url = try XCTUnwrap(wrapper["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertEqual(url, "data:image/jpeg;base64," + Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
        // 键名必须是 image_url，写成 imageUrl 上游直接 500
        XCTAssertNil(part["imageUrl"])
    }

    func testVisionUserContentPutsBothImagesBeforeTheQuestion() throws {
        let content = AskVision.visionUserContent(question: "这是什么",
                                                  overviewJPEG: Data([1]),
                                                  closeUpJPEG: Data([2]))
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["type"] as? String, "image_url")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        XCTAssertEqual(content[2]["type"] as? String, "text")
        XCTAssertEqual(content[2]["text"] as? String, "这是什么")
    }

    /// 整个 content 数组要能被 JSONSerialization 吃下去，不然运行时才炸
    func testVisionUserContentIsJSONSerializable() throws {
        let body: [String: Any] = [
            "model": "glm-5.3-flash",
            "messages": [["role": "user",
                          "content": AskVision.visionUserContent(question: "hi",
                                                                 overviewJPEG: Data([1, 2, 3]),
                                                                 closeUpJPEG: Data([4, 5, 6]))]],
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        let data = try JSONSerialization.data(withJSONObject: body)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"image_url\""))
        XCTAssertFalse(text.contains("imageUrl"))
    }

    // MARK: 关思考

    func testThinkingIsDisabledWhereItCanBe() {
        var qwen: [String: Any] = [:]
        AskVision.applyThinkingSettings(in: &qwen, provider: "qwen", model: "qwen3.8-flash")
        XCTAssertEqual(qwen["enable_thinking"] as? Bool, false)

        var doubao: [String: Any] = [:]
        AskVision.applyThinkingSettings(in: &doubao, provider: "doubao", model: "doubao-seed-2-1-turbo-260628")
        XCTAssertEqual((doubao["thinking"] as? [String: String])?["type"], "disabled")
    }

    /// 官方文档说 GLM-5.3 系列关不掉思考，但 Coding Plan 端点实测 disabled 生效（2026-09-21），照发
    func testZhipuAlwaysDisablesThinking() {
        for model in ["glm-5.3-flash", "glm-4.5-air"] {
            var body: [String: Any] = [:]
            AskVision.applyThinkingSettings(in: &body, provider: "zhipu", model: model)
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled", model)
            XCTAssertNil(body["reasoning_effort"], model)
        }
    }

    func testForcesThinkingCoversTheAutoRoutedNames() {
        // Coding Plan 端点会把 GLM-5.2 / 5.1 / 5-Turbo / 4.7 自动路由到 5.3 系列
        for model in ["glm-5.3-flash", "GLM-5.3-FlashX", "glm-5.2", "glm-5-turbo", "glm-4.7-flash"] {
            XCTAssertTrue(AskVision.forcesThinking(model: model), model)
        }
        for model in ["glm-4.6v", "glm-4.5-air", "qwen3.8-flash"] {
            XCTAssertFalse(AskVision.forcesThinking(model: model), model)
        }
    }

    /// 思考关不掉的模型，输出上限要留出思考的份额，不然在思考阶段就被截断
    func testMaxTokensLeavesRoomForForcedThinking() {
        XCTAssertGreaterThan(AskVision.maxTokens(provider: "zhipu"), AskVision.maxTokens(provider: "qwen"))
        XCTAssertEqual(AskVision.maxTokens(provider: "qwen"), 600)
    }

    // MARK: 模型与端点

    func testZhipuGoesThroughTheCodingPlanEndpoint() {
        XCTAssertEqual(AskVision.visionEndpoint(provider: "zhipu")?.absoluteString,
                       "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions")
        XCTAssertEqual(ZhipuEndpoint.defaultModel, "glm-5.3-flash")
    }

    func testCandidatesNeverEmptyAndOverrideWins() {
        for provider in ["qwen", "zhipu", "doubao", "unknown"] {
            XCTAssertFalse(AskVision.visionCandidates(provider: provider).isEmpty)
        }
        XCTAssertEqual(AskVision.visionCandidates(provider: "qwen", override: "my-model"), ["my-model"])
        XCTAssertEqual(AskVision.visionModel(provider: "zhipu"), "glm-5.3-flash")
    }

    func testSizeSummaryOnlyReportsNumbers() {
        let summary = AskVision.sizeSummary(overviewJPEG: Data(count: 51_200), closeUpJPEG: Data(count: 153_600))
        XCTAssertEqual(summary, "overview=50KB closeup=150KB")
    }

    // MARK: - 联网路由（模型自己判断）

    func testSearchToolIsOfferedOnlyWhenItCanBeUsed() {
        XCTAssertTrue(AskSearch.shouldOfferTool(provider: "deepseek", hasQwenKey: true))
        XCTAssertTrue(AskSearch.shouldOfferTool(provider: "zhipu", hasQwenKey: true))
        // 没有千问 Key：带了工具也没处转
        XCTAssertFalse(AskSearch.shouldOfferTool(provider: "deepseek", hasQwenKey: false))
        // 千问自己就能搜；豆包没验证过认不认 tools；托管通道服务器自己开了联网
        XCTAssertFalse(AskSearch.shouldOfferTool(provider: "qwen", hasQwenKey: true))
        XCTAssertFalse(AskSearch.shouldOfferTool(provider: "doubao", hasQwenKey: true))
        XCTAssertFalse(AskSearch.shouldOfferTool(provider: nil, hasQwenKey: true))
    }

    func testSearchToolDefinitionIsAValidFunctionTool() throws {
        let tools = AskSearch.tools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")   // DeepSeek 对 type=web_search 直接 422
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, AskSearch.toolName)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: tools))
    }

    func testExplicitSearchPrefix() {
        XCTAssertTrue(AskSearch.hasExplicitSearchPrefix("搜一下海德堡明天的天气"))
        XCTAssertTrue(AskSearch.hasExplicitSearchPrefix("  联网查查英伟达市值"))
        XCTAssertFalse(AskSearch.hasExplicitSearchPrefix("这道题选哪个"))
        XCTAssertFalse(AskSearch.hasExplicitSearchPrefix("帮我解释一下联网是什么意思"))
    }

    /// 工具名和参数都可能分片到达
    func testToolCallAccumulatorJoinsFragments() {
        var acc = ToolCallAccumulator()
        XCTAssertFalse(acc.ingest(delta: ["tool_calls": [["index": 0, "function": ["name": "web_"]]]], lookingFor: "web_search"))
        XCTAssertTrue(acc.ingest(delta: ["tool_calls": [["index": 0, "function": ["name": "search", "arguments": "{\"qu"]]]], lookingFor: "web_search"))
        _ = acc.ingest(delta: ["tool_calls": [["index": 0, "function": ["arguments": "ery\": \"x\"}"]]]], lookingFor: "web_search")
        XCTAssertEqual(acc.argumentsJSON(at: 0), "{\"query\": \"x\"}")
    }

    /// 普通出字的块、别的工具名都不算
    func testToolCallAccumulatorIgnoresContentAndOtherTools() {
        var acc = ToolCallAccumulator()
        XCTAssertFalse(acc.ingest(delta: ["content": "你好"], lookingFor: "web_search"))
        XCTAssertFalse(acc.ingest(delta: ["tool_calls": [["index": 0, "function": ["name": "other_tool"]]]], lookingFor: "web_search"))
        // 同一块里既有 content 又有工具调用；并排第二个调用才是要找的
        XCTAssertTrue(acc.ingest(delta: ["content": "我查一下", "tool_calls": [["index": 1, "function": ["name": "web_search"]]]], lookingFor: "web_search"))
    }

    func testDeepSeekIsAProviderWithThinkingDisabledAndASecretKey() {
        var body: [String: Any] = [:]
        AskVision.applyThinkingSettings(in: &body, provider: "deepseek", model: DeepSeekEndpoint.defaultModel)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")   // 默认开着思考，GetNewWord 因此慢到过 31 秒
        XCTAssertEqual(AskVision.visionCandidates(provider: "deepseek", override: nil), ["deepseek-flash"])
        XCTAssertEqual(AskVision.visionEndpoint(provider: "deepseek")?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertTrue(VoicePolishConfig.secretKeys.contains("deepseek_api_key"))
    }

    /// 搜索词是模型看完屏幕后写的，转千问时靠它带上屏幕上下文（那一问不带图）
    func testSearchQueryIsExtractedAndAttachedToTheQuestion() {
        var acc = ToolCallAccumulator()
        _ = acc.ingest(delta: ["tool_calls": [["index": 0, "function": ["name": "web_search", "arguments": "{\"query\": \"RTX 5090"]]]], lookingFor: "web_search")
        XCTAssertNil(acc.searchQuery(for: "web_search"), "参数还没吐完，不是合法 JSON")
        _ = acc.ingest(delta: ["tool_calls": [["index": 0, "function": ["arguments": " 价格\"}"]]]], lookingFor: "web_search")
        XCTAssertEqual(acc.searchQuery(for: "web_search"), "RTX 5090 价格")

        XCTAssertEqual(AskSearch.searchQuestion("这个多少钱", query: nil), "这个多少钱")
        XCTAssertTrue(AskSearch.searchQuestion("这个多少钱", query: "RTX 5090 价格").contains("RTX 5090 价格"))
        XCTAssertTrue(AskSearch.searchQuestion("这个多少钱", query: "RTX 5090 价格").hasPrefix("这个多少钱"))
    }
}
