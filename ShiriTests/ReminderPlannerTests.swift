import XCTest
@testable import ShiriCore

final class ReminderPlannerTests: XCTestCase {
    func testDailyConfirmationKeepsNominalTimeAcrossSpringDSTTransition() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0)))
        var card = Card(title: "夏令时提醒", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(year: 2026, month: 3, day: 8), time: DayTime(hour: 1, minute: 58), frequency: .daily)
        card.schedule?.timeZoneMode = .fixed; card.schedule?.timeZoneIdentifier = cal.timeZone.identifier
        card.reminders.isEnabled = true
        var library = LibrarySnapshot(); library.cards = [card]
        let plan = ReminderPlanner(calendar: cal).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: true))
        let check = try XCTUnwrap(plan.requests.first { $0.isCompletionConfirmation == true })
        XCTAssertEqual(check.calendarMatch?.hour, 2, "The DST day's 03:03 delivery must not shift every later day's check")
        XCTAssertEqual(check.calendarMatch?.minute, 3)
        XCTAssertEqual(cal.component(.hour, from: check.firesAt), 3)
        XCTAssertEqual(check.firesAt.timeIntervalSince(try XCTUnwrap(plan.requests.first { $0.isPrimary }?.firesAt)), 300)
    }

    func testPendingTaskGetsOneActionableConfirmationAfterDueTime() throws {
        let card = task("取快递")
        var library = LibrarySnapshot(); library.cards = [card]
        let now = date(12, 15).addingTimeInterval(60)
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(plan.requests.count, 1)
        let request = try XCTUnwrap(plan.requests.first)
        XCTAssertEqual(request.isCompletionConfirmation, true)
        XCTAssertEqual(request.firesAt, date(12, 15).addingTimeInterval(300))
        XCTAssertEqual(request.title, card.title); XCTAssertTrue(request.body.contains("已完成"))
        XCTAssertEqual(try request.payload.resolve(in: library, deliveredAt: request.firesAt, calendar: calendar).plannedAt, date(12, 15))
        let later = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(12,16), capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertTrue(later.requests.isEmpty, "An unanswered check must not become an endless loop")
    }

    func testConfirmationAcrossMidnightResolvesThePreviousDaysOccurrence() throws {
        var card = task("睡前关窗", day: 11, repeating: true); card.schedule?.time = DayTime(hour: 23, minute: 58)
        var library = LibrarySnapshot(); library.cards = [card]
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(11,23), capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(plan.requests.count, 2)
        let check = try XCTUnwrap(plan.requests.first { $0.isCompletionConfirmation == true })
        XCTAssertEqual(check.calendarMatch?.hour, 0); XCTAssertEqual(check.calendarMatch?.minute, 3)
        let delivered = date(13,0).addingTimeInterval(180)
        XCTAssertEqual(try check.payload.resolve(in: library, deliveredAt: delivered, calendar: calendar).plannedAt, date(12,23).addingTimeInterval(58*60))
    }

    func testCompletionBeforeConfirmationCancelsOnlyThatOccurrence() throws {
        let card = task("每日检查", day: 11, repeating: true)
        var library = LibrarySnapshot(); library.cards = [card]
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).next(for: card, after: date(11)))
        let now = date(11,15).addingTimeInterval(60)
        library.events = [TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "test", kind: .completed, now: now)]
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertFalse(plan.requests.contains { $0.firesAt == date(11,15).addingTimeInterval(300) })
        XCTAssertTrue(plan.requests.contains { $0.firesAt == date(12,15).addingTimeInterval(300) })
    }

    func testExplicitFollowUpAtConfirmationTimeDoesNotDuplicate() {
        var card = task("只问一次"); card.reminders.followUpMinutes = [5]
        var library = LibrarySnapshot(); library.cards = [card]
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertEqual(plan.requests.filter { $0.firesAt == date(12,15).addingTimeInterval(300) }.count, 1)
    }

    func testAlarmConfirmationRespectsPermissionAndTitlePrivacy() throws {
        var card = task("私密标题"); card.note = "私密备注"; card.reminders.channel = .alarm
        var library = LibrarySnapshot(); library.cards = [card]
        var prefs = AppPreferences(); prefs.notificationPrivacy = .hidden
        let planner = ReminderPlanner(calendar: calendar)
        let denied = planner.plan(library: library, preferences: prefs, now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: false, alarmAllowed: true))
        XCTAssertTrue(denied.requests.allSatisfy { $0.channel == .alarm })
        XCTAssertTrue(denied.issues.contains { $0.message.contains("完成确认") })
        let allowed = planner.plan(library: library, preferences: prefs, now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true, alarmAllowed: true))
        let check = try XCTUnwrap(allowed.requests.first { $0.isCompletionConfirmation == true })
        XCTAssertEqual(check.channel, .notification)
        XCTAssertFalse(allowed.requests.contains { $0.title.contains("私密") || $0.body.contains("私密") })
        prefs.completionConfirmationDelay = 0
        let disabled = planner.plan(library: library, preferences: prefs, now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: false, alarmAllowed: true))
        XCTAssertFalse(disabled.issues.contains { $0.message.contains("完成确认") })
    }

    func testTurningOffConfirmationPreservesExplicitFollowUpNodes() {
        var card = task("保留自己的追加提醒"); card.reminders.followUpMinutes = [10]
        var library = LibrarySnapshot(); library.cards = [card]
        var prefs = AppPreferences(); prefs.completionConfirmationDelay = 0
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: prefs, now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(plan.requests.count, 2)
        XCTAssertFalse(plan.requests.contains { $0.isCompletionConfirmation == true })
        XCTAssertTrue(plan.requests.contains { $0.firesAt == date(12,15).addingTimeInterval(600) })
    }

    func testOlderSnoozedTaskStillGetsConfirmationAfterSnoozeFires() throws {
        let card = task("旧安排", day: 1)
        var library = LibrarySnapshot(); library.cards = [card]
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card, at: date(13)))
        var state = PersonalReminderState(occurrenceID: occurrence.id, now: date(13))
        state.snoozedUntil = date(13,11); state.snoozedOccurrence = occurrence
        library.personalStates[occurrence.id] = state
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(13,11).addingTimeInterval(60), capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertEqual(plan.requests.first?.firesAt, date(13,11).addingTimeInterval(300))
    }

    func testOldPreferencesAndReminderPayloadsRemainDecodable() throws {
        let data = try JSONEncoder().encode(AppPreferences())
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.completionConfirmationMinutes, 5)
        var library = LibrarySnapshot(); library.cards = [task("旧登记")]
        let request = try XCTUnwrap(ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true)).requests.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "isCompletionConfirmation")
        let legacy = try JSONDecoder().decode(PlannedReminder.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.id, request.id); XCTAssertNil(legacy.isCompletionConfirmation)
    }

    func testSimpleRepeatsDoNotAlsoRegisterIndividualCopies() {
        for frequency in [RepeatFrequency.daily, .weekly, .monthly, .yearly] {
            var card = task("循环提醒", day: 11, repeating: true)
            card.schedule?.frequency = frequency
            if frequency == .weekly { card.schedule?.weekdays = [1, 3] }
            var library = LibrarySnapshot(); library.cards = [card]
            let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true))
            XCTAssertEqual(plan.requests.filter { $0.isCompletionConfirmation != true }.count, frequency == .weekly ? 2 : 1, "\(frequency) must not consume slots for dates already covered by its repeat")
            XCTAssertEqual(plan.requests.filter { $0.isCompletionConfirmation == true }.count, frequency == .weekly ? 2 : 1)
            XCTAssertTrue(plan.requests.allSatisfy { $0.calendarMatch != nil })
            XCTAssertTrue(plan.deferred.isEmpty)
        }
    }

    func testRepeatDeduplicationPreservesExplicitLeadAndFollowUpNodes() {
        var card = task("练琴", day: 11, repeating: true)
        card.reminders.advanceMinutes = [0, 10]; card.reminders.followUpMinutes = [15]
        var library = LibrarySnapshot(); library.cards = [card]
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true), budget: 500)
        XCTAssertEqual(plan.requests.filter { $0.calendarMatch != nil }.count, 2)
        XCTAssertFalse(plan.requests.contains { $0.calendarMatch == nil && $0.payload.offsetMinutes == 0 })
        for offset in [-10, 15] {
            XCTAssertTrue(plan.requests.contains { $0.firesAt == date(12, 15).addingTimeInterval(Double(offset * 60)) })
        }
    }

    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func date(_ day: Int, _ hour: Int = 10) -> Date { calendar.date(from: DateComponents(year: 2026,month: 9,day: day,hour: hour))! }
    func task(_ title: String, day: Int = 12, repeating: Bool = false) -> Card {
        var card = Card(title: title, kind: .task, now: date(11))
        card.schedule = ScheduleDefinition(start: CivilDate(year: 2026,month: 9,day: day),time: DayTime(hour: 15),frequency: repeating ? .daily : .never)
        card.reminders.isEnabled = true; return card
    }
    func testBudgetPrioritizesEveryCardsPrimaryOverFollowups() {
        var snapshot = LibrarySnapshot(); snapshot.cards = (0..<50).map { index in var c = task("task \(index)"); c.reminders.followUpMinutes = [5,10,30]; return c }
        let desired = ReminderPlanner(calendar: calendar).plan(library: snapshot,preferences: AppPreferences(),now: date(11),capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(desired.requests.count, 48)
        XCTAssertTrue(desired.requests.allSatisfy(\.isPrimary))
        XCTAssertEqual(Set(desired.requests.map(\.cardID)).count, 48)
        XCTAssertEqual(desired.issues.count, 2)
        XCTAssertEqual(desired.deferred.count, 152)
    }
    func testRepeatPayloadResolvesOriginalDeliveryDayAndNeverFirstOccurrence() throws {
        var snapshot = LibrarySnapshot(); snapshot.cards = [task("练琴",day: 11,repeating: true)]
        let desired = ReminderPlanner(calendar: calendar).plan(library: snapshot,preferences: AppPreferences(),now: date(11),capabilities: ReminderCapabilities(notificationsAllowed: true))
        let series = try XCTUnwrap(desired.requests.first { $0.payload.scope == .series })
        XCTAssertNil(series.payload.occurrenceID)
        let first = try series.payload.resolve(in: snapshot,deliveredAt: date(11,15),calendar: calendar)
        let third = try series.payload.resolve(in: snapshot,deliveredAt: date(13,15),calendar: calendar)
        XCTAssertNotEqual(first.id,third.id)
        XCTAssertEqual(third.plannedAt,date(13,15))
        snapshot.events = [TaskEvent(operationID: UUID(), occurrence: first,actorID: "test",kind: .completed,now: date(11,16))]
        let after = ReminderPlanner(calendar: calendar).plan(library: snapshot,preferences: AppPreferences(),now: date(11,16),capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertTrue(after.requests.contains { $0.id == series.id })
    }
    func testSeriesCannotFireBeforeItsFutureStartDate() {
        var snapshot = LibrarySnapshot(); snapshot.cards = [task("以后开始",day: 20,repeating: true)]
        let desired = ReminderPlanner(calendar: calendar).plan(library: snapshot,preferences: AppPreferences(),now: date(11),capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertTrue(desired.requests.allSatisfy { $0.firesAt >= date(20,15) && $0.calendarMatch == nil })
    }
    func testMovedOccurrenceEntersNewWindowAndLeavesOriginalWindow() throws {
        let card = task("改期")
        let engine = OccurrenceEngine(calendar: calendar)
        let occurrence = try XCTUnwrap(engine.next(for: card,after: date(11)))
        let override = OccurrenceOverride(occurrenceID: occurrence.id,cardID: card.id,kind: .rescheduled,newDate: date(20,15),now: date(11),original: occurrence)
        XCTAssertTrue(engine.occurrences(for: card,in: DateInterval(start: date(12,0),end: date(13,0)),overrides: [override]).isEmpty)
        XCTAssertEqual(engine.occurrences(for: card,in: DateInterval(start: date(20,0),end: date(21,0)),overrides: [override]).first?.id,occurrence.id)
    }
    func testStoppedOccurrenceAndSnoozeNeverMoveDueDate() throws {
        var snapshot = LibrarySnapshot(); var card = task("截至明天"); card.schedule?.dueAt = date(14); snapshot.cards = [card]
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).next(for: card,after: date(11)))
        var personal = PersonalReminderState(occurrenceID: occurrence.id,now: date(11)); personal.isStopped = true
        snapshot.personalStates[occurrence.id] = personal
        XCTAssertTrue(ReminderPlanner(calendar: calendar).plan(library: snapshot,preferences: AppPreferences(),now: date(11),capabilities: ReminderCapabilities(notificationsAllowed: true)).requests.isEmpty)
        personal.isStopped = false; personal.snoozedUntil = date(13); snapshot.personalStates[occurrence.id] = personal
        let desired = ReminderPlanner(calendar: calendar).plan(library: snapshot,preferences: AppPreferences(),now: date(11),capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(desired.requests.count,2); XCTAssertEqual(desired.requests.first?.firesAt,date(13));
        XCTAssertEqual(desired.requests.first { $0.isCompletionConfirmation == true }?.firesAt, date(13).addingTimeInterval(300)); XCTAssertEqual(card.schedule?.dueAt,date(14))
    }
    func testNoPermissionHasVisibleIssueAndNoImplicitAlarmFallback() {
        var snapshot = LibrarySnapshot(); var card = task("闹钟"); card.reminders.channel = .alarm; snapshot.cards = [card]
        let desired = ReminderPlanner(calendar: calendar).plan(library: snapshot,preferences: AppPreferences(),now: date(11),capabilities: ReminderCapabilities(notificationsAllowed: true,alarmAllowed: false))
        XCTAssertTrue(desired.requests.isEmpty); XCTAssertEqual(desired.issues.count,1)
    }
    func testGeofencesDeduplicateAndExposeDeferredCardsAndCooldown() {
        var cards = (0..<22).map { i -> Card in var c = task("地点 \(i)"); c.place = PlaceRule(name: "地点",address: "",latitude: 30 + Double(i)/100,longitude: 120); return c }
        var duplicate = cards[0]; duplicate.id = UUID(); cards.append(duplicate)
        let plan = GeofencePlanner.plan(cards: cards,now: date(11))
        XCTAssertEqual(plan.active.count,20); XCTAssertEqual(plan.active.flatMap(\.cardIDs).count,21); XCTAssertEqual(plan.deferred.count,2)
        XCTAssertFalse(GeofencePlanner.shouldNotify(place: cards[0].place!,transition: .enter,now: date(11),lastTrigger: date(11).addingTimeInterval(-60)))
    }
    func testInvalidDatesAndHalfOpenIntervals() {
        let invalid = ScheduleDefinition(start: CivilDate(year: 2026,month: 2,day: 31),time: DayTime(hour: 9))
        XCTAssertThrowsError(try invalid.validate())
        let range = DateInterval(start: date(11),end: date(12))
        XCTAssertTrue(range.containsHalfOpen(date(11))); XCTAssertFalse(range.containsHalfOpen(date(12)))
    }
    func testCustomNodeEditingDeduplicatesAndRejectsInvalidChangesAtomically() throws {
        var policy = ReminderPolicy(); policy.isEnabled = true
        try policy.setNode(120, followUp: false)
        try policy.setNode(180, followUp: false)
        try policy.setNode(120, followUp: false, replacing: 180)
        XCTAssertEqual(policy.advanceMinutes, [0,120])
        try policy.setNode(45, followUp: true)
        let before = policy
        for invalid in [-1, ReminderPolicy.maximumAdvanceMinutes + 1, Int.max] {
            XCTAssertThrowsError(try policy.setNode(invalid, followUp: false, replacing: 120))
            XCTAssertEqual(policy, before)
        }
        for invalid in [0,1441] { XCTAssertThrowsError(try policy.setNode(invalid, followUp: true)); XCTAssertEqual(policy, before) }
        for value in [1,2,3,4] { try policy.setNode(value, followUp: false) }
        XCTAssertEqual(policy.advanceMinutes.count, 6)
        XCTAssertThrowsError(try policy.setNode(5, followUp: false))
        try policy.setNode(60, followUp: true); try policy.setNode(1440, followUp: true)
        XCTAssertThrowsError(try policy.setNode(90, followUp: true))
        XCTAssertEqual(ReminderPolicy.nodeLabel(2910), "提前 2 天 30 分钟")
        let roundTrip = try JSONDecoder().decode(ReminderPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(roundTrip, policy)
    }
    func testSpokenParcelKeepsExplicitLeadAndAddsCompletionConfirmation() throws {
        let parsed = try ChineseCardParser(calendar: calendar).interpret("今天下午三点提前十分钟提醒我取快递", now: date(11))
        let card = try XCTUnwrap(parsed.first?.card)
        var library = LibrarySnapshot(); library.cards = [card]
        let planner = ReminderPlanner(calendar: calendar)
        let desired = planner.plan(library: library, preferences: AppPreferences(), now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(desired.requests.count, 2)
        XCTAssertEqual(desired.requests.first { $0.isCompletionConfirmation == true }?.firesAt, date(11,15).addingTimeInterval(300))
        XCTAssertEqual(desired.requests.first?.firesAt, date(11,15).addingTimeInterval(-600))
        XCTAssertEqual(card.schedule?.time, DayTime(hour: 15))
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).next(for: card, after: date(11)))
        library.events = [TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "test", kind: .completed, now: date(11))]
        XCTAssertTrue(planner.plan(library: library, preferences: AppPreferences(), now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true)).requests.isEmpty)
    }
    func testCustomLeadAndFollowUpAcrossMidnightAndPastNodes() {
        var card = task("跨天提醒", day: 12); card.schedule?.time = DayTime(hour: 0, minute: 10)
        card.reminders.advanceMinutes = [0,90,90,2880]; card.reminders.followUpMinutes = [45,1440]
        var library = LibrarySnapshot(); library.cards = [card]
        let desired = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(11), capabilities: ReminderCapabilities(notificationsAllowed: true))
        let planned = date(12,0).addingTimeInterval(600)
        XCTAssertEqual(Set(desired.requests.map(\.firesAt)), Set([-90,0,5,45,1440].map { planned.addingTimeInterval(Double($0) * 60) }))
        XCTAssertEqual(desired.requests.count, 5)
    }
}
