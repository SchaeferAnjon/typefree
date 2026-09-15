import XCTest
@testable import VoicePolishCore

final class LicenseManagerTests: XCTestCase {
    // 跨语言测试向量（与 license-worker/test/sign.test.mjs 同源），
    // 证明 Worker（@noble/ed25519）签出的 token 在 CryptoKit 这端验得过。
    let testPub = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
    let testMsg = "TF-TEST2-TEST3-TEST4-TEST5:device-hash-abc123"
    let testSig = "tQJNE79gWEcEZm0adDtNGBlCy7Z/rlc3AOD4fEUikc0W0h0CqNdDaNg5MamxR7ax/WTJVnhmXojxGLU+h2VVCA=="

    func testLicenseMessageFormat() {
        XCTAssertEqual(LicenseManager.licenseMessage(code: "A", deviceID: "B"), "A:B")
    }

    func testVerifyCrossLanguageVector() {
        XCTAssertTrue(LicenseManager.verify(message: testMsg, tokenBase64: testSig, publicKeyBase64: testPub))
    }

    func testVerifyRejectsTamperedSignature() {
        let bad = testSig.replacingOccurrences(of: "t", with: "u")
        XCTAssertFalse(LicenseManager.verify(message: testMsg, tokenBase64: bad, publicKeyBase64: testPub))
        XCTAssertFalse(LicenseManager.verify(message: testMsg + "x", tokenBase64: testSig, publicKeyBase64: testPub))
    }

    func testDeviceIDStableAndNonEmpty() {
        let m = LicenseManager(defaults: UserDefaults(suiteName: "lm-test")!)
        XCTAssertFalse(m.deviceID().isEmpty)
        XCTAssertEqual(m.deviceID(), m.deviceID())
    }

    func testNotActivatedWithGarbageToken() {
        let d = UserDefaults(suiteName: "lm-test2")!
        d.set("TF-X", forKey: "license.key")
        d.set("not-a-sig", forKey: "license.token")
        XCTAssertFalse(LicenseManager(defaults: d).isActivated)
    }

    // MARK: - 联网复核（决策逻辑为纯函数，网络部分由 worker 集成测试覆盖）

    func testRevalidationDueIntervals() {
        let t0: TimeInterval = 1_780_000_000   // 任意基准时刻
        let interval = LicenseManager.revalidationInterval
        XCTAssertTrue(LicenseManager.isRevalidationDue(lastValidatedAt: 0, now: t0),
                      "从未复核过（缺省 0）→ 立即复核")
        XCTAssertFalse(LicenseManager.isRevalidationDue(lastValidatedAt: t0, now: t0 + interval - 1))
        XCTAssertTrue(LicenseManager.isRevalidationDue(lastValidatedAt: t0, now: t0 + interval))
    }

    // MARK: - 会员（2026-09）

