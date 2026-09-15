import XCTest
@testable import VoicePolishCore

/// 用例取自 2026-09-11 owner 配置里真实攒下的纠错候选
final class MishearingCheckTests: XCTestCase {

    private func yes(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(MishearingCheck.isLikelyMishearing(old: old, new: new), "\(old)→\(new) 应算听错", file: file, line: line)
    }

    private func no(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(MishearingCheck.isLikelyMishearing(old: old, new: new), "\(old)→\(new) 不该学", file: file, line: line)
    }

    func testChineseHomophonesAndNearHomophonesAreMishearings() {
        yes("徐翔", "徐相")
        yes("姚小媛", "姚晓媛")
        yes("热磁", "热词")
        yes("玉米", "域名")      // mi ≈ ming（鼻音尾）
        yes("天成", "天辰")      // cheng ≈ chen
        yes("说五", "说无")
        yes("小度控制台", "小肚控制台")
    }

    func testContentEditsAreRejected() {
        no("周四", "周三")
        no("周四", "周日")
        no("明天", "后天")
        no("共5", "共4")        // 数字变了
        no("测试一下", "要求后续变更")
        no("我都等", "要求后续变更")
        no("版本上面", "分支")
        no("那些", "那先")
        no("的学", "的询")
    }

    func testMeaningfulHomophoneSwapsAreRejected() {
        no("，他", "，它")      // 去掉标点只剩一个字
        no("他们", "她们")
        no("跑的快", "跑得快")
    }

    func testLatinCorrectionsNeedCloseSpelling() {
        yes("OpenWrt", "OpenWiki")
        yes("Open wake.", "openwiki")
        yes("Cloud code", "Claude Code")
        yes("APIK", "APIKey")
        yes("扣的 X", "codex")    // 中英混合按拼音比
        no("PredictIt", "polymarket")
        no("Openness", "obsidian")
        no("Thank you.", "Th")
        no("高质量的 VPS", "畅所欲问")
        no("测试一下能不能用", "[name]")
    }

    func testCaseOrPunctuationOnlyChangesAreNotMishearings() {
        no("cloud", "Cloud")
        no("热词。", "热词")
    }
}
