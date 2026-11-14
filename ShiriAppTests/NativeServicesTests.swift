import XCTest
import ImageIO
import PDFKit
import UIKit
import UserNotifications
import ActivityKit
import AlarmKit
import ShiriCore
@testable import Shiri

@MainActor
final class NativeServicesTests: XCTestCase {
    @available(iOS 18.0, *)
    func testWidgetVoiceConfirmationIsPersistentAndIdempotent() async throws {
        let repo = try await repository(), now = Date(), id = UUID()
        let draft = try VoiceCaptureDraft.prepare("整理书桌", id: id, startedAt: now, calendar: .current)
        try await repo.saveDraft(draft)
        let first = try await VoiceCapturePersistence.confirm(id: id, repository: repo, now: now)
        let second = try await VoiceCapturePersistence.confirm(id: id, repository: repo, now: now)
        let snapshot = try await repo.library(), drafts = try await repo.drafts()
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(snapshot.cards.count, 1)
        XCTAssertEqual(snapshot.cards.first?.title, "整理书桌"); XCTAssertTrue(drafts.isEmpty)
        XCTAssertFalse(StartWidgetVoiceIntent.openAppWhenRun)
        XCTAssertFalse(StopWidgetVoiceIntent.openAppWhenRun)
        XCTAssertFalse(SaveWidgetVoiceIntent.openAppWhenRun)
    }
    func testWidgetVoiceAmbiguityKeepsRecoverableDraft() async throws {
        let repo = try await repository(), now = Date(), id = UUID()
        let draft = try VoiceCaptureDraft.prepare("明天三点喊我取快递", id: id, startedAt: now, calendar: .current)
        try await repo.saveDraft(draft)
        do { _ = try await VoiceCapturePersistence.confirm(id: id, repository: repo, now: now); XCTFail("Ambiguous time must require review") }
        catch { XCTAssertTrue(error.localizedDescription.contains("核对")) }
        let snapshot = try await repo.library(), drafts = try await repo.drafts()
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertEqual(drafts.first?.originalText, "明天三点喊我取快递")
        XCTAssertEqual(drafts.first?.card.title, "取快递")
    }
    func testWidgetVoiceDraftWaitsForStartupAndPreservesCurrentEdits() async throws {
        let repo = try await repository(), model = AppModel(), id = UUID()
        let draft = try VoiceCaptureDraft.prepare("明天三点喊我取快递", id: id, startedAt: Date(), calendar: .current)
        try await repo.saveDraft(draft)
        let url = URL(string: "nianyi://draft/\(id)")!
        await model.openFile(url)
        XCTAssertEqual(model.pendingVoiceDraftID, id)
        XCTAssertNil(model.composer)
        model.prepareRefreshForTesting(repository: repo, effect: {})
        addTeardownBlock { try await model.finishRefreshForTesting() }
        model.isLoading = false
        model.create(kind: .note)
        model.composer?.card.title = "尚未保存的内容"
        let original = model.composer
        model.presentPendingComposer()
        XCTAssertEqual(model.composer, original)
        model.cancelPendingComposer()
        XCTAssertNil(model.pendingVoiceDraftID)
        await model.openFile(url)
        XCTAssertEqual(model.composer, original)
        let opened = expectation(description: "Restores the recorded draft after the current editor closes")
        let subscription = model.$composer.sink { if $0?.id == id { opened.fulfill() } }
        defer { subscription.cancel() }
        model.composer = nil; model.presentPendingComposer()
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(model.composer, draft)
        XCTAssertFalse(model.startsWithSpeech)
        XCTAssertNil(model.pendingVoiceDraftID)
        let library = try await repo.library()
        XCTAssertTrue(library.cards.isEmpty, "Recovering a draft must not save a card automatically")
    }
    @available(iOS 26.0, *)
    private func registeredAlarm(title: String = "完成验收", after seconds: TimeInterval = 900) async throws -> (ShiriRepository, PlannedReminder) {
        try await AlarmAdapter.requestPermission()
        let repo = try await repository(), now = Date()
        let target = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + seconds)
        var card = Card(title: title, now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: .current), time: DayTime(hour: Calendar.current.component(.hour, from: target), minute: Calendar.current.component(.minute, from: target)))
        card.schedule?.timeZoneMode = .elapsed; card.schedule?.absoluteInstant = target
        card.reminders.isEnabled = true; card.reminders.channel = .alarm
        _ = try await CardCommands(repository: repo).save(CardDraft(card: card), now: now)
        let library = try await repo.library()
        let desired = ReminderPlanner(calendar: .current).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: false, alarmAllowed: true))
        let ledger = try await AlarmAdapter.reconcile(desired, repository: repo, now: now)
        return (repo, try XCTUnwrap(ledger.first?.request))
    }

    @available(iOS 26.0, *)
    func testAlarmShowsLiteralTaskTitleAndUsesSystemStop() async throws {
        let (_, request) = try await registeredAlarm(title: "取快递 %@ · 第 2 次")
        defer { try? AlarmManager.shared.cancel(id: StableID.uuid(request.id)) }
        let alert = AlarmAdapter.alert(for: request)
        XCTAssertEqual(String(localized: alert.title), request.title)
        XCTAssertNil(alert.secondaryButton)
    }

    @available(iOS 26.0, *)
    func testCompletionNotificationActionPersistsAndCancelsAlarm() async throws {
        let (repo, request) = try await registeredAlarm()
        defer { try? AlarmManager.shared.cancel(id: StableID.uuid(request.id)) }
        try await SystemActionHandler.handle(action: "COMPLETE", payload: request.payload, deliveredAt: request.firesAt, repository: repo, now: Date())
        let library = try await repo.library()
        let occurrence = try request.payload.resolve(in: library, deliveredAt: request.firesAt, calendar: .current)
        XCTAssertEqual(EventReducer.state(events: library.events(for: occurrence.id)), .completed)
        XCTAssertFalse(try AlarmManager.shared.alarms.contains { $0.id == StableID.uuid(request.id) })
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        XCTAssertFalse(pending.contains { NotificationAdapter.payload($0.content.userInfo)?.cardID == request.cardID })
    }

    @available(iOS 26.0, *)
    func testConfirmationSnoozeKeepsTaskPendingAndRegistersOneNewAlarm() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        let (repo, request) = try await registeredAlarm()
        let now = Date()
        try await SystemActionHandler.handle(action: "SNOOZE", payload: request.payload, deliveredAt: request.firesAt, repository: repo, now: now)
        let library = try await repo.library()
        let occurrence = try request.payload.resolve(in: library, deliveredAt: request.firesAt, calendar: .current)
        XCTAssertEqual(library.personalStates[occurrence.id]?.snoozedUntil, now.addingTimeInterval(600))
        XCTAssertEqual(EventReducer.state(events: library.events(for: occurrence.id)), .pending)
        let ledger = try await repo.deviceValue([ReminderLedgerEntry].self, key: "alarm-ledger") ?? []
        let notifications = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { NotificationAdapter.payload($0.content.userInfo)?.cardID == request.cardID }
        defer {
            for entry in ledger { try? AlarmManager.shared.cancel(id: StableID.uuid(entry.id)) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notifications.map(\.identifier))
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifications.map(\.identifier))
        }
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.first?.request.firesAt, now.addingTimeInterval(600))
        XCTAssertFalse(try AlarmManager.shared.alarms.contains { $0.id == StableID.uuid(request.id) })
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.content.subtitle, "这件事完成了吗？")
    }

    @available(iOS 26.0, *)
    func testForegroundKeepsRingingUntilSnoozeReplacesTheAlarm() async throws {
        let (repo, request) = try await registeredAlarm(after: 8)
        let id = StableID.uuid(request.id)
        defer { try? AlarmManager.shared.cancel(id: id) }
        let deadline = Date().addingTimeInterval(18)
        while Date() < deadline {
            if try AlarmManager.shared.alarms.contains(where: { $0.id == id && $0.state == .alerting }) { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertTrue(try AlarmManager.shared.alarms.contains { $0.id == id && $0.state == .alerting })
        let library = try await repo.library(), now = Date()
        let desired = ReminderPlanner(calendar: .current).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: false, alarmAllowed: true))
        let ledger = try await AlarmAdapter.reconcile(desired, repository: repo, now: now)
        XCTAssertTrue(ledger.contains { $0.id == request.id })
        XCTAssertTrue(try AlarmManager.shared.alarms.contains { $0.id == id && $0.state == .alerting })
        try await SystemActionHandler.handle(action: "SNOOZE", payload: request.payload, deliveredAt: request.firesAt, repository: repo, now: Date())
        let snoozed = try await repo.deviceValue([ReminderLedgerEntry].self, key: "alarm-ledger") ?? []
        defer {
            for entry in snoozed { try? AlarmManager.shared.cancel(id: StableID.uuid(entry.id)) }
        }
        XCTAssertEqual(snoozed.count, 1)
        XCTAssertFalse(try AlarmManager.shared.alarms.contains { $0.id == id })
        let notifications = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { NotificationAdapter.payload($0.content.userInfo)?.cardID == request.cardID }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: notifications.map(\.identifier))
    }

    func testNotificationCategoryProvidesDirectCompleteSnoozeAndTimeChange() async throws {
        NotificationAdapter.registerActions()
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        let category = try XCTUnwrap(categories.first { $0.identifier == NotificationAdapter.category })
        XCTAssertEqual(category.actions.map(\.identifier), ["COMPLETE", "SNOOZE", "RESCHEDULE", "STOP"])
        XCTAssertTrue(try XCTUnwrap(category.actions.first { $0.identifier == "COMPLETE" }).options.contains(.authenticationRequired))
        XCTAssertTrue(try XCTUnwrap(category.actions.first { $0.identifier == "RESCHEDULE" }).options.contains(.foreground))
    }

    @available(iOS 26.0, *)
    func testStaleNotificationActionCannotCompleteAnEditedSchedule() async throws {
        let (repo, request) = try await registeredAlarm()
        defer { try? AlarmManager.shared.cancel(id: StableID.uuid(request.id)) }
        let savedLibrary = try await repo.library()
        var card = try XCTUnwrap(savedLibrary.cards.first)
        card.schedule?.time = DayTime(hour: 22); card.schedule?.absoluteInstant = Date().addingTimeInterval(7200)
        _ = try await CardCommands(repository: repo).save(CardDraft(card: card, isEditing: true), now: Date())
        do { try await SystemActionHandler.handle(action: "COMPLETE", payload: request.payload, deliveredAt: request.firesAt, repository: repo, now: Date()); XCTFail("An old alarm must not complete the edited occurrence") }
        catch ShiriError.validation { }
        let library = try await repo.library(); XCTAssertTrue(library.events.isEmpty)
    }

    func testNearFutureNotificationActuallyReachesDeliveredCenter() async throws {
        let now = Date(), calendar = Calendar.current
        let target = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 8)
        let repo = try await repository(), commands = CardCommands(repository: repo)
        var card = Card(title: "模拟器实际送达验收", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: calendar), time: DayTime(hour: calendar.component(.hour, from: target), minute: calendar.component(.minute, from: target)))
        card.schedule?.timeZoneMode = .elapsed; card.schedule?.absoluteInstant = target
        card.reminders.isEnabled = true
        card = try await commands.save(CardDraft(card: card), now: now)
        let center = UNUserNotificationCenter.current()
        let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        XCTAssertTrue(allowed)
        let library = try await repo.library()
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: allowed))
        let ledger = try await NotificationAdapter.shared.reconcile(plan, library: library, repository: repo, now: now)
        let id = try XCTUnwrap(ledger.first?.id)
        let ids = ledger.map(\.id)
        defer { center.removePendingNotificationRequests(withIdentifiers: ids); center.removeDeliveredNotifications(withIdentifiers: ids) }
        XCTAssertEqual(ledger.count, 2); XCTAssertEqual(ledger.first?.status, .registered)
        XCTAssertEqual(ledger.filter { $0.request.isCompletionConfirmation == true }.count, 1)
        var received: UNNotification?
        let deadline = target.addingTimeInterval(12)
        while Date() < deadline && received == nil {
            received = await center.deliveredNotifications().first { $0.request.identifier == id }
            if received == nil { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        let delivered = try XCTUnwrap(received, "A pending request alone is not delivery evidence")
        XCTAssertEqual(delivered.request.content.title, card.title)
        XCTAssertGreaterThanOrEqual(delivered.date, target.addingTimeInterval(-1))
        let evidence = "Planned: \(target.ISO8601Format()); delivered: \(delivered.date.ISO8601Format()); foreground simulator only."
        let attachment = XCTAttachment(string: evidence); attachment.name = "actual-notification-delivery"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDailyRepeatRegistersOneReminderAndOneConfirmationAndCancelsAfterDeletion() async throws {
        let now = Date(), calendar = Calendar.current
        let target = now.addingTimeInterval(3600)
        let repo = try await repository(), commands = CardCommands(repository: repo)
        var card = Card(title: "每天只安排一份通知", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: calendar), time: DayTime(hour: calendar.component(.hour, from: target), minute: calendar.component(.minute, from: target)), frequency: .daily)
        card.reminders.isEnabled = true
        card = try await commands.save(CardDraft(card: card), now: now)
        let center = UNUserNotificationCenter.current()
        let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        XCTAssertTrue(allowed)
        let planner = ReminderPlanner(calendar: calendar)
        var library = try await repo.library()
        let plan = planner.plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: allowed))
        let ledger = try await NotificationAdapter.shared.reconcile(plan, library: library, repository: repo, now: now)
        let ids = Set(ledger.map(\.id))
        defer { center.removePendingNotificationRequests(withIdentifiers: Array(ids)) }
        let actual = await center.pendingNotificationRequests().filter { ids.contains($0.identifier) }
        XCTAssertEqual(ledger.count, 2); XCTAssertEqual(actual.count, 2)
        XCTAssertEqual(ledger.filter { $0.request.isCompletionConfirmation != true }.count, 1)
        XCTAssertEqual(ledger.filter { $0.request.isCompletionConfirmation == true }.count, 1)
        XCTAssertEqual((actual.first?.trigger as? UNCalendarNotificationTrigger)?.repeats, true)
        XCTAssertTrue(plan.deferred.isEmpty)
        try await commands.setLifecycle(card: card, lifecycle: .deleted, now: now)
        library = try await repo.library()
        let removed = planner.plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: allowed))
        _ = try await NotificationAdapter.shared.reconcile(removed, library: library, repository: repo, now: now)
        let remaining = await center.pendingNotificationRequests()
        XCTAssertFalse(remaining.contains { ids.contains($0.identifier) })
    }

    func testSpokenCustomRemindersPersistRegisterAndCancelAfterCompletion() async throws {
        let now = Date(), calendar = Calendar.current
        let text = "明天下午三点提前两小时和十分钟提醒我去菜鸟驿站取快递，到点也提醒，之后四十五分钟再提醒一次"
        let draft = try XCTUnwrap(ChineseCardParser(calendar: calendar).interpret(text, now: now).first)
        XCTAssertTrue(draft.questions.isEmpty)
        let repo = try await repository()
        let card = try await CardCommands(repository: repo).save(draft, now: now)
        var library = try await repo.library()
        XCTAssertEqual(library.cards.first?.title, "去菜鸟驿站取快递")
        XCTAssertEqual(library.cards.first?.reminders.advanceMinutes, [0,10,120])
        XCTAssertEqual(library.cards.first?.reminders.followUpMinutes, [45])
        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound,.badge])
        XCTAssertTrue(allowed)
        let planner = ReminderPlanner(calendar: calendar)
        let desired = planner.plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: allowed))
        XCTAssertEqual(desired.requests.count, 5)
        let ledger = try await NotificationAdapter.shared.reconcile(desired, library: library, repository: repo, now: now)
        let ids = Set(ledger.map(\.id))
        defer { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Array(ids)) }
        XCTAssertEqual(ledger.filter { $0.status == .registered }.count, 5)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { ids.contains($0.identifier) }
        XCTAssertEqual(pending.count, 5)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).next(for: card, after: now))
        let planned = try XCTUnwrap(occurrence.plannedAt)
        let actualDates = pending.compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }
        XCTAssertEqual(Set(actualDates), Set([-120,-10,0,5,45].map { planned.addingTimeInterval(Double($0) * 60) }))
        try await CardCommands(repository: repo).complete(occurrence, now: now)
        library = try await repo.library()
        let finished = planner.plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: allowed))
        _ = try await NotificationAdapter.shared.reconcile(finished, library: library, repository: repo, now: now)
        let remaining = await UNUserNotificationCenter.current().pendingNotificationRequests()
        XCTAssertFalse(remaining.contains { ids.contains($0.identifier) })
    }
    func testCardThumbnailsRespectSizeAndKeepOriginalsIntact() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: format).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.9)), original = data
        let cache = CardThumbnailCache()
        let large = await cache.image(data: data, cacheKey: "landscape", maximumPixelSize: 1200)
        let small = await cache.image(data: data, cacheKey: "landscape", maximumPixelSize: 400)
        XCTAssertEqual(large?.cgImage?.width, 1200); XCTAssertEqual(large?.cgImage?.height, 600)
        XCTAssertEqual(small?.cgImage?.width, 400); XCTAssertEqual(small?.cgImage?.height, 200)
        XCTAssertEqual(data, original)
        let invalid = await cache.image(data: Data("not an image".utf8))
        XCTAssertNil(invalid)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(data: data, cacheKey: "landscape")
        }
        let cancelledImage = await cancelled.value
        XCTAssertNil(cancelledImage)
    }

    func testWidgetDatesRemainAccurateAndHiddenContentStaysPrivate() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 8)))
        var timed = Card(title: "给妈妈打个电话", now: now)
        timed.note = "只给自己看的备注"
        timed.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 19))
        var allDay = Card(title: "整理照片", now: now)
        allDay.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: nil)
        var library = LibrarySnapshot(); library.cards = [timed, allDay]
        let visible = WidgetSnapshot.make(library: library, preferences: AppPreferences(), now: now, calendar: calendar)
        XCTAssertEqual(visible.cards.first { $0.id == timed.id }?.isDateOnly, false)
        XCTAssertEqual(visible.cards.first { $0.id == allDay.id }?.isDateOnly, true)
        XCTAssertEqual(visible.pendingCount, 2)
        var preferences = AppPreferences(); preferences.widgetPrivacy = .hidden
        let hidden = WidgetSnapshot.make(library: library, preferences: preferences, now: now, calendar: calendar)
        XCTAssertTrue(hidden.hidesContent)
        XCTAssertEqual(hidden.pendingCount, 2)
        XCTAssertTrue(hidden.cards.allSatisfy { $0.title == "打开拾日查看" && $0.note.isEmpty && !$0.canComplete })
    }

    func testOldWidgetCardsWithoutDateOnlyFieldStillDecode() throws {
        let now = Date(); var library = LibrarySnapshot()
        var card = Card(title: "旧版定时卡片", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: .current), time: DayTime(hour: 23))
        library.cards = [card]
        let snapshot = WidgetSnapshot.make(library: library, preferences: AppPreferences(), now: now, calendar: .current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(snapshot.cards.first))) as? [String: Any])
        object.removeValue(forKey: "isDateOnly")
        let decoded = try JSONDecoder().decode(WidgetCard.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, card.id)
        XCTAssertNotNil(decoded.plannedAt)
        XCTAssertNil(decoded.isDateOnly)
        XCTAssertTrue(decoded.canComplete)
    }

    func testCustomSnoozeAcrossDaysKeepsPlanAndDeadline() async throws {
        let repo = try await repository(), now = Date()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var card = Card(title: "先提醒，后截止", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 23))
        card.schedule?.dueAt = now.addingTimeInterval(172800); card.reminders.isEnabled = true
        card = try await CardCommands(repository: repo).save(CardDraft(card: card), now: now)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card, at: now))
        let chosen = now.addingTimeInterval(259200)
        try await CardCommands(repository: repo).snooze(occurrence, until: chosen, now: now)
        let snapshot = try await repo.library()
        XCTAssertEqual(snapshot.cards.first?.schedule, card.schedule)
        XCTAssertEqual(snapshot.personalStates[occurrence.id]?.snoozedUntil, chosen)
        let plan = ReminderPlanner(calendar: calendar).plan(library: snapshot, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertTrue(plan.requests.contains { $0.cardID == card.id && $0.firesAt == chosen })
        XCTAssertEqual(EventReducer.state(events: snapshot.events(for: occurrence.id)), .pending)
        try await CardCommands(repository: repo).resumeReminder(occurrence, now: now)
        let resumed = try await repo.library()
        XCTAssertNil(resumed.personalStates[occurrence.id]?.snoozedUntil)
    }
    func testDeadlinePresentationSeparatesPlanAndPreservesHistoricalNoDeadline() {
        let now = Date()
        var card = Card(title: "交材料", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: .current), time: DayTime(hour: 9))
        let old = Occurrence(card: card, semanticKey: "old", plannedAt: now.addingTimeInterval(-3600))
        card.schedule?.dueAt = now.addingTimeInterval(3600)
        let current = Occurrence(card: card, semanticKey: "current", plannedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(CardPresentation.pendingTimeStatus(CardProjection(card: card, occurrence: current), now: now), "已到安排时间 · 未标记完成")
        XCTAssertEqual(CardPresentation.deadline(CardProjection(card: card, occurrence: current)), card.schedule?.dueAt)
        XCTAssertNil(CardPresentation.deadline(CardProjection(card: card, occurrence: old)))
        XCTAssertEqual(CardPresentation.pendingTimeStatus(CardProjection(card: card, occurrence: current), now: now.addingTimeInterval(7200)), "已到截止 · 未标记完成")
    }
    private var browsingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func browsingDate(_ day: Int, hour: Int = 9) -> Date {
        browsingCalendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
    func testSelectedDateCompletionAndSkipKeepTodayPending() async throws {
        let repo = try await repository(), commands = CardCommands(repository: repo)
        let now = browsingDate(12), chosenDate = browsingDate(19)
        var card = Card(title: "每天读一页", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: browsingCalendar), time: DayTime(hour: 9))
        card.schedule?.frequency = .daily
        card = try await commands.save(CardDraft(card: card), now: now)
        var library = try await repo.library()
        let today = try XCTUnwrap(AppModel.projectDay(library, on: now, calendar: browsingCalendar).first?.occurrence)
        let chosen = try XCTUnwrap(AppModel.projectDay(library, on: chosenDate, calendar: browsingCalendar).first?.occurrence)
        let detail = try XCTUnwrap(AppModel.detailProjection(cardID: card.id, in: library, occurrence: chosen, now: now, calendar: browsingCalendar))
        XCTAssertEqual(detail.occurrence?.id, chosen.id)
        XCTAssertNotEqual(detail.occurrence?.id, today.id)
        try await commands.complete(try XCTUnwrap(detail.occurrence), now: now)
        library = try await repo.library()
        XCTAssertEqual(EventReducer.state(events: library.events(for: today.id)), .pending)
        XCTAssertEqual(AppModel.detailProjection(cardID: card.id, in: library, occurrence: chosen, now: now, calendar: browsingCalendar)?.state, .completed)
        try await commands.undo(chosen, now: now)
        try await commands.skip(chosen, now: now)
        library = try await repo.library()
        XCTAssertEqual(AppModel.projectDay(library, on: chosenDate, calendar: browsingCalendar).first?.state, .skipped)
        XCTAssertEqual(EventReducer.state(events: library.events(for: today.id)), .pending)
    }
    func testDateBrowsingKeepsBothRepetitionsMovedOntoOneDay() async throws {
        let repo = try await repository(), commands = CardCommands(repository: repo)
        let now = browsingDate(12)
        var card = Card(title: "练一小段琴", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: browsingCalendar), time: DayTime(hour: 9))
        card.schedule?.frequency = .daily
        card = try await commands.save(CardDraft(card: card), now: now)
        var library = try await repo.library()
        let original = try XCTUnwrap(AppModel.projectDay(library, on: browsingDate(19), calendar: browsingCalendar).first?.occurrence)
        let regular = try XCTUnwrap(AppModel.projectDay(library, on: browsingDate(20), calendar: browsingCalendar).first?.occurrence)
        let movedDate = browsingDate(20, hour: 10)
        try await commands.rescheduleOccurrence(original, to: movedDate, now: now)
        library = try await repo.library()
        let sameDay = AppModel.projectDay(library, on: browsingDate(20), calendar: browsingCalendar)
        XCTAssertEqual(sameDay.count, 2)
        XCTAssertEqual(Set(sameDay.compactMap { $0.occurrence?.id }), Set([original.id, regular.id]))
        XCTAssertTrue(AppModel.projectDay(library, on: browsingDate(19), calendar: browsingCalendar).isEmpty)
        let detail = try XCTUnwrap(AppModel.detailProjection(cardID: card.id, in: library, occurrence: original, now: now, calendar: browsingCalendar))
        XCTAssertEqual(detail.occurrence?.id, original.id)
        XCTAssertEqual(detail.occurrence?.plannedAt, movedDate)
        try await commands.complete(try XCTUnwrap(detail.occurrence), now: now)
        library = try await repo.library()
        XCTAssertEqual(EventReducer.state(events: library.events(for: regular.id)), .pending)
        XCTAssertEqual(AppModel.projectDay(library, on: browsingDate(20), calendar: browsingCalendar).filter { $0.state == .completed }.count, 1)
    }
    func testDateBrowsingPreservesCommittedHistoryAfterRuleChanges() async throws {
        let repo = try await repository(), commands = CardCommands(repository: repo)
        let now = browsingDate(12)
        var card = Card(title: "每日整理", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: browsingCalendar), time: DayTime(hour: 9))
        card.schedule?.frequency = .daily
        card = try await commands.save(CardDraft(card: card), now: now)
        var library = try await repo.library()
        let historic = try XCTUnwrap(AppModel.projectDay(library, on: browsingDate(13), calendar: browsingCalendar).first?.occurrence)
        let pending = try XCTUnwrap(AppModel.projectDay(library, on: browsingDate(19), calendar: browsingCalendar).first?.occurrence)
        try await commands.complete(historic, now: now)
        card.schedule?.start = CivilDate(browsingDate(20), calendar: browsingCalendar)
        card = try await commands.save(CardDraft(card: card, isEditing: true), now: now)
        library = try await repo.library()
        let past = AppModel.projectDay(library, on: browsingDate(13), calendar: browsingCalendar)
        XCTAssertEqual(past.count, 1)
        XCTAssertEqual(past.first?.occurrence?.id, historic.id)
        XCTAssertEqual(past.first?.state, .completed)
        XCTAssertEqual(AppModel.detailProjection(cardID: card.id, in: library, occurrence: historic, now: now, calendar: browsingCalendar)?.occurrence?.id, historic.id)
        let revised = try XCTUnwrap(AppModel.detailProjection(cardID: card.id, in: library, occurrence: pending, now: now, calendar: browsingCalendar)?.occurrence)
        XCTAssertEqual(revised.scheduleID, card.schedulingID)
        XCTAssertEqual(revised.plannedAt, browsingDate(20))
        try await commands.setLifecycle(card: card, lifecycle: .archived, now: now)
        library = try await repo.library()
        XCTAssertTrue(AppModel.projectDay(library, on: browsingDate(13), calendar: browsingCalendar).isEmpty)
    }
    func testDateBrowsingSelectionClearsOnOtherCardAndDismissal() {
        let model = AppModel(), now = browsingDate(12)
        let first = Card(title: "第一张卡", now: now), second = Card(title: "第二张卡", now: now)
        let occurrence = Occurrence(card: first, semanticKey: "selected", plannedAt: browsingDate(19))
        model.openCard(CardProjection(card: first, occurrence: occurrence))
        XCTAssertEqual(model.selectedOccurrence?.id, occurrence.id)
        var updated = first; updated.title = "修改后的第一张卡"
        model.selectedCard = updated
        XCTAssertEqual(model.selectedOccurrence?.id, occurrence.id)
        model.selectedCard = second
        XCTAssertNil(model.selectedOccurrence)
        model.openCard(CardProjection(card: first, occurrence: occurrence))
        model.selectedCard = nil
        XCTAssertNil(model.selectedOccurrence)
        model.selectedCard = first
        XCTAssertNil(model.selectedOccurrence)
    }
    func testSameCardDeepLinkClearsPreviouslyBrowsedOccurrence() async throws {
        let model = AppModel(), now = browsingDate(12)
        var card = Card(title: "每天读一页", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: browsingCalendar), time: DayTime(hour: 9), frequency: .daily)
        var library = LibrarySnapshot(); library.cards = [card]
        model.library = library; model.projections = AppModel.project(library, now: now, calendar: browsingCalendar)
        let selected = try XCTUnwrap(AppModel.projectDay(library, on: browsingDate(19), calendar: browsingCalendar).first)
        model.openCard(selected)
        XCTAssertEqual(model.selectedOccurrence?.id, selected.occurrence?.id)
        try await model.openFile(XCTUnwrap(URL(string: "nianyi://card/" + card.id.uuidString)))
        XCTAssertEqual(model.selectedCard?.id, card.id)
        XCTAssertNil(model.selectedOccurrence)
        XCTAssertEqual(model.detailProjection(cardID: card.id)?.occurrence?.plannedAt, now)
    }
    func testNotificationInstanceReplacesSameCardBrowsingBeforeCompletion() async throws {
        let repo = try await repository(), commands = CardCommands(repository: repo)
        let model = AppModel(), now = browsingDate(12)
        var card = Card(title: "通知要对应当天", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: browsingCalendar), time: DayTime(hour: 9), frequency: .daily)
        card = try await commands.save(CardDraft(card: card), now: now)
        let library = try await repo.library()
        let current = try XCTUnwrap(AppModel.projectDay(library, on: now, calendar: browsingCalendar).first?.occurrence)
        let selected = try XCTUnwrap(AppModel.projectDay(library, on: browsingDate(19), calendar: browsingCalendar).first)
        model.openCard(selected)
        let payload = NotificationPayload(card: card, occurrence: current, scope: .occurrence, offset: 0)
        let delivered = try payload.resolve(in: library, deliveredAt: now, calendar: browsingCalendar)
        model.openCard(card, occurrence: delivered)
        XCTAssertEqual(model.selectedOccurrence?.id, current.id)
        XCTAssertNotEqual(model.selectedOccurrence?.id, selected.occurrence?.id)
        try await commands.complete(XCTUnwrap(model.selectedOccurrence), now: now)
        let after = try await repo.library()
        XCTAssertEqual(EventReducer.state(events: after.events(for: current.id)), .completed)
        let selectedID = try XCTUnwrap(selected.occurrence?.id)
        XCTAssertEqual(EventReducer.state(events: after.events(for: selectedID)), .pending)
    }
    func testShareOnlySelectedOccurrenceUsesItsDateAndRejectsOldRules() throws {
        let now = browsingDate(12)
        var card = Card(title: "分享下周的安排", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: browsingCalendar), time: DayTime(hour: 9), frequency: .daily)
        card.schedule?.timeZoneMode = .fixed; card.schedule?.timeZoneIdentifier = browsingCalendar.timeZone.identifier
        var library = LibrarySnapshot(); library.cards = [card]
        let occurrence = try XCTUnwrap(AppModel.projectDay(library, on: browsingDate(19), calendar: browsingCalendar).first?.occurrence)
        let preview = try SharingComposerView.makeSnapshot(card: card, occurrence: occurrence, attachments: [], extent: .currentOccurrence, includeNote: true, includePhotos: false)
        let generated = try SharingComposerView.makeSnapshot(card: card, occurrence: occurrence, attachments: [], extent: .currentOccurrence, includeNote: true, includePhotos: true)
        let package = SharePackage(session: ShareSession(snapshot: generated, recipientLabel: "朋友", feedback: false, now: now))
        let decoded = try FileTransport.decodeShare(FileTransport.encode(package))
        XCTAssertEqual(decoded.snapshot.card.schedule?.start, preview.card.schedule?.start)
        XCTAssertEqual(decoded.snapshot.card.schedule?.time, preview.card.schedule?.time)
        XCTAssertEqual(decoded.snapshot.sourceOccurrenceKey, preview.sourceOccurrenceKey)
        XCTAssertEqual(decoded.snapshot.card.schedule?.start, CivilDate(browsingDate(19), calendar: browsingCalendar))
        XCTAssertEqual(decoded.snapshot.card.schedule?.frequency, .never)
        XCTAssertEqual(decoded.snapshot.sourceOccurrenceKey, occurrence.semanticKey)
        let wholeRule = try SharingComposerView.makeSnapshot(card: card, occurrence: occurrence, attachments: [], extent: .entireRule, includeNote: true, includePhotos: false)
        XCTAssertEqual(wholeRule.card.schedule, card.schedule)
        XCTAssertThrowsError(try SharingComposerView.makeSnapshot(card: card, occurrence: nil, attachments: [], extent: .currentOccurrence, includeNote: true, includePhotos: false))
        card.schedule?.id = UUID()
        XCTAssertThrowsError(try SharingComposerView.makeSnapshot(card: card, occurrence: occurrence, attachments: [], extent: .currentOccurrence, includeNote: true, includePhotos: false))
        XCTAssertThrowsError(try SharingComposerView.makeSnapshot(card: card, occurrence: occurrence, attachments: [], extent: .entireRule, includeNote: true, includePhotos: false))
    }
    func testSceneArtworkKeepsExplicitAppearanceAndNeutralDefaults() {
        let now = Date()
        var card = Card(title: "整理本周安排", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: .current), time: DayTime(hour: 9))
        XCTAssertEqual(CardArtwork.asset(for: card), "DeskCalendar")
        card.schedule = nil
        XCTAssertEqual(CardArtwork.asset(for: card), "PaperNotebook")
        card.appearance.overriddenFields.insert("illustration")
        XCTAssertEqual(CardArtwork.asset(for: card), "Ginkgo")
        card.appearance.illustration = .none
        XCTAssertNil(CardArtwork.asset(for: card))
        card.appearance.overriddenFields = []; card.appearance.illustration = .ginkgo; card.title = "去花店取花"
        XCTAssertEqual(CardArtwork.asset(for: card), "Ginkgo")
        card.birthday = BirthdayRule(name: "相识纪念日", calendar: .gregorian, month: 10, day: 18); card.birthday?.occasion = .anniversary
        XCTAssertEqual(CardArtwork.asset(for: card), "ReviewFlowers")
        for name in ["PaperNotebook", "QuietTea", "SearchCards", "PaperEnvelope", "DeskCalendar"] { XCTAssertNotNil(UIImage(named: name), name) }
    }
    @available(iOS 16.1, *)
    func testSavedCardStartsWithoutNotificationAndUpdatesWithoutReplacingOtherCards() async throws {
        let repo = try await repository(), service = LiveActivityService()
        let now = Date(), calendar = Calendar.current, target = Date().addingTimeInterval(1200)
        var first = Card(title: "喝一杯水", now: now)
        first.schedule = ScheduleDefinition(start: CivilDate(target, calendar: calendar), time: DayTime(hour: calendar.component(.hour, from: target), minute: calendar.component(.minute, from: target)))
        first.reminders.enablesLiveActivity = true
        first = try await CardCommands(repository: repo).save(CardDraft(card: first), now: now)
        let firstID = first.id
        addTeardownBlock {
            for activity in Activity<ShiriActivityAttributes>.activities where activity.attributes.cardID == firstID.uuidString {
                await activity.end(using: nil, dismissalPolicy: .immediate)
            }
        }
        var library = try await repo.library()
        try await service.activateSavedCard(first, library: library, privacy: .hidden, now: now)
        let activity = try XCTUnwrap(Activity<ShiriActivityAttributes>.activities.first { $0.attributes.cardID == firstID.uuidString })
        XCTAssertEqual(activity.contentState.title, "有一件事等你处理")
        XCTAssertFalse(first.reminders.isEnabled)
        first.title = "慢慢喝一杯温水"
        first = try await CardCommands(repository: repo).save(CardDraft(card: first, isEditing: true), now: now)
        library = try await repo.library()
        try await service.activateSavedCard(first, library: library, privacy: .full, now: now)
        for _ in 0..<30 {
            if Activity<ShiriActivityAttributes>.activities.first(where: { $0.id == activity.id })?.contentState.title == first.title { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let updated = Activity<ShiriActivityAttributes>.activities.filter { $0.attributes.cardID == firstID.uuidString }
        XCTAssertEqual(updated.count, 1); XCTAssertEqual(updated.first?.id, activity.id)
        XCTAssertEqual(updated.first?.contentState.title, first.title)
        var second = Card(title: "站起来走一走", now: now)
        second.schedule = first.schedule; second.reminders.enablesLiveActivity = true
        second = try await CardCommands(repository: repo).save(CardDraft(card: second), now: now)
        let secondID = second.id
        addTeardownBlock {
            for activity in Activity<ShiriActivityAttributes>.activities where activity.attributes.cardID == secondID.uuidString {
                await activity.end(using: nil, dismissalPolicy: .immediate)
            }
        }
        library = try await repo.library()
        try await service.activateSavedCard(second, library: library, privacy: .hidden, now: now)
        XCTAssertTrue(Activity<ShiriActivityAttributes>.activities.contains { $0.id == activity.id && $0.activityState == .active })
        XCTAssertTrue(Activity<ShiriActivityAttributes>.activities.contains { $0.attributes.cardID == secondID.uuidString })
        first.reminders.enablesLiveActivity = false
        _ = try await CardCommands(repository: repo).save(CardDraft(card: first, isEditing: true), now: now)
        library = try await repo.library()
        await service.reconcile(library: library, privacy: .hidden, now: now)
        XCTAssertFalse(Activity<ShiriActivityAttributes>.activities.contains { $0.id == activity.id && $0.activityState == .active })
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: second, at: now))
        try await CardCommands(repository: repo).stopReminder(occurrence, now: now)
        library = try await repo.library()
        await service.reconcile(library: library, privacy: .hidden, now: now)
        try await service.activateSavedCard(second, library: library, privacy: .hidden, now: now)
        XCTAssertFalse(Activity<ShiriActivityAttributes>.activities.contains { $0.attributes.cardID == secondID.uuidString && $0.activityState == .active })
        XCTAssertEqual(EventReducer.state(events: library.events(for: occurrence.id)), .pending)
    }

    @available(iOS 16.1, *)
    func testNotesPastAndDisabledCardsDoNotStartActivities() async throws {
        let repo = try await repository(), service = LiveActivityService(), now = Date()
        for variant in 0..<3 {
            var card = Card(title: "无需实时活动的卡片", kind: variant == 0 ? .note : .task, now: now)
            card.reminders.enablesLiveActivity = variant != 2
            if variant != 0 {
                let target = now.addingTimeInterval(variant == 1 ? -7200 : 86400)
                card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: .current), time: DayTime(hour: Calendar.current.component(.hour, from: target), minute: Calendar.current.component(.minute, from: target)))
            }
            card = try await CardCommands(repository: repo).save(CardDraft(card: card), now: now)
            try await service.activateSavedCard(card, library: try await repo.library(), privacy: .hidden, now: now)
            XCTAssertFalse(Activity<ShiriActivityAttributes>.activities.contains { $0.attributes.cardID == card.id.uuidString })
        }
    }

    @available(iOS 16.2, *)
    func testUndatedAndDateOnlyActivitiesSurviveReconcileAndEndOnCompletion() async throws {
        let repo = try await repository(), service = LiveActivityService(), now = Date()
        for dateOnly in [false, true] {
            var card = Card(title: "收拾一下书桌", now: now)
            if dateOnly { card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: .current), time: nil) }
            card.reminders.enablesLiveActivity = true
            card.reminders.scheduledLiveActivity = true
            card = try await CardCommands(repository: repo).save(CardDraft(card: card), now: now)
            let id = card.id
            addTeardownBlock {
                for activity in Activity<ShiriActivityAttributes>.activities where activity.attributes.cardID == id.uuidString {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            try await service.activateSavedCard(card, library: try await repo.library(), privacy: .hidden, now: now)
            let live = try XCTUnwrap(Activity<ShiriActivityAttributes>.activities.first { $0.attributes.cardID == id.uuidString })
            XCTAssertEqual(live.activityState, .active)
            XCTAssertEqual(live.content.state.title, "有一件事等你处理")
            XCTAssertEqual(live.content.state.isDateOnly, true)
            XCTAssertEqual(live.content.state.targetDate == nil, !dateOnly)
            await service.reconcile(library: try await repo.library(), privacy: .hidden, now: now)
            XCTAssertTrue(Activity<ShiriActivityAttributes>.activities.contains { $0.id == live.id && $0.activityState == .active })
            let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: .current).relevantOccurrence(for: card, at: now))
            try await CardCommands(repository: repo).complete(occurrence, now: now)
            await service.reconcile(library: try await repo.library(), privacy: .hidden, now: now)
            await service.reconcile(library: try await repo.library(), privacy: .hidden, now: now)
            XCTAssertFalse(Activity<ShiriActivityAttributes>.activities.contains { $0.id == live.id && $0.activityState == .active })
        }
    }

    @available(iOS 16.2, *)
    func testShowNowEnablesExistingTimedCardAndPreservesStoppedReminder() async throws {
        let repo = try await repository(), model = AppModel(), now = Date(), calendar = Calendar.current
        model.prepareRefreshForTesting(repository: repo, effect: {})
        addTeardownBlock { try await model.finishRefreshForTesting() }
        let target = now.addingTimeInterval(1800)
        var card = Card(title: "原来的定时待办", now: now)
        card.note = "保留原内容与通知设置"
        card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: calendar), time: DayTime(hour: calendar.component(.hour, from: target), minute: calendar.component(.minute, from: target)))
        card = try await CardCommands(repository: repo).save(CardDraft(card: card), now: now)
        let id = card.id
        addTeardownBlock {
            for activity in Activity<ShiriActivityAttributes>.activities where activity.attributes.cardID == id.uuidString {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        XCTAssertFalse(card.reminders.enablesLiveActivity)
        try await model.showLiveActivityNow(cardID: id)
        try await model.showLiveActivityNow(cardID: id)
        let library = try await repo.library(), saved = try XCTUnwrap(library.cards.first)
        XCTAssertEqual(saved.title, card.title); XCTAssertEqual(saved.note, card.note); XCTAssertEqual(saved.schedule, card.schedule)
        XCTAssertFalse(saved.reminders.isEnabled); XCTAssertTrue(saved.reminders.enablesLiveActivity); XCTAssertFalse(saved.reminders.scheduledLiveActivity)
        let active = Activity<ShiriActivityAttributes>.activities.filter { $0.attributes.cardID == id.uuidString && $0.activityState == .active }
        XCTAssertEqual(active.count, 1)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: saved, at: now))
        XCTAssertTrue(model.liveActivities.status(for: CardProjection(card: saved, occurrence: occurrence)).contains("已开启"))
        try await CardCommands(repository: repo).stopReminder(occurrence, now: now)
        await model.liveActivities.reconcile(library: try await repo.library(), privacy: .full, now: now)
        do { try await model.showLiveActivityNow(cardID: id); XCTFail("A stopped reminder must not silently restart") }
        catch { XCTAssertTrue(error.localizedDescription.contains("停止"), error.localizedDescription) }
        let stoppedLibrary = try await repo.library()
        XCTAssertTrue(stoppedLibrary.personalStates[occurrence.id]?.isStopped == true)
        XCTAssertFalse(Activity<ShiriActivityAttributes>.activities.contains { $0.attributes.cardID == id.uuidString && $0.activityState == .active })
    }

    @available(iOS 16.1, *)
    func testOldTimedActivityContentStillDecodes() throws {
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: ["title": "旧版活动", "targetDate": target.timeIntervalSinceReferenceDate, "isHidden": false])
        let state = try JSONDecoder().decode(ShiriActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(state.targetDate, target); XCTAssertNil(state.isDateOnly)
    }

    @available(iOS 26.0, *)
    func testScheduledActivityUsesPendingAndNearDueActivityStartsImmediately() async throws {
        let repo = try await repository(), service = LiveActivityService()
        let now = Date(), calendar = Calendar.current
        var cards: [Card] = []
        for seconds in [7200.0, 120.0] {
            let target = now.addingTimeInterval(seconds)
            var card = Card(title: "预约显示验证", now: now)
            card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: calendar), time: DayTime(hour: calendar.component(.hour, from: target), minute: calendar.component(.minute, from: target)))
            card.reminders.enablesLiveActivity = true; card.reminders.scheduledLiveActivity = true
            card = try await CardCommands(repository: repo).save(CardDraft(card: card), now: now)
            cards.append(card)
            let cardID = card.id
            addTeardownBlock {
                for activity in Activity<ShiriActivityAttributes>.activities where activity.attributes.cardID == cardID.uuidString {
                    await activity.end(using: nil, dismissalPolicy: .immediate)
                }
            }
            try await service.activateSavedCard(card, library: try await repo.library(), privacy: .hidden, now: now)
        }
        let later = try XCTUnwrap(Activity<ShiriActivityAttributes>.activities.first { $0.attributes.cardID == cards[0].id.uuidString })
        let near = try XCTUnwrap(Activity<ShiriActivityAttributes>.activities.first { $0.attributes.cardID == cards[1].id.uuidString })
        XCTAssertEqual(later.activityState, .pending)
        XCTAssertEqual(near.activityState, .active)
        try await service.activateSavedCard(cards[0], library: try await repo.library(), privacy: .hidden, now: now)
        XCTAssertEqual(Activity<ShiriActivityAttributes>.activities.filter { $0.attributes.cardID == cards[0].id.uuidString }.count, 1)
        cards[0].reminders.scheduledLiveActivity = false
        try await service.activateSavedCard(cards[0], library: try await repo.library(), privacy: .hidden, now: now)
        XCTAssertTrue(Activity<ShiriActivityAttributes>.activities.contains { $0.attributes.cardID == cards[0].id.uuidString && $0.activityState == .active })
        cards[0].reminders.scheduledLiveActivity = true
        try await service.activateSavedCard(cards[0], library: try await repo.library(), privacy: .hidden, now: now)
        let pending = try XCTUnwrap(Activity<ShiriActivityAttributes>.activities.first { $0.attributes.cardID == cards[0].id.uuidString })
        XCTAssertEqual(pending.activityState, .pending)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: cards[0], at: now))
        let moved = now.addingTimeInterval(10800)
        try await CardCommands(repository: repo).rescheduleOccurrence(occurrence, to: moved, now: now)
        let failures = await service.reconcile(library: try await repo.library(), privacy: .hidden, now: now)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let rescheduled = try XCTUnwrap(Activity<ShiriActivityAttributes>.activities.first { $0.attributes.cardID == cards[0].id.uuidString })
        XCTAssertNotEqual(rescheduled.id, pending.id)
        XCTAssertEqual(rescheduled.contentState.targetDate, moved)
        XCTAssertEqual(rescheduled.activityState, .pending)
    }
    private func repository() async throws -> ShiriRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriNativeTests-" + UUID().uuidString)
        let persistence = try await PersistenceController.open(PersistenceConfiguration(directory: directory))
        addTeardownBlock {
            try await persistence.detachStores()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        return ShiriRepository(persistence: persistence,actorID: "native-tests")
    }
    @available(iOS 26.0, *)
    func testAlarmRegistrationAndStopKeepTaskPending() async throws {
        try await AlarmAdapter.requestPermission()
        XCTAssertTrue(AlarmAdapter.allowed)
        let repo = try await repository(); let now = Date(); let calendar = Calendar.current; let target = now.addingTimeInterval(900)
        var card = Card(title: "闹钟登记验证",now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(target,calendar: calendar),time: DayTime(hour: calendar.component(.hour,from: target),minute: calendar.component(.minute,from: target)))
        card.reminders.isEnabled = true; card.reminders.channel = .alarm
        card = try await CardCommands(repository: repo).save(CardDraft(card: card),now: now)
        var library = try await repo.library()
        let desired = ReminderPlanner(calendar: calendar).plan(library: library,preferences: AppPreferences(),now: now,capabilities: ReminderCapabilities(notificationsAllowed: false,alarmAllowed: true))
        let ledger = try await AlarmAdapter.reconcile(desired,repository: repo,now: now)
        let entry = try XCTUnwrap(ledger.first); XCTAssertEqual(entry.status,.registered)
        let id = StableID.uuid(entry.id)
        defer { try? AlarmManager.shared.cancel(id: id) }
        XCTAssertTrue(try AlarmManager.shared.alarms.contains { $0.id == id })
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card,at: now))
        try await CardCommands(repository: repo).stopReminder(occurrence,now: now,alarmOnly: true)
        library = try await repo.library()
        XCTAssertEqual(EventReducer.state(events: library.events(for: occurrence.id)),.pending)
        let stopped = ReminderPlanner(calendar: calendar).plan(library: library,preferences: AppPreferences(),now: now,capabilities: ReminderCapabilities(notificationsAllowed: false,alarmAllowed: true))
        _ = try await AlarmAdapter.reconcile(stopped,repository: repo,now: now)
        XCTAssertFalse(try AlarmManager.shared.alarms.contains { $0.id == id })
    }
    @available(iOS 16.1, *)
    func testLiveActivityEndsAfterCompletionAndDoesNotRecreateOnReconcile() async throws {
        let repo = try await repository(); let now = Date(); let calendar = Calendar.current; let target = now.addingTimeInterval(900)
        var card = Card(title: "实时活动验证",now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(target,calendar: calendar),time: DayTime(hour: calendar.component(.hour,from: target),minute: calendar.component(.minute,from: target)))
        card.reminders.isEnabled = true; card.reminders.enablesLiveActivity = true
        card = try await CardCommands(repository: repo).save(CardDraft(card: card),now: now)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card,at: now))
        let service = LiveActivityService()
        try await service.start(CardProjection(card: card,occurrence: occurrence),privacy: .hidden,scheduled: false,now: now)
        let live = try XCTUnwrap(Activity<ShiriActivityAttributes>.activities.first { $0.attributes.cardID == card.id.uuidString })
        XCTAssertEqual(live.contentState.title,"有一件事等你处理")
        try await CardCommands(repository: repo).complete(occurrence,now: now)
        let library = try await repo.library()
        await service.reconcile(library: library,privacy: .hidden,now: now)
        await service.reconcile(library: library,privacy: .hidden,now: now)
        XCTAssertFalse(Activity<ShiriActivityAttributes>.activities.contains { $0.id == live.id && $0.activityState == .active })
    }
    func testNotificationReconciliationRegistersAndCancelsCompletedOccurrence() async throws {
        let center = UNUserNotificationCenter.current()
        let authorized = try await center.requestAuthorization(options: [.alert,.sound,.badge])
        XCTAssertTrue(authorized,"Allow notifications for the isolated Shiri simulator application")
        let repo = try await repository(); let now = Date(); let calendar = Calendar.current
        let target = now.addingTimeInterval(300)
        var card = Card(title: "原生通知登记验证",now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(target,calendar: calendar),time: DayTime(hour: calendar.component(.hour,from: target),minute: calendar.component(.minute,from: target)))
        card.reminders.isEnabled = true
        card = try await CardCommands(repository: repo).save(CardDraft(card: card),now: now)
        var library = try await repo.library()
        let desired = ReminderPlanner(calendar: calendar).plan(library: library,preferences: AppPreferences(),now: now,capabilities: ReminderCapabilities(notificationsAllowed: authorized))
        let ledger = try await NotificationAdapter.shared.reconcile(desired,library: library,repository: repo,now: now)
        XCTAssertTrue(ledger.contains { $0.status == .registered })
        let ids = Set(ledger.map(\.id))
        let pending = await center.pendingNotificationRequests()
        XCTAssertTrue(pending.contains { ids.contains($0.identifier) })
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card,at: now))
        try await CardCommands(repository: repo).complete(occurrence,now: now)
        library = try await repo.library()
        let finished = ReminderPlanner(calendar: calendar).plan(library: library,preferences: AppPreferences(),now: now,capabilities: ReminderCapabilities(notificationsAllowed: authorized))
        _ = try await NotificationAdapter.shared.reconcile(finished,library: library,repository: repo,now: now)
        let after = await center.pendingNotificationRequests()
        XCTAssertFalse(after.contains { ids.contains($0.identifier) })
    }
    func testSixLargeImagesAndSmallImageNormalizeWithoutLocationMetadata() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4000,height: 3000),format: format)
        let image = renderer.image { context in UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0,y: 0,width: 4000,height: 3000)) }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 1))
        let cardID = UUID()
        for index in 0..<6 {
            let normalized = try autoreleasepool { try PhotoProcessor.prepare(data,cardID: cardID,index: index) }
            XCTAssertLessThanOrEqual(normalized.data.count,AppLimits.attachmentBytes)
            XCTAssertLessThanOrEqual(max(normalized.width,normalized.height),2048)
            try normalized.validate()
            let source = try XCTUnwrap(CGImageSourceCreateWithData(normalized.data as CFData,nil))
            let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
            XCTAssertNil(metadata[kCGImagePropertyGPSDictionary as String])
        }
        let small = UIGraphicsImageRenderer(size: CGSize(width: 16,height: 16),format: format).image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0,y: 0,width: 16,height: 16)) }
        let normalized = try PhotoProcessor.prepare(try XCTUnwrap(small.pngData()),cardID: cardID,index: 0)
        XCTAssertEqual(normalized.width,16); XCTAssertEqual(normalized.height,16)
    }
}

