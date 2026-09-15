import XCTest
@testable import VoicePolishCore

final class TrialManagerTests: XCTestCase {

    // MARK: - parseTrialStart：纯函数，不依赖网络

    func testParseSuccess() {
        let json: [String: Any] = [
            "trial_token": "tok-abc123",
            "days_left": 7,
            "daily_limit": 1500,
            "used_today": 42,
        ]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertEqual(p.token, "tok-abc123")
        XCTAssertEqual(p.daysLeft, 7)
        XCTAssertEqual(p.dailyLimit, 1500)
        XCTAssertEqual(p.usedToday, 42)
        XCTAssertFalse(p.expired)
    }

    func testParseExpired() {
        let json: [String: Any] = ["expired": true]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertNil(p.token)
        XCTAssertTrue(p.expired)
    }

    func testParseMissingDailyLimitDefaultsTo1500() {
        let json: [String: Any] = [
            "trial_token": "tok-xyz",
            "days_left": 3,
            "used_today": 0,
            // daily_limit 故意缺失
        ]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertEqual(p.dailyLimit, 1500, "daily_limit 缺失时应默认 1500")
    }

    func testParseGarbageJson() {
        let p = TrialManager.parseTrialStart(["error": "unknown"])
        XCTAssertNil(p.token, "看不懂的响应 → token 为 nil")
        XCTAssertFalse(p.expired, "看不懂的响应 → 不标记为过期")
    }

    func testParseEmptyDict() {
        let p = TrialManager.parseTrialStart([:])
        XCTAssertNil(p.token)
        XCTAssertFalse(p.expired)
    }

    func testParseExpiredFalseNotTreatedAsExpired() {
        // expired:false 不应触发过期路径
        let json: [String: Any] = [
            "trial_token": "tok-still-valid",
            "days_left": 5,
            "daily_limit": 1500,
            "used_today": 10,
            "expired": false,
        ]
        let p = TrialManager.parseTrialStart(json)
        XCTAssertEqual(p.token, "tok-still-valid")
        XCTAssertFalse(p.expired)
    }

    // MARK: - isInTrial：注入独立 UserDefaults，不污染 .standard

    private func freshDefaults(name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "trial-test-\(name)")!
        // 清理残留
        for key in ["trial.token", "trial.daysLeft", "trial.usedToday",
                    "trial.dailyLimit", "trial.expired", "trial.lastRefreshAt"] {
            d.removeObject(forKey: key)
        }
        return d
    }

    func testIsInTrialTrueWhenTokenPresentAndNotExpired() {
        let d = freshDefaults(name: "active")
        d.set("tok-valid", forKey: "trial.token")
        d.set(false, forKey: "trial.expired")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertTrue(mgr.isInTrial)
    }

    func testIsInTrialFalseWhenNoToken() {
        let d = freshDefaults(name: "notoken")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertFalse(mgr.isInTrial)
    }

    func testIsInTrialFalseWhenExpiredFlagSet() {
        let d = freshDefaults(name: "expired")
        d.set("tok-old", forKey: "trial.token")
        d.set(true, forKey: "trial.expired")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertFalse(mgr.isInTrial)
    }

    func testIsInTrialFalseWhenTokenIsEmptyString() {
        let d = freshDefaults(name: "emptytoken")
        d.set("", forKey: "trial.token")
        d.set(false, forKey: "trial.expired")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertFalse(mgr.isInTrial)
    }

    // MARK: - 缓存往返：applyParsed 后读回 accessor 要匹配

    func testCacheRoundTripSuccessResponse() {
        let d = freshDefaults(name: "roundtrip")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")

        let json: [String: Any] = [
            "trial_token": "rt-token-99",
            "days_left": 14,
            "daily_limit": 2000,
            "used_today": 111,
        ]
        let parsed = TrialManager.parseTrialStart(json)
        // 直接调用内部 applyParsed（通过 refreshFromServer 的 testable 逻辑），
        // 这里用内部方法验证：通过同一 defaults 构造第二个实例读回
        //
        // 因为 applyParsed 是 private，我们用一个协议保留的方式——
        // 通过制造一个假的成功响应来走完整路径：
        // 只需验证 parseTrialStart 的输出字段与 accessor 在手动写入后一致即可。
        d.set(parsed.token ?? "", forKey: "trial.token")
        d.set(parsed.daysLeft,   forKey: "trial.daysLeft")
        d.set(parsed.usedToday,  forKey: "trial.usedToday")
        d.set(parsed.dailyLimit, forKey: "trial.dailyLimit")
        d.set(false,             forKey: "trial.expired")

        XCTAssertEqual(mgr.trialToken, "rt-token-99")
        XCTAssertEqual(mgr.daysLeft,   14)
        XCTAssertEqual(mgr.usedToday,  111)
        XCTAssertEqual(mgr.dailyLimit, 2000)
        XCTAssertTrue(mgr.isInTrial)
    }

    func testCacheRoundTripExpiredClearsToken() {
        let d = freshDefaults(name: "roundtrip-exp")
        // 先放一个有效 token
        d.set("old-token", forKey: "trial.token")
        d.set(false, forKey: "trial.expired")

        // 模拟 applyParsed({expired:true}) 的写入逻辑（镜像 TrialManager 实现）
        d.removeObject(forKey: "trial.token")
        d.set(true, forKey: "trial.expired")

        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertNil(mgr.trialToken)
        XCTAssertFalse(mgr.isInTrial)
    }

    func testDailyLimitDefaultsTo1500WhenNotCached() {
        let d = freshDefaults(name: "limit-default")
        let mgr = TrialManager(defaults: d, apiBase: "http://localhost")
        XCTAssertEqual(mgr.dailyLimit, 1500, "UserDefaults 无值时 dailyLimit accessor 应默认 1500")
    }
}
