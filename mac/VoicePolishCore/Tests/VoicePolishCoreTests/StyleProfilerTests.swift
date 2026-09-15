import XCTest
@testable import VoicePolishCore

final class StyleProfilerTests: XCTestCase {

    // MARK: - 场景分类

    func testSceneClassification() {
        XCTAssertEqual(SceneCategory.classify(appName: "微信"), .chat)
        XCTAssertEqual(SceneCategory.classify(appName: "WeChat"), .chat)
        XCTAssertEqual(SceneCategory.classify(appName: "企业微信"), .chat)
        XCTAssertEqual(SceneCategory.classify(appName: "Cursor"), .coding)
        XCTAssertEqual(SceneCategory.classify(appName: "iTerm2"), .coding)
        XCTAssertEqual(SceneCategory.classify(appName: "Pages"), .writing)
        XCTAssertEqual(SceneCategory.classify(appName: "备忘录"), .writing)
        XCTAssertEqual(SceneCategory.classify(appName: "豆包"), .ai)
        XCTAssertEqual(SceneCategory.classify(appName: "ChatGPT"), .ai)
        XCTAssertEqual(SceneCategory.classify(appName: "Google Chrome"), .other)
        XCTAssertEqual(SceneCategory.classify(appName: nil), .other)
        XCTAssertEqual(SceneCategory.classify(appName: "键盘"), .other)
    }

    // MARK: - 全局层（人身特征）

    func testGlobalNilWhenTooFewRecords() {
        let outputs = Array(repeating: "这是一条正常长度的历史成稿内容。", count: 9)
        XCTAssertNil(StyleProfiler.globalPromptSection(fromOutputs: outputs))
    }

    func testGlobalDetectsMixedLanguageHabit() {
        let outputs = Array(repeating: "帮我看一下 Kubernetes deployment 的 rolling update 策略，顺便检查 ingress controller 配置。", count: 12)
        let section = StyleProfiler.globalPromptSection(fromOutputs: outputs)
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("绝不翻译"))
        XCTAssertTrue(section!.hasPrefix("## 该用户的表达习惯"))
    }

    func testGlobalDetectsShortSentenceHabit() {
        let outputs = Array(repeating: "先发我。改一下。明天再说。这样就行。", count: 12)
        let section = StyleProfiler.globalPromptSection(fromOutputs: outputs)
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("简短"))
    }

    func testGlobalNeverContainsSceneTraits() {
        // 列表/敬语是场合特征，绝不该混进全局层
        let listy = "今天的安排：\n1. 上午开会\n2. 下午写方案\n3. 晚上健身，麻烦您确认"
        let outputs = Array(repeating: listy, count: 12)
        if let section = StyleProfiler.globalPromptSection(fromOutputs: outputs) {
            XCTAssertFalse(section.contains("列表"))
            XCTAssertFalse(section.contains("您"))
        }
    }

    func testGlobalNeutralTextsProduceNoProfile() {
        let neutral = "今天下午和同事讨论了项目里的几个安排，大家把接下来要做的事情都对齐了。"
        let outputs = Array(repeating: neutral, count: 12)
        XCTAssertNil(StyleProfiler.globalPromptSection(fromOutputs: outputs))
    }

    // MARK: - 场景层（场合特征）

    func testSceneListHabitRequiresSpokenEnumeration() {
        let listyOutput = "明天的安排：\n1. 上午开会\n2. 下午写方案"

        // 原话真的在并列着说（第一…第二…）→ 学
        let spoken = Array(repeating: StyleProfiler.Sample(
            output: listyOutput,
            asr: "明天的安排第一上午开会第二下午写方案"
        ), count: 12)
        let section = StyleProfiler.scenePromptSection(scene: .writing, samples: spoken)
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("列表"))
        XCTAssertTrue(section!.contains("文档写作"))

        // 成稿有列表但原话没有并列口癖（模型自作主张排的）→ 不学
        let unspoken = Array(repeating: StyleProfiler.Sample(
            output: listyOutput,
            asr: "明天上午开会下午写方案"
        ), count: 12)
        XCTAssertNil(StyleProfiler.scenePromptSection(scene: .writing, samples: unspoken))
    }

    func testSceneHonorificDetection() {
        let samples = Array(repeating: StyleProfiler.Sample(
            output: "您好，合同已经发到您的邮箱，麻烦您查收一下。",
            asr: "您好合同已经发到您的邮箱麻烦您查收一下"
        ), count: 12)
        let section = StyleProfiler.scenePromptSection(scene: .chat, samples: samples)
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("您"))
        XCTAssertTrue(section!.contains("聊天对话"))
    }

    func testSpokenEnumerationNeedsTwoDistinctMarkers() {
        XCTAssertTrue(StyleProfiler.spokenEnumeration(in: "第一要这样第二要那样"))
        XCTAssertTrue(StyleProfiler.spokenEnumeration(in: "首先把代码合了其次把版本发了"))
        XCTAssertFalse(StyleProfiler.spokenEnumeration(in: "还有一个问题想问"))
        XCTAssertFalse(StyleProfiler.spokenEnumeration(in: "先这样吧明天再说"))
    }

    func testSentenceSegmentsAndListDetection() {
        XCTAssertEqual(StyleProfiler.sentenceSegments(in: "你好。今天天气不错！走吗？"), ["你好", "今天天气不错", "走吗"])
        XCTAssertTrue(StyleProfiler.containsListLine("清单：\n1. 第一件事"))
        XCTAssertTrue(StyleProfiler.containsListLine("- 一个点"))
        XCTAssertFalse(StyleProfiler.containsListLine("2026年的计划还没写"))
    }

    // MARK: - 画像存取与按场景组装

    func testStoreRoundTripAndSceneAssembly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("style-profile-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("style_profile.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(StyleProfileStore.load(from: url))
        XCTAssertNil(StyleProfileStore.promptSection(forAppName: "微信", from: url))

        let snapshot = StyleProfileSnapshot(
            globalSection: "## 全局\n- 人身习惯",
            sceneSections: [SceneCategory.chat.rawValue: "## 聊天\n- 场合习惯"],
            recordCount: 42,
            computedAt: Date()
        )
        StyleProfileStore.save(snapshot, to: url)
        XCTAssertEqual(StyleProfileStore.load(from: url), snapshot)

        // 聊天 App：全局 + 聊天场景
        XCTAssertEqual(StyleProfileStore.promptSection(forAppName: "微信", from: url),
                       "## 全局\n- 人身习惯\n\n## 聊天\n- 场合习惯")
        // 没学过的场景：只有全局
        XCTAssertEqual(StyleProfileStore.promptSection(forAppName: "Cursor", from: url), "## 全局\n- 人身习惯")
        // other 场景（浏览器等大杂烩）：不注入场景层
        XCTAssertEqual(StyleProfileStore.promptSection(forAppName: "Google Chrome", from: url), "## 全局\n- 人身习惯")
        // 不带 App 信息（Omni 路径）：只有全局
        XCTAssertEqual(StyleProfileStore.promptSection(from: url), "## 全局\n- 人身习惯")

        StyleProfileStore.clear(at: url)
        XCTAssertNil(StyleProfileStore.load(from: url))
    }
}