@MainActor
private final class RefreshTestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class AppRefreshTests: XCTestCase {
    private func repository(for model: AppModel) async throws -> ShiriRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriRefreshTests-" + UUID().uuidString)
        let persistence = try await PersistenceController.open(PersistenceConfiguration(directory: directory))
        addTeardownBlock {
            try await model.finishRefreshForTesting()
            try await persistence.detachStores()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        return ShiriRepository(persistence: persistence, actorID: "refresh-main")
    }
    func testRefreshReturnsAfterOwnLedgerWriteAndStillAppliesExternalHistory() async throws {
        let model = AppModel(), returned = expectation(description: "User refresh returns")
        let repository = try await self.repository(for: model)
        let externalCard = Card(title: "组件写入仍会出现", now: Date())
        let externalApplied = expectation(description: "Later external history updates the visible library")
        var reportedExternal = false
        let remainsQuiet = expectation(description: "Self-authored ledger notifications do not start another reconciliation")
        remainsQuiet.isInverted = true
        var verifyingQuiet = false
        model.prepareRefreshForTesting(repository: repository) {
            if verifyingQuiet { verifyingQuiet = false; remainsQuiet.fulfill() }
            // Real same-author device writes reproduce notification/alarm ledger reconciliation.
            try await repository.setDeviceValue(UUID().uuidString, key: "notification-ledger-test")
            await model.receiveStoreChangeForTesting()
            if model.library.cards.contains(where: { $0.id == externalCard.id }), !reportedExternal {
                reportedExternal = true; externalApplied.fulfill()
            }
        }
        Task { await model.refresh(); returned.fulfill() }
        await fulfillment(of: [returned], timeout: 3)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.completedRefreshPassesForTesting, 1, "Our ledger writes must not create a self-sustaining reconciliation loop")
        let widget = ShiriRepository(persistence: repository.persistence, actorID: "widget")
        _ = try await CardCommands(repository: widget).save(CardDraft(card: externalCard), now: Date())
        await model.receiveStoreChangeForTesting()
        await fulfillment(of: [externalApplied], timeout: 3)
        XCTAssertEqual(model.library.cards.map(\.id), [externalCard.id])
        // save commits the card and its confirmed snapshot to different stores. They may
        // correctly arrive in separate external-history batches. A user-requested pass after
        // save has returned is a barrier that consumes both, without assuming a batch count.
        let barrierReturned = expectation(description: "Refresh after all external save transactions returns")
        Task { await model.refresh(); barrierReturned.fulfill() }
        await fulfillment(of: [barrierReturned], timeout: 3)
        let settledPassCount = model.completedRefreshPassesForTesting
        verifyingQuiet = true
        try await repository.setDeviceValue(UUID().uuidString, key: "notification-ledger-test")
        for _ in 0..<3 { await model.receiveStoreChangeForTesting() }
        await fulfillment(of: [remainsQuiet], timeout: 0.4)
        XCTAssertEqual(model.completedRefreshPassesForTesting, settledPassCount, "After external history drains, self-authored writes and repeated notifications must add zero refresh passes")
    }
    func testEarlierRefreshCallerReturnsWhileLaterRequestedPassIsStillRunning() async throws {
        let model = AppModel(), repository = try await self.repository(for: model)
        let firstGate = RefreshTestGate(), secondGate = RefreshTestGate()
        addTeardownBlock { await firstGate.release(); await secondGate.release() }
        let firstStarted = expectation(description: "First pass began")
        let secondQueued = expectation(description: "Second user refresh requested")
        let secondStarted = expectation(description: "Second pass began")
        let firstReturned = expectation(description: "First caller can dismiss its sheet")
        let secondReturned = expectation(description: "Second caller sees its own completed pass")
        var pass = 0
        model.prepareRefreshForTesting(repository: repository) {
            pass += 1
            if pass == 1 { firstStarted.fulfill(); await firstGate.wait() }
            else if pass == 2 { secondStarted.fulfill(); await secondGate.wait() }
        }
        Task { await model.refresh(); firstReturned.fulfill() }
        await fulfillment(of: [firstStarted], timeout: 3)
        Task { secondQueued.fulfill(); await model.refresh(); secondReturned.fulfill() }
        await fulfillment(of: [secondQueued], timeout: 3)
        firstGate.release()
        await fulfillment(of: [firstReturned, secondStarted], timeout: 3)
        XCTAssertEqual(model.completedRefreshPassesForTesting, 1, "The first caller must return even while a later pass remains suspended")
        secondGate.release()
        await fulfillment(of: [secondReturned], timeout: 3)
        XCTAssertEqual(model.completedRefreshPassesForTesting, 2)
    }
    func testStartupCleanupWaitsForInFlightRefreshThenReturns() async throws {
        let model = AppModel(), repository = try await self.repository(for: model)
        let gate = RefreshTestGate()
        addTeardownBlock { await gate.release() }
        let passStarted = expectation(description: "Refresh is reading the current store")
        let refreshed = expectation(description: "Refresh caller is released")
        let cleanupFinished = expectation(description: "Cleanup waits until the refresh finishes")
        var didCleanUp = false
        model.prepareRefreshForTesting(repository: repository) { passStarted.fulfill(); await gate.wait() }
        Task { await model.refresh(); refreshed.fulfill() }
        await fulfillment(of: [passStarted], timeout: 3)
        Task {
            do { try await model.finishRefreshForTesting(); didCleanUp = true; cleanupFinished.fulfill() }
            catch { XCTFail(error.localizedDescription); cleanupFinished.fulfill() }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(didCleanUp, "A store must not detach while a refresh still uses it")
        gate.release()
        await fulfillment(of: [refreshed, cleanupFinished], timeout: 3)
        XCTAssertTrue(didCleanUp)
        XCTAssertNil(model.repository)
    }
}

