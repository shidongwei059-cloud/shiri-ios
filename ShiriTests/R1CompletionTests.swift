import XCTest
@testable import ShiriCore

final class R1CompletionTests: IsolatedStoreTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func date(_ day: Int, _ hour: Int = 9) -> Date { date(2026, 9, day, hour) }
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))! }
    func repository() async throws -> ShiriRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriR1-" + UUID().uuidString)
        return ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: directory)), actorID: "r1")
    }
    func testSparseMonthlyAndYearlySchedulesHaveAFutureOccurrence() {
        let engine = OccurrenceEngine(calendar: calendar)
        var card = Card(title: "长期到期检查", now: date(1))
        card.schedule = ScheduleDefinition(start: CivilDate(date(1), calendar: calendar), time: DayTime(hour: 9), frequency: .yearly)
        card.schedule?.interval = 99
        XCTAssertEqual(engine.next(for: card, after: date(2))?.plannedAt, date(2125, 9, 1))
        card.schedule?.frequency = .monthly; card.schedule?.interval = 99
        XCTAssertEqual(engine.next(for: card, after: date(2))?.plannedAt, date(2034, 12, 1))
    }
    func testOnlyThisTimeSharePreservesOverrideFixedZoneAndDeadline() throws {
        var card = Card(title: "会议", now: date(1))
        card.schedule = ScheduleDefinition(start: CivilDate(date(5), calendar: calendar), time: DayTime(hour: 9), frequency: .daily, timeZone: calendar.timeZone)
        card.schedule?.timeZoneMode = .fixed; card.schedule?.dueAt = date(5, 18)
        var occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).next(for: card, after: date(1)))
        occurrence.plannedAt = date(6, 15)
        let snapshot = SharedCardSnapshot(card: card, attachments: [], occurrence: occurrence, extent: .currentOccurrence, includeNote: false, includePhotos: false, calendar: calendar)
        XCTAssertEqual(snapshot.card.schedule?.frequency, .never)
        XCTAssertEqual(snapshot.card.schedule?.time, DayTime(hour: 15))
        XCTAssertEqual(snapshot.card.schedule?.timeZoneMode, .fixed)
        XCTAssertEqual(snapshot.card.schedule?.dueAt, date(5, 18))
        XCTAssertEqual(OccurrenceEngine(calendar: calendar).next(for: snapshot.card, after: date(1))?.plannedAt, date(6, 15))
    }
    func testBirthdayShareForCurrentOccurrenceDoesNotRepeatNextYear() throws {
        var card = Card(title: "妈妈生日", kind: .note, now: date(1))
        var birthday = BirthdayRule(name: "妈妈", calendar: .lunar, month: 8, day: 15); birthday.dayTime = DayTime(hour: 9); card.birthday = birthday
        let engine = OccurrenceEngine(calendar: calendar)
        let occurrence = try XCTUnwrap(engine.next(for: card, after: date(1)))
        let snapshot = SharedCardSnapshot(card: card, attachments: [], occurrence: occurrence, extent: .currentOccurrence, includeNote: false, includePhotos: false, calendar: calendar)
        XCTAssertFalse(try XCTUnwrap(snapshot.card.birthday?.repeatsYearly))
        let future = engine.occurrences(for: snapshot.card, in: DateInterval(start: date(1), end: date(2030, 9, 1)))
        XCTAssertEqual(future.count, 1); XCTAssertEqual(future.first?.plannedAt, occurrence.plannedAt)
    }
    func testReceiptUndoRespectsCausalityAcrossClockSkewAndInstances() {
        let session = UUID()
        let a = ReceiptEvent(operationID: UUID(), sessionID: session, semanticKey: "A", kind: .completed, now: date(10))
        let b = ReceiptEvent(operationID: UUID(), sessionID: session, semanticKey: "A", kind: .completed, now: date(1))
        let undo = ReceiptEvent(operationID: UUID(), sessionID: session, semanticKey: "A", kind: .reopened, now: date(2), reverses: [a.id])
        XCTAssertEqual(ReceiptReducer.state([undo, a, b, a], semanticKey: "A"), .completed)
        XCTAssertEqual(ReceiptReducer.state([undo, a], semanticKey: "A"), .pending)
        XCTAssertEqual(ReceiptReducer.state([undo, a], semanticKey: "B"), .unknown)
        let otherUndo = ReceiptEvent(operationID: UUID(), sessionID: session, semanticKey: "B", kind: .reopened, now: date(11), reverses: [b.id])
        XCTAssertEqual(ReceiptReducer.state([undo, a, b, otherUndo], semanticKey: "A"), .completed)
    }
    func testCloseRepeatCancelsFutureRemindersWithoutCompletingOrLosingHistory() async throws {
        let repo = try await repository(); let commands = CardCommands(repository: repo)
        var card = Card(title: "每日阅读", now: date(1))
        card.schedule = ScheduleDefinition(start: CivilDate(date(1), calendar: calendar), time: DayTime(hour: 9), frequency: .daily)
        card.reminders.isEnabled = true
        card = try await commands.save(CardDraft(card: card), now: date(1, 8))
        let first = try XCTUnwrap(OccurrenceEngine(calendar: calendar).next(for: card, after: date(1, 8)))
        try await commands.complete(first, now: date(1, 10))
        try await commands.closeSeries(card: card, now: date(2, 8))
        let library = try await repo.library()
        XCTAssertEqual(library.events.count, 1); XCTAssertEqual(library.cards.first?.lifecycle, .active)
        XCTAssertEqual(library.cards.first?.schedulingID, card.schedulingID)
        XCTAssertNil(OccurrenceEngine(calendar: calendar).next(for: library.cards[0], after: date(2, 8)))
        let plan = ReminderPlanner(calendar: calendar).plan(library: library, preferences: AppPreferences(), now: date(2, 8), capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertTrue(plan.requests.isEmpty)
        do { try await commands.snooze(first, until: date(3), now: date(2)); XCTFail("Closed series cannot be snoozed") } catch {}
        let review = ReviewCalculator.summarize(library: library, interval: DateInterval(start: date(1, 0), end: date(8, 0)), calendar: calendar, now: date(8), period: .week)
        XCTAssertEqual(review.completed.count, 1); XCTAssertEqual(review.planned.count, 1)
    }
    func testFutureEditPreservesCompletedSnapshotAndRejectsOldOverride() async throws {
        let repo = try await repository(); let commands = CardCommands(repository: repo); let engine = OccurrenceEngine(calendar: calendar)
        var card = Card(title: "旧阅读安排", now: date(1))
        card.schedule = ScheduleDefinition(start: CivilDate(date(1), calendar: calendar), time: DayTime(hour: 9), frequency: .daily)
        card = try await commands.save(CardDraft(card: card), now: date(1, 8))
        let first = try XCTUnwrap(engine.next(for: card, after: date(1, 8)))
        try await commands.complete(first, now: date(1, 10))
        let second = try XCTUnwrap(engine.next(for: card, after: date(2, 0)))
        try await commands.rescheduleOccurrence(second, to: date(4, 15), now: date(2, 0))
        var draft = CardDraft(card: card, isEditing: true); draft.editingFrom = second
        draft.card.title = "新阅读安排"; draft.card.schedule?.start = CivilDate(date(2), calendar: calendar); draft.card.schedule?.time = DayTime(hour: 15)
        let saved = try await commands.save(draft, now: date(2, 8))
        let library = try await repo.library()
        XCTAssertEqual(library.events.first?.snapshot.title, "旧阅读安排")
        let next = engine.occurrences(for: saved, in: DateInterval(start: date(2, 0), end: date(5, 0)), overrides: library.overrides)
        XCTAssertEqual(next.count, 3); XCTAssertTrue(next.allSatisfy { $0.scheduleID == saved.schedulingID })
        do { try await commands.rescheduleOccurrence(first, to: date(9), now: date(3)); XCTFail("Completed old instances cannot be moved") } catch {}
    }
    func testBackupRejectsDuplicateAndCrossOccurrenceEventsBeforeWriting() async throws {
        let repo = try await repository(); let commands = CardCommands(repository: repo)
        let card = try await commands.save(CardDraft(card: Card(title: "原内容", now: date(1))), now: date(1))
        let occurrence = Occurrence(card: card, semanticKey: "undated", plannedAt: nil)
        try await commands.complete(occurrence, now: date(2))
        let backup = try await repo.exportBackup(now: date(3))
        var payload = backup.payload; payload.events.append(payload.events[0])
        XCTAssertThrowsError(try payload.validate())
        payload = backup.payload; payload.events[0].occurrenceID = "missing-instance"
        let invalid = try BackupDocument(payload: payload, now: date(3))
        do { _ = try await repo.restoreBackup(invalid, policy: .replaceMatching, now: date(3)); XCTFail("Must reject before replacing") } catch {}
        let intact = try await repo.library(); XCTAssertEqual(intact.cards.map(\.title), ["原内容"]); XCTAssertEqual(intact.events.count, 1)
    }
    func testStoppedAndSkippedInstancesCanBeExplicitlyResumed() async throws {
        let repo = try await repository(); let commands = CardCommands(repository: repo)
        let card = try await commands.save(CardDraft(card: Card(title: "待整理", now: date(1))), now: date(1))
        let occurrence = Occurrence(card: card, semanticKey: "undated", plannedAt: nil)
        try await commands.stopReminder(occurrence, now: date(1))
        try await commands.resumeReminder(occurrence, now: date(2))
        try await commands.skip(occurrence, now: date(2))
        try await commands.unskip(occurrence, now: date(3))
        let library = try await repo.library()
        XCTAssertEqual(EventReducer.state(events: library.events), .pending)
        XCTAssertFalse(library.personalStates[occurrence.id]?.isStopped ?? true)
    }
    func testSystemBackupExclusionCoversDatabaseSidecarsAndCanBeReversed() async throws {
        let repo = try await repository()
        _ = try await CardCommands(repository: repo).save(CardDraft(card: Card(title: "本机模式", now: date(1))), now: date(1))
        try repo.setSystemBackupExcluded(true)
        var root = repo.persistence.configuration.directory
        XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isExcludedFromBackupKey]).filter { $0.lastPathComponent.contains("sqlite") }
        XCTAssertFalse(files.isEmpty)
        for file in files { XCTAssertTrue(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, file.lastPathComponent) }
        try repo.setSystemBackupExcluded(false)
        root = URL(fileURLWithPath: root.path, isDirectory: true)
        // URL resource values can remain cached within the same run-loop pass.
        // Verify the filesystem value after another URL instance changes the flag.
        root.removeAllCachedResourceValues()
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SystemBackupExcluded").path))
    }
    func testDeletingOneScopeKeepsTheOtherScopeAndItsHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriDeleteScopes-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: directory, loadsCloudStores: true)), actorID: "delete-test")
        let commands = CardCommands(repository: repo)
        let local = try await commands.save(CardDraft(card: Card(title: "本机记录", now: date(1))), now: date(1))
        var cloud = Card(title: "本人云端记录", now: date(1)); cloud.scope = .privateCloud
        cloud = try await commands.save(CardDraft(card: cloud), now: date(1))
        try await commands.complete(Occurrence(card: cloud, semanticKey: "undated", plannedAt: nil), now: date(2))
        try await repo.saveDraft(CardDraft(card: Card(title: "未保存草稿", now: date(2))))
        let deleted = try await repo.deleteAllCards(in: .local, now: date(3)); XCTAssertEqual(deleted, 1)
        let remaining = try await repo.library(); XCTAssertEqual(remaining.cards.map(\.id), [cloud.id]); XCTAssertEqual(remaining.events.count, 1)
        let drafts = try await repo.drafts(); XCTAssertTrue(drafts.isEmpty)
        XCTAssertFalse(remaining.cards.contains { $0.id == local.id })
        let cloudDeleted = try await repo.deleteAllCards(in: .privateCloud, now: date(4)); XCTAssertEqual(cloudDeleted, 1)
        let empty = try await repo.library(); XCTAssertTrue(empty.cards.isEmpty); XCTAssertTrue(empty.events.isEmpty)
    }
    func testQueuedDraftsAndInterpretationMarkerSurviveRelaunch() async throws {
        let repo = try await repository()
        var draft = CardDraft(card: Card(title: "第一件", now: date(1)), originalText: "第一件；第二件")
        draft.interpretedText = draft.originalText
        draft.additionalDrafts = [CardDraft(card: Card(title: "第二件", now: date(1)))]
        try await repo.saveDraft(draft)
        let second = ShiriRepository(persistence: try await openTestPersistence(repo.persistence.configuration), actorID: "reopened")
        let recovered = try await second.drafts()
        XCTAssertEqual(recovered, [draft]); XCTAssertEqual(recovered.first?.additionalDrafts?.first?.card.title, "第二件")
        let library = try await second.library(); XCTAssertTrue(library.cards.isEmpty)
    }

    func testRecoveringReceiptDoesNotResetItsRetryBackoff() async throws {
        let repo = try await repository()
        let receipt = ReceiptEvent(operationID: UUID(), sessionID: UUID(), semanticKey: "one", kind: .completed, now: date(1))
        try await repo.enqueue(receipt)
        var pending = ReceiptOutboxItem(receipt: receipt); pending.retryCount = 4; pending.nextAttemptAt = date(2); pending.lastError = "等待同步"
        try await repo.updateOutbox(pending)
        try await repo.enqueue(receipt)
        let result = try await repo.outbox()
        XCTAssertEqual(result, [pending])
    }

    func testRejectedScheduleEditKeepsFeedbackAndSuccessfulEditStopsItTogether() async throws {
        let repo = try await repository(); let commands = CardCommands(repository: repo)
        var card = Card(title: "朋友的重复安排", now: date(1))
        card.schedule = ScheduleDefinition(start: CivilDate(date(1), calendar: calendar), time: DayTime(hour: 9), frequency: .daily)
        let snapshot = SharedCardSnapshot(card: card, attachments: [], occurrence: nil, extent: .entireRule, includeNote: false, includePhotos: false)
        var package = SharePackage(session: ShareSession(snapshot: snapshot, recipientLabel: "朋友", feedback: true, now: date(1)))
        package.feedbackURL = URL(string: "https://www.icloud.com/share/test")
        let link = ImportLink(cardID: card.id, package: package, feedbackConsent: true, now: date(1))
        card = try await repo.save(card, parents: [], now: date(1), imported: link)
        var draft = CardDraft(card: card, isEditing: true); draft.card.title = ""; draft.card.schedule?.time = DayTime(hour: 15)
        do { _ = try await commands.save(draft, now: date(2)); XCTFail("Empty title must fail before stopping feedback") } catch {}
        let unchanged = try await repo.library(); let before = try await repo.outbox()
        XCTAssertEqual(unchanged.importLinks.first?.feedbackConsent, true); XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(unchanged.cards.first?.schedule?.time, DayTime(hour: 9))
        draft.card.title = "重新安排"
        _ = try await commands.save(draft, now: date(2))
        let changed = try await repo.library(); let after = try await repo.outbox()
        XCTAssertEqual(changed.importLinks.first?.feedbackConsent, false)
        XCTAssertEqual(changed.cards.first?.schedule?.time, DayTime(hour: 15)); XCTAssertEqual(after.map(\.receipt.kind), [.feedbackStopped])
    }

}
