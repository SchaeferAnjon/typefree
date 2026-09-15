import XCTest
@testable import VoicePolishCore

final class ActivityRhythmTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        return f.date(from: s)!
    }
    private func rec(_ d: String, _ chars: Int) -> DailyRecord { DailyRecord(date: d, charCount: chars, sessionCount: max(1, chars / 50)) }

    func testFillsMissingDaysWithZeroAndMarksToday() {
        let r = ActivityRhythm.compute(records: [rec("2026-09-15", 300), rec("2026-09-13", 100)],
                                       today: date("2026-09-15"), days: 4, calendar: cal)
        XCTAssertEqual(r.days.map(\.date), ["2026-09-12", "2026-09-13", "2026-09-14", "2026-09-15"])
        XCTAssertEqual(r.days.map(\.chars), [0, 100, 0, 300])
        XCTAssertTrue(r.days.last!.isToday)
        XCTAssertEqual(r.days.last!.weekday, 3, "2026-09-15 是周二")
    }

    func testStreaksCountFromTodayOrYesterday() {
        let used = ["2026-09-10", "2026-09-11", "2026-09-12", "2026-09-14", "2026-09-15"].map { rec($0, 200) }
        let r = ActivityRhythm.compute(records: used, today: date("2026-09-15"), calendar: cal)
        XCTAssertEqual(r.currentStreak, 2, "14、15 连续两天")
        XCTAssertEqual(r.bestStreak, 3, "10-12 三天")
        XCTAssertEqual(r.activeDays, 5)

        let notYetToday = ActivityRhythm.compute(records: Array(used.dropLast()), today: date("2026-09-15"), calendar: cal)
        XCTAssertEqual(notYetToday.currentStreak, 1, "今天还没用，从昨天往前数，不算断")
    }

    func testBusiestWeekdayOverLastEightWeeks() {
        // 每个周三 1000 字，其他日子 100 字
        var records: [DailyRecord] = []
        for offset in 0..<56 {
            let d = cal.date(byAdding: .day, value: -offset, to: date("2026-09-15"))!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
            records.append(rec(f.string(from: d), cal.component(.weekday, from: d) == 4 ? 1000 : 100))
        }
        let r = ActivityRhythm.compute(records: records, today: date("2026-09-15"), calendar: cal)
        XCTAssertEqual(r.busiestWeekday, 4)
        XCTAssertEqual(ActivityRhythm.weekdayNames[4], "周三")
        XCTAssertNil(ActivityRhythm.compute(records: [], today: date("2026-09-15"), calendar: cal).busiestWeekday)
    }
}
