import XCTest
@testable import VoicePolishCore

final class HostedRouteTests: XCTestCase {
    private func route(ownKey: Bool = false, hosted: Bool = true, activated: Bool = false,
                       member: Bool = false, trial: Bool = false, memberFirst: Bool = false) -> HostedRoute {
        HostedRoute.decide(ownKeyConfigured: ownKey, hostedAvailable: hosted, isActivated: activated,
                           hasActiveMembership: member, isInTrial: trial, memberFirst: memberFirst)
    }

    func testOwnKeyWinsUnlessMemberFirst() {
        XCTAssertEqual(route(ownKey: true, activated: true, member: true, trial: true), .none, "默认（创世）自己的 Key 优先")
        XCTAssertEqual(route(ownKey: true, trial: true), .none, "试用期间填了 Key 就用 Key")
    }

    func testMemberFirstOverridesOwnKey() {
        XCTAssertEqual(route(ownKey: true, activated: true, member: true, memberFirst: true), .member)
        XCTAssertEqual(route(ownKey: true, activated: true, member: false, memberFirst: true), .none, "会员到期回落到自己的 Key")
        XCTAssertEqual(route(ownKey: true, hosted: false, activated: true, member: true, memberFirst: true), .none, "自编译版没有会员通道")
    }

    func testSelfCompiledBuildHasNoHostedChannel() {
        XCTAssertEqual(route(hosted: false, activated: true, member: true), .none)
        XCTAssertEqual(route(hosted: false, trial: true), .none)
    }

    func testActiveMemberUsesMemberChannel() {
        XCTAssertEqual(route(activated: true, member: true), .member)
        XCTAssertEqual(route(activated: true, member: true, trial: true), .member, "会员优先于试用")
    }

    func testTrialOnlyForNotActivated() {
        XCTAssertEqual(route(trial: true), .trial)
        XCTAssertEqual(route(activated: true, trial: true), .none, "老买断/赠送码不走试用")
    }

    func testExpiredMemberOrNothingFallsToNone() {
        XCTAssertEqual(route(activated: true, member: false), .none)
        XCTAssertEqual(route(), .none)
    }
}