    /// 造一个 payload 正确、签名随便的会员令牌（App 端只读 exp，不验签）。
    private func fakeMemberToken(exp: Int) -> String {
        let payload = Data("TF-X|dev|\(exp)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return payload + ".c2ln"
    }

    func testMemberTokenExpiryDecode() {
        XCTAssertEqual(LicenseManager.memberTokenExpiry(fakeMemberToken(exp: 1_800_000_000)), 1_800_000_000)
        XCTAssertNil(LicenseManager.memberTokenExpiry("garbage"))
        XCTAssertNil(LicenseManager.memberTokenExpiry("abc.def"))
        XCTAssertNil(LicenseManager.memberTokenExpiry(Data("a|b".utf8).base64EncodedString() + ".x"), "payload 段数不对")
    }

    func testMembershipParseOldServerAndMember() {
        let old = LicenseManager.MembershipInfo.parse(["valid": true])
        XCTAssertEqual(old.plan, "sponsor")
        XCTAssertFalse(old.genesis); XCTAssertFalse(old.expired); XCTAssertNil(old.memberToken); XCTAssertNil(old.expiresDay)
        let m = LicenseManager.MembershipInfo.parse(["plan": "member", "genesis": true, "expires_at": "2027-09-14 00:00:00",
                                                     "expires_day": "2027-09-14", "expired": false, "member_token": "t"])
        XCTAssertEqual(m.plan, "member"); XCTAssertTrue(m.genesis)
        XCTAssertEqual(m.expiresAt, "2027-09-14 00:00:00"); XCTAssertEqual(m.expiresDay, "2027-09-14"); XCTAssertEqual(m.memberToken, "t")
        XCTAssertNil(LicenseManager.MembershipInfo.parse(["plan": "member", "member_token": ""]).memberToken, "空令牌当没有")
    }

    func testMembershipParseAutoRenew() {
        XCTAssertFalse(LicenseManager.MembershipInfo.parse(["plan": "member"]).autoRenew)
        XCTAssertTrue(LicenseManager.MembershipInfo.parse(["plan": "member", "auto_renew": true]).autoRenew)
    }

    func testParseUTC() {
        XCTAssertEqual(LicenseManager.parseUTC("2027-01-01 00:00:00"), 1_798_761_600)
        XCTAssertNil(LicenseManager.parseUTC("2027-01-01T00:00:00Z"))
    }

    func testRevalidationDueForMembers() {
        let now: TimeInterval = 1_780_000_000
        XCTAssertTrue(LicenseManager.isRevalidationDue(lastValidatedAt: now, now: now, isMember: true, memberTokenExpiry: nil),
                      "会员手里没令牌 → 立刻复核")
        XCTAssertTrue(LicenseManager.isRevalidationDue(lastValidatedAt: now, now: now, isMember: true, memberTokenExpiry: now + 3600),
                      "令牌 24 小时内到期 → 复核换新")
        XCTAssertFalse(LicenseManager.isRevalidationDue(lastValidatedAt: now, now: now, isMember: true, memberTokenExpiry: now + 5 * 86400))
        XCTAssertFalse(LicenseManager.isRevalidationDue(lastValidatedAt: now, now: now, isMember: false, memberTokenExpiry: nil),
                       "非会员照旧按 3 天间隔")
    }

    func testNotActivatedMeansNoMembership() {
        let d = UserDefaults(suiteName: "lm-test-member")!
        d.set("member", forKey: "license.plan")
        d.set(true, forKey: "license.genesis")
        d.set(fakeMemberToken(exp: 9_999_999_999), forKey: "license.memberToken")
        let m = LicenseManager(defaults: d)
        XCTAssertFalse(m.isMember); XCTAssertFalse(m.isGenesis); XCTAssertNil(m.memberToken()); XCTAssertFalse(m.hasActiveMembership(),
                       "没通过激活验签，本地字段再怎么写也不算会员")
    }

    func testRevalidationVerdictOnlyExplicitAnswerCounts() {
        XCTAssertEqual(LicenseManager.revalidationVerdict(["valid": true]), true)
        XCTAssertEqual(LicenseManager.revalidationVerdict(["valid": false]), false)
        XCTAssertNil(LicenseManager.revalidationVerdict([:]), "看不懂的返回 → 不动作")
        XCTAssertNil(LicenseManager.revalidationVerdict(["error": "x"]))
    }

    func testAppVersionChangeForcesRevalidation() {
        XCTAssertTrue(LicenseManager.appVersionChanged(stored: nil, current: "3.0.0"), "老版本升上来没存过版本号，也要立刻复核")
        XCTAssertTrue(LicenseManager.appVersionChanged(stored: "2.8.1", current: "3.0.0"))
        XCTAssertFalse(LicenseManager.appVersionChanged(stored: "3.0.0", current: "3.0.0"))
        XCTAssertFalse(LicenseManager.appVersionChanged(stored: nil, current: ""), "读不到版本号就别乱清")
    }
}