@MainActor
final class ExperienceNativeTests: XCTestCase {
    func testDeviceTextRecognitionReadsChineseDateAndRejectsBlankImage() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 700), format: format)
        let source = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
            ("预约名称：去看展\n2026-10-20 15:00\n地点：城市美术馆" as NSString).draw(in: CGRect(x: 50, y: 70, width: 900, height: 520), withAttributes: [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.black])
        }
        let recognized = try ScreenshotRecognition.recognize(XCTUnwrap(source.pngData()))
        XCTAssertTrue(recognized.text.contains("去看展"), recognized.text)
        XCTAssertTrue(recognized.text.contains("2026"), recognized.text)
        XCTAssertTrue(recognized.text.contains("15:00"), recognized.text)
        let blank = renderer.image { context in UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 700)) }
        XCTAssertThrowsError(try ScreenshotRecognition.recognize(XCTUnwrap(blank.pngData())))
    }
    func testCardStatusDistinguishesPermissionLedgerFailureCapacityAndHandledState() {
        let model = AppModel(), now = Date(), calendar = Calendar.current
        let future = now.addingTimeInterval(3600)
        var card = Card(title: "登记状态验证", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(future, calendar: calendar), time: DayTime(hour: calendar.component(.hour, from: future), minute: calendar.component(.minute, from: future)))
        card.reminders.isEnabled = true
        let occurrence = OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card, at: now)
        let projection = CardProjection(card: card, occurrence: occurrence)
        model.systemCapabilities.notifications = .denied
        XCTAssertTrue(model.reminderStatus(for: projection).needsAttention)
        XCTAssertFalse(model.reminderStatus(for: projection).text.hasPrefix("已安排"))
        model.systemCapabilities.notifications = .ready
        var library = LibrarySnapshot(); library.cards = [card]
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: true))
        guard let request = plan.requests.first else { return XCTFail("Future notification must have a plan") }
        model.reminderLedger = [ReminderLedgerEntry(request: request, status: .registered, now: now)]
        XCTAssertTrue(model.reminderStatus(for: projection).text.hasPrefix("已安排"))
        model.reminderLedger = [ReminderLedgerEntry(request: request, status: .failed, message: "登记失败，请重试", now: now)]
        XCTAssertEqual(model.reminderStatus(for: projection).text, "登记失败，请重试")
        model.reminderIssues = [SchedulingIssue(cardID: card.id, message: "提醒容量暂满")]
        XCTAssertEqual(model.reminderStatus(for: projection).text, "提醒容量暂满")
        var archived = card; archived.lifecycle = .archived
        XCTAssertEqual(model.reminderStatus(for: CardProjection(card: archived, occurrence: occurrence)).text, "提醒已停止")
        var handled = projection; handled.state = .completed
        XCTAssertEqual(model.reminderStatus(for: handled).text, "这一次已处理")
    }
}

