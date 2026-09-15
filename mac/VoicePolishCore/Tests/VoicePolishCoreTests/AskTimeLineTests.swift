import XCTest
@testable import VoicePolishCore

final class AskTimeLineTests: XCTestCase {
    private func date(_ tz: String, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testBeijingTime() {
        let now = date("Asia/Shanghai", 2026, 9, 11, 11, 45)
        XCTAssertEqual(AIPolisher.askTimeLine(now: now, timeZone: TimeZone(identifier: "Asia/Shanghai")!),
                       "当前时间：2026年9月11日 星期五 11:45（北京时间）。")
    }

    func testMidnightPadsAndWeekday() {
        let now = date("Asia/Shanghai", 2026, 9, 13, 0, 5)
        XCTAssertEqual(AIPolisher.askTimeLine(now: now, timeZone: TimeZone(identifier: "Asia/Shanghai")!),
                       "当前时间：2026年9月13日 星期日 00:05（北京时间）。")
    }

    func testOtherTimeZonesUseUTCOffset() {
        let now = date("Asia/Shanghai", 2026, 9, 11, 11, 45)
        XCTAssertEqual(AIPolisher.askTimeLine(now: now, timeZone: TimeZone(identifier: "America/New_York")!),
                       "当前时间：2026年9月10日 星期四 23:45（UTC-4）。")
        XCTAssertEqual(AIPolisher.askTimeLine(now: now, timeZone: TimeZone(identifier: "Asia/Kolkata")!),
                       "当前时间：2026年9月11日 星期五 09:15（UTC+5:30）。")
    }
}
