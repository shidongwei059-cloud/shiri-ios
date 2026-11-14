import XCTest
@testable import ShiriCore

final class CaptureAndOrderingTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 10))! }

    func testHandledPinnedAndRecentlyEditedCardsFollowPendingCards() {
        let pending = Card(title: "还没做", now: now.addingTimeInterval(-60))
        var completed = Card(title: "已完成并固定", now: now); completed.isPinned = true
        var done = CardProjection(card: completed, occurrence: nil); done.state = .completed
        var skipped = CardProjection(card: Card(title: "跳过", now: now), occurrence: nil); skipped.state = .skipped
        let waiting = CardProjection(card: pending, occurrence: nil)
        XCTAssertEqual([done, skipped, waiting].sorted(by: CardProjection.libraryOrder).map(\.card.title), ["还没做", "已完成并固定", "跳过"])
        done.state = .pending
        XCTAssertEqual([waiting, done].sorted(by: CardProjection.libraryOrder).first?.id, done.id)
    }

    func testSpokenAssistantWrappersPreserveActionsAndOtherPeople() throws {
        let cases = [
            ("明天下午三点喊我取快递", "取快递"),
            ("明早七点叫我起床", "起床"),
            ("明天下午三点，喊我一下去菜鸟驿站取快递", "去菜鸟驿站取快递"),
            ("请明天下午三点喊一下我去医院复诊", "去医院复诊"),
            ("明天下午三点喊妈妈吃饭", "喊妈妈吃饭"),
            ("明天下午三点喊我妈吃饭", "喊我妈吃饭"),
            ("明天下午三点喊我的同事开会", "喊我的同事开会"),
            ("明天下午三点叫我朋友取快递", "叫我朋友取快递"),
            ("明天下午三点提醒妈妈吃药", "提醒妈妈吃药"),
            ("明天下午三点叫小王去会议室开会", "叫小王去会议室开会"),
            ("明天下午三点提醒我喊爸爸吃饭", "喊爸爸吃饭"),
            ("明天下午三点去叫小李取快递", "去叫小李取快递"),
            ("明天下午三点去喊我家书店取书", "去喊我家书店取书")
        ]
        for (text, title) in cases {
            let result = try VoiceCaptureDraft.prepare(text, id: UUID(), startedAt: now, calendar: calendar)
            XCTAssertEqual(result.card.title, title, text)
            XCTAssertNil(result.card.place, text)
        }
    }

    func testWidgetCompletionSortingDoesNotDependOnPrivacyOrPinning() {
        var done = Card(title: "已完成", now: now); done.isPinned = true
        done.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 8))
        var waiting = Card(title: "待完成", now: now)
        waiting.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 15))
        let occurrence = OccurrenceEngine(calendar: calendar).relevantOccurrence(for: done, at: now)!
        var library = LibrarySnapshot(); library.cards = [done, waiting]
        library.events = [TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "test", kind: .completed, now: now)]
        for privacy in ContentPrivacy.allCases {
            var preferences = AppPreferences(); preferences.widgetPrivacy = privacy
            let snapshot = WidgetSnapshot.make(library: library, preferences: preferences, now: now, calendar: calendar)
            XCTAssertEqual(snapshot.cards.map(\.id), [waiting.id, done.id])
            XCTAssertEqual(snapshot.pendingCount, 1)
        }
    }

    func testOutsideAppConfirmationRequiresOneValidatedArrangement() throws {
        let id = UUID()
        let good = try VoiceCaptureDraft.prepare("明天下午三点喊我取快递", id: id, startedAt: now, calendar: calendar)
        XCTAssertEqual(good.id, id); XCTAssertEqual(good.card.id, id)
        XCTAssertTrue(VoiceCaptureDraft.canConfirm(good))
        for text in ["明天三点喊我起床", "明天取快递，后天买牛奶", "到公司提醒我拿文件"] {
            let result = try VoiceCaptureDraft.prepare(text, id: id, startedAt: now, calendar: calendar)
            XCTAssertFalse(VoiceCaptureDraft.canConfirm(result), text)
            XCTAssertEqual(result.originalText, text)
        }
        XCTAssertThrowsError(try VoiceCaptureDraft.prepare("  ", id: id, startedAt: now, calendar: calendar))
    }

    func testEditingSpokenDurationUsesTheChosenDateAndRepeatRule() throws {
        var card = try XCTUnwrap(ChineseCardParser(calendar: calendar).interpret("20分钟后喊我取快递", now: now).first?.card)
        let engine = OccurrenceEngine(calendar: calendar)
        XCTAssertEqual(engine.relevantOccurrence(for: card, at: now)?.plannedAt, now.addingTimeInterval(1200))
        card.schedule?.useCalendarTiming()
        card.schedule?.start = CivilDate(year: 2026, month: 9, day: 16)
        card.schedule?.time = DayTime(hour: 15)
        let chosen = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 15))!
        XCTAssertEqual(engine.relevantOccurrence(for: card, at: now)?.plannedAt, chosen)
        card.schedule?.frequency = .daily
        let interval = DateInterval(start: chosen, end: chosen.addingTimeInterval(3 * 86400))
        XCTAssertEqual(engine.occurrences(for: card, in: interval).count, 3)
        card.schedule?.timeZoneMode = .fixed
        card.schedule?.timeZoneIdentifier = "Asia/Shanghai"
        card.schedule?.useCalendarTiming()
        XCTAssertEqual(card.schedule?.timeZoneMode, .fixed, "Editing must preserve an explicitly selected time zone")
    }
}