@MainActor
final class WidgetVoiceRoutingTests: XCTestCase {
    func testVoiceIntentDeliversForegroundRequestWithoutOpeningAStore() async throws {
        var received: [ComposerInputMode] = []
        let subscription = ComposerIntentRouter.shared.$request.sink { if let request = $0 { received.append(request.mode) } }
        defer {
            subscription.cancel()
            if let request = ComposerIntentRouter.shared.request { ComposerIntentRouter.shared.consume(request.id) }
        }
        _ = try await OpenVoiceComposerIntent().perform()
        XCTAssertEqual(received.last, .voice)
        XCTAssertTrue(OpenVoiceComposerIntent.openAppWhenRun)
        _ = try await OpenComposerIntent().perform()
        XCTAssertEqual(received.last, .text)
    }
    func testColdLaunchWaitsForStoreAndCoalescesRepeatedVoiceRequests() {
        let model = AppModel()
        model.requestComposer(.voice)
        XCTAssertNil(model.composer)
        XCTAssertEqual(model.pendingComposerInput, .voice)
        model.isLoading = false; model.presentPendingComposer()
        XCTAssertEqual(model.composer?.card.kind, .task)
        XCTAssertTrue(model.startsWithSpeech)
        let id = model.composer?.card.id
        model.startsWithSpeech = false
        model.requestComposer(.voice)
        XCTAssertEqual(model.composer?.card.id, id)
        XCTAssertNil(model.pendingComposerInput)
        XCTAssertTrue(model.library.cards.isEmpty, "Opening a voice entry must not create a saved card")
    }
    func testExternalVoiceRequestPreservesAnExistingDraftAndCanBeCancelled() {
        let model = AppModel(); model.isLoading = false
        model.create(kind: .note)
        model.composer?.card.title = "尚未保存的输入"
        let original = model.composer
        model.requestComposer(.voice)
        XCTAssertEqual(model.composer, original)
        XCTAssertEqual(model.pendingComposerInput, .voice)
        model.cancelPendingComposer()
        model.composer = nil; model.presentPendingComposer()
        XCTAssertNil(model.composer)
        model.composer = original
        model.requestComposer(.voice)
        model.composer = nil; model.presentPendingComposer()
        XCTAssertNotEqual(model.composer?.card.id, original?.card.id)
        XCTAssertEqual(model.composer?.card.kind, .task)
        XCTAssertTrue(model.startsWithSpeech)
    }
    func testVoiceDeepLinkAndRecoveryDoNotBypassLoadingOrOverwriteInput() async {
        XCTAssertEqual(ComposerInputMode.from(ComposerInputMode.voiceURL), .voice)
        XCTAssertEqual(ComposerInputMode.from(URL(string: "nianyi://compose")!), .text)
        XCTAssertNil(ComposerInputMode.from(URL(string: "https://example.com/compose?input=voice")!))
        let model = AppModel(); model.isLoading = false; model.fatalError = "等待重试"
        await model.openFile(ComposerInputMode.voiceURL)
        XCTAssertNil(model.composer)
        model.fatalError = nil; model.presentPendingComposer()
        XCTAssertTrue(model.startsWithSpeech)
        XCTAssertEqual(model.composer?.card.kind, .task)
    }
}

