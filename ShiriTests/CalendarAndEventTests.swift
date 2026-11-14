import XCTest
@testable import ShiriCore

final class CalendarAndEventTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testMonthlyLastDayAndSkipHaveDifferentExplicitResults() throws {
        var card = Card(title: "月末付款", now: date(2026,1,1))
        var schedule = ScheduleDefinition(start: CivilDate(year: 2026, month: 1, day: 31), time: DayTime(hour: 9), frequency: .monthly, timeZone: calendar.timeZone)
        XCTAssertThrowsError(try schedule.validate())
        schedule.missingDatePolicy = .lastValidDay; card.schedule = schedule
        let interval = DateInterval(start: date(2026,1,1), end: date(2026,4,1))
        let engine = OccurrenceEngine(calendar: calendar)
        XCTAssertEqual(engine.occurrences(for: card, in: interval).compactMap(\.plannedAt), [date(2026,1,31,9),date(2026,2,28,9),date(2026,3,31,9)])
        card.schedule?.missingDatePolicy = .skip
        XCTAssertEqual(engine.occurrences(for: card, in: interval).compactMap(\.plannedAt), [date(2026,1,31,9),date(2026,3,31,9)])
    }

    func testWeeklySeveralWeekdaysAndStableOccurrenceIDs() {
        var card = Card(title: "背单词", now: date(2026,9,7))
        var schedule = ScheduleDefinition(start: CivilDate(year: 2026, month: 9, day: 7), time: DayTime(hour: 20), frequency: .weekly, timeZone: calendar.timeZone)
        schedule.weekdays = [2,4,6]; card.schedule = schedule
        let engine = OccurrenceEngine(calendar: calendar)
        let first = engine.occurrences(for: card, in: DateInterval(start: date(2026,9,7), end: date(2026,9,14)))
        XCTAssertEqual(first.compactMap(\.plannedAt), [date(2026,9,7,20),date(2026,9,9,20),date(2026,9,11,20)])
        XCTAssertEqual(first[1].id, engine.occurrences(for: card, in: DateInterval(start: date(2026,9,8), end: date(2026,9,10))).first?.id)
    }

    func testDSTGapUsesCalendarInsteadOfAdding86400Seconds() {
        var losAngeles = calendar; losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let engine = OccurrenceEngine(calendar: losAngeles)
        let result = engine.date(CivilDate(year: 2026, month: 3, day: 8), time: DayTime(hour: 2, minute: 30))!
        let components = losAngeles.dateComponents([.hour,.minute], from: result)
        XCTAssertEqual(components.hour, 3); XCTAssertEqual(components.minute, 30)
    }

    func testLunarBirthdayUsesChineseCalendarAndRequiresPolicy() throws {
        var birthday = BirthdayRule(name: "妈妈", calendar: .lunar, month: 8, day: 15)
        birthday.dayTime = DayTime(hour: 9)
        let engine = BirthdayCalendarEngine(calendar: calendar)
        let dates = engine.nextDates(for: birthday, after: date(2026,1,1), limit: 3)
        XCTAssertEqual(dates.count, 3)
        var lunar = Calendar(identifier: .chinese); lunar.timeZone = calendar.timeZone
        for value in dates {
            let components = lunar.dateComponents(in: lunar.timeZone, from: value)
            XCTAssertEqual(components.month, 8); XCTAssertEqual(components.day, 15); XCTAssertNotEqual(components.isLeapMonth, true)
        }
        birthday.isLeapMonth = true
        XCTAssertThrowsError(try birthday.validate())
        birthday.leapMonthPolicy = .regularWhenMissing
        XCTAssertNoThrow(try birthday.validate())
    }

    func testGregorianLeapBirthdayWithoutYearAndNoCompletion() throws {
        var birthday = BirthdayRule(name: "朋友", calendar: .gregorian, month: 2, day: 29)
        XCTAssertThrowsError(try birthday.validate())
        birthday.missingDatePolicy = .lastValidDay; birthday.dayTime = DayTime(hour: 10)
        let dates = BirthdayCalendarEngine(calendar: calendar).nextDates(for: birthday, after: date(2026,1,1), limit: 3)
        XCTAssertEqual(dates, [date(2026,2,28,10),date(2027,2,28,10),date(2028,2,29,10)])
        var card = Card(title: "朋友的生日", kind: .note, now: date(2026,1,1)); card.birthday = birthday
        XCTAssertFalse(card.canComplete)
    }

    func testConcurrentCompletionSurvivesUndoThatDidNotObserveIt() {
        let card = Card(title: "完成一件事", now: date(2026,9,11))
        let occurrence = Occurrence(card: card, semanticKey: "undated", plannedAt: nil)
        let a = TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "A", kind: .completed, now: date(2026,9,11,10))
        let b = TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "B", kind: .completed, now: date(2026,9,11,9))
        let undoA = TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "A", kind: .reopened, now: date(2026,9,11,11), reverses: [a.id])
        XCTAssertEqual(EventReducer.state(events: [undoA,b,a,a]), .completed)
        XCTAssertEqual(EventReducer.effectiveCompletions([undoA,b,a,a]).map(\.id), [b.id])
        let undoBoth = TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "A", kind: .reopened, now: date(2026,9,11,12), reverses: [a.id,b.id])
        XCTAssertEqual(EventReducer.state(events: [undoBoth,a,undoA,b]), .pending)
    }

    func testUndatedTaskNeverMovesItsIdentityWithClockAndNoteIsNotTask() {
        let card = Card(title: "以后学 SwiftUI", now: date(2026,9,11))
        let engine = OccurrenceEngine(calendar: calendar)
        let a = engine.next(for: card, after: date(2026,9,11))
        let b = engine.next(for: card, after: date(2027,9,11))
        XCTAssertEqual(a?.id,b?.id); XCTAssertNil(a?.plannedAt)
        let note = Card(title: "停车位 B2", kind: .note, now: date(2026,9,11))
        XCTAssertNil(engine.next(for: note, after: date(2026,9,11)))
    }

    func testUserAppearanceOverridesSurviveTextChanges() {
        var appearance = CardAppearance.recommended(for: "取快递", kind: .task)
        appearance.theme = .mist; appearance.overriddenFields.insert("theme")
        appearance.applyRecommendation(.recommended(for: "去花店", kind: .task))
        XCTAssertEqual(appearance.theme, .mist); XCTAssertEqual(appearance.illustration, .ginkgo)
    }
}