@MainActor
final class StandardDatasetPerformanceTests: XCTestCase {
    func testDocumentedDatasetReadSearchSaveAndReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriStandardPerformance-" + UUID().uuidString)
        let persistence = try await PersistenceController.open(PersistenceConfiguration(directory: directory))
        addTeardownBlock { try await persistence.detachStores(); try FileManager.default.removeItem(at: directory) }
        let repo = ShiriRepository(persistence: persistence, actorID: "standard-performance")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10))!
        try await DevelopmentFixtures.seedStandardPerformance(repository: repo, now: now, calendar: calendar)
        var readMS: [Double] = [], saveMS: [Double] = [], searchMS: [Double] = []
        var snapshot = LibrarySnapshot()
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            snapshot = try await repo.library()
            readMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        XCTAssertEqual(snapshot.cards.count, 10_000); XCTAssertEqual(snapshot.events.count, 50_000)
        var edited = try XCTUnwrap(snapshot.cards.first { $0.title == "生活事项 0000" })
        for index in 0..<20 {
            edited.note = "本地保存响应验证 \(index)"
            let start = ProcessInfo.processInfo.systemUptime
            edited = try await CardCommands(repository: repo).save(CardDraft(card: edited, isEditing: true), now: now.addingTimeInterval(Double(index)))
            saveMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            let ids = try await repo.searchCardIDs("银杏雨", limit: 100)
            searchMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(ids.count, 1)
        }
        let interval = calendar.dateInterval(of: .year, for: now)!
        let reviewInput = snapshot, reviewCalendar = calendar
        let start = ProcessInfo.processInfo.systemUptime
        let review = await Task.detached { ReviewCalculator.summarize(library: reviewInput, interval: interval, calendar: reviewCalendar, now: now, period: .year) }.value
        let reviewMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(review.completed.count, 10_000)
        let after = try await repo.library()
        XCTAssertEqual(after.cards.count, 10_000); XCTAssertEqual(after.events.count, 50_000)
        XCTAssertEqual(after.cards.first { $0.id == edited.id }?.note, "本地保存响应验证 19")
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        let report: [String: Any] = ["cards": 10_000, "events": 50_000, "activeCards": 1000,
            "build": _isDebugAssertConfiguration() ? "Debug iOS Simulator" : "Optimized iOS Simulator (-O, isolated DEBUG fixtures)", "fullLibraryReadMS": readMS,
            "localSaveMS": saveMS, "localSaveP95MS": p95(saveMS), "searchMS": searchMS,
            "searchP95MS": p95(searchMS), "annualReviewMS": reviewMS,
            "notes": "Reads are not cold launch. Save covers durable CardCommands storage, excluding later system reminder reconciliation."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "standard-dataset-performance.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("NIANYI_STANDARD_METRICS " + String(decoding: data, as: UTF8.self))
        XCTAssertLessThan(p95(saveMS), 300, "Documented local-save budget, excluding media and permissions")
        XCTAssertLessThan(p95(searchMS), 300, "Documented limited repository-search budget")
    }
}

@MainActor
final class MemoryRenderingTests: XCTestCase {
    func testBookletKeepsLongTextAllPhotosAndEveryStyleReadable() throws {
        let now = Date()
        var card = Card(title: String(repeating: "值得记住的小事", count: 12), kind: .note, now: now)
        card.memoryDate = now; card.memory = MemoryMetadata(sourceCardID: UUID(), sourceTitle: "来源私密安排")
        card.note = String(repeating: "那天一起走过山间的小路，看云慢慢散开。", count: 90) + "回忆正文最后一句"
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var photos: [Attachment] = []
        for index in 0..<6 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { context in
                UIColor(hue: CGFloat(index) / 6, saturation: 0.5, brightness: 0.8, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            }
            photos.append(Attachment(cardID: card.id, data: try XCTUnwrap(image.jpegData(compressionQuality: 0.8)), width: 600, height: 400, sortIndex: index))
        }
        card.attachmentIDs = photos.map(\.id)
        for style in MemoryExportStyle.allCases {
            let pdf = try MemoryBookRenderer.render(cards: [card], photos: [card.id: photos], includesNotes: true, title: "一段可以慢慢翻看的日子", style: style, coverID: photos.last?.id)
            XCTAssertGreaterThan(MemoryBookRenderer.pageCount(pdf), 4)
            for page in 1...MemoryBookRenderer.pageCount(pdf) { XCTAssertNotNil(MemoryBookRenderer.preview(pdf, page: page)) }
            let document = try XCTUnwrap(PDFDocument(data: pdf))
            let text = try XCTUnwrap(document.string)
            let evidence = XCTAttachment(data: pdf, uniformTypeIdentifier: "com.adobe.pdf"); evidence.name = "回忆小册子-" + style.rawValue; evidence.lifetime = .keepAlways; add(evidence)
            XCTAssertTrue(text.filter { !$0.isWhitespace }.contains("回忆正文最后一句"), "Long text must reach the final page across line breaks: " + style.rawValue)
            XCTAssertTrue(text.contains("6 / 6"), "All six photos must be included")
            XCTAssertFalse(text.contains("来源私密安排"))
            XCTAssertFalse(text.contains(card.memory!.sourceCardID!.uuidString))
        }
    }
    func testSingleMemoryImageHasNoBookCoverAndFitsTitleOnlyContent() throws {
        var card = Card(title: "今天的日落", kind: .note, now: Date()); card.memory = MemoryMetadata(); card.memoryDate = Date()
        card.note = "没有选择时不能出现的正文"
        let data = try MemoryBookRenderer.render(cards: [card], photos: [:], includesNotes: false, title: "不应出现的册子封面", style: .paper, coverID: nil, includesCover: false, compact: true)
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(document.pageCount, 1); XCTAssertEqual(page.bounds(for: .mediaBox).height, 420)
        let text = document.string ?? ""
        XCTAssertTrue(text.contains(card.title)); XCTAssertFalse(text.contains(card.note)); XCTAssertFalse(text.contains("不应出现的册子封面"))
        let preview = try XCTUnwrap(MemoryBookRenderer.preview(data, page: 1))
        XCTAssertEqual(preview.size.width / preview.size.height, page.bounds(for: .mediaBox).width / 420, accuracy: 0.01)
        let attachment = XCTAttachment(image: preview); attachment.name = "单篇图片_仅标题_紧凑预览"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDefaultBookletOmitsPrivateBodyAndProvidesValidCoverPreview() throws {
        var card = Card(title: "一张照片里的日子", kind: .note, now: Date()); card.memoryDate = Date(); card.memory = MemoryMetadata()
        card.note = "未经选择不得导出的私密正文"
        let pdf = try MemoryBookRenderer.render(cards: [card], photos: [:], includesNotes: false, title: "我的回忆", style: .paper, coverID: nil)
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertFalse(document.string?.contains(card.note) == true)
        XCTAssertNotNil(MemoryBookRenderer.preview(pdf, page: 1)); XCTAssertNil(MemoryBookRenderer.preview(pdf, page: 3))
    }
}


@MainActor
final class MemoryEditorPersistenceTests: XCTestCase {
    private func setupModel() async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriMemoryEditor-" + UUID().uuidString)
        let persistence = try await PersistenceController.open(PersistenceConfiguration(directory: directory))
        let model = AppModel(), repo = ShiriRepository(persistence: persistence, actorID: "memory-editor-tests")
        model.prepareRefreshForTesting(repository: repo, effect: {})
        await model.refresh()
        addTeardownBlock { try await model.finishRefreshForTesting(); try await persistence.detachStores(); try FileManager.default.removeItem(at: directory) }
        return model
    }
    private func editor(_ model: AppModel, editing: Card? = nil) async -> MemoryEditorState {
        let editor = MemoryEditorState()
        await editor.load(model: model, initialDate: model.now, occasionID: nil, source: nil, editing: editing, previous: nil, restoring: nil)
        XCTAssertTrue(editor.initialized); return editor
    }
    func testAutosaveRecoversNarrativeAndOldDateThenSaveDoesNotResurrectDraft() async throws {
        let model = try await setupModel(), state = await editor(model), repo = try XCTUnwrap(model.repository)
        state.draft.card.note = "今天喊我吃饭的是妈妈。回忆里保留叙述"
        state.draft.card.memoryDate = model.now.addingTimeInterval(-400 * 86400)
        state.draft.memorySpeechText = "还没有加入正文的一段话"
        state.autosave(model: model)
        try await Task.sleep(nanoseconds: 550_000_000)
        let restored = await editor(model)
        XCTAssertTrue(restored.recovered); XCTAssertEqual(restored.draft.card.note, state.draft.card.note)
        XCTAssertEqual(restored.draft.card.memoryDate, state.draft.card.memoryDate)
        XCTAssertEqual(restored.draft.memorySpeechText, state.draft.memorySpeechText)
        let before = try await repo.library(); XCTAssertTrue(before.cards.isEmpty)
        restored.draft.card.note += "\n" + (restored.draft.memorySpeechText ?? ""); restored.draft.memorySpeechText = nil
        restored.autosave(model: model)
        let result = await restored.save(model: model)
        let saved = try XCTUnwrap(result)
        XCTAssertEqual(saved.memoryDate, state.draft.card.memoryDate); XCTAssertEqual(model.lastSavedMemory?.id, saved.id)
        try await Task.sleep(nanoseconds: 450_000_000)
        let drafts = try await repo.drafts(), library = try await repo.library()
        XCTAssertTrue(drafts.isEmpty); XCTAssertEqual(library.cards.count, 1)
    }
    func testDiscardDrainsPendingWriteAndLeavesSavedMemoryUntouched() async throws {
        let model = try await setupModel(), state = await editor(model), repo = try XCTUnwrap(model.repository)
        state.draft.card.note = "原来的内容"
        let result = await state.save(model: model)
        let saved = try XCTUnwrap(result)
        let editing = await editor(model, editing: saved)
        editing.draft.card.note = "尚未确认的修改"; editing.autosave(model: model, immediately: true)
        let discarded = await editing.discard(model: model); XCTAssertTrue(discarded)
        editing.autosave(model: model, immediately: true)
        try await Task.sleep(nanoseconds: 450_000_000)
        let drafts = try await repo.drafts(), library = try await repo.library()
        XCTAssertTrue(drafts.isEmpty); XCTAssertEqual(library.cards.first?.note, "原来的内容")
    }
    func testClearingAllNewContentRemovesEarlierAutosavedDraft() async throws {
        let model = try await setupModel(), state = await editor(model), repo = try XCTUnwrap(model.repository)
        state.draft.card.note = "稍后决定清空"; state.autosave(model: model, immediately: true)
        try await Task.sleep(nanoseconds: 450_000_000)
        let earlier = try await repo.drafts(); XCTAssertEqual(earlier.count, 1)
        state.draft.card.note = ""; state.autosave(model: model, immediately: true)
        try await Task.sleep(nanoseconds: 450_000_000)
        let drafts = try await repo.drafts(); XCTAssertTrue(drafts.isEmpty)
    }
    func testConcurrentEditKeepsNewRevisionAndRecoverableDraft() async throws {
        let model = try await setupModel(), state = await editor(model), repo = try XCTUnwrap(model.repository)
        state.draft.card.note = "开始的内容"
        let firstResult = await state.save(model: model)
        var saved = try XCTUnwrap(firstResult)
        let editing = await editor(model, editing: saved)
        editing.draft.card.note = "当前未保存的补写"
        saved.note = "另一处已保存的内容"
        _ = try await CardCommands(repository: repo).save(CardDraft(card: saved, isEditing: true), now: model.now)
        let result = await editing.save(model: model)
        XCTAssertNil(result); XCTAssertNotNil(editing.error)
        let library = try await repo.library(), drafts = try await repo.drafts()
        XCTAssertEqual(library.cards.first?.note, "另一处已保存的内容")
        XCTAssertEqual(drafts.first?.card.note, "当前未保存的补写"); XCTAssertEqual(drafts.first?.card.revisionID, saved.revisionID)
    }
}
