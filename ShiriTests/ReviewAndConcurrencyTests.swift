import XCTest
@testable import ShiriCore

final class ReviewAndConcurrencyTests: IsolatedStoreTestCase {
    func testWritingContextRejectsARevisionThatChangedAfterPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriSaveRevision-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "save-revision")
        let commands = CardCommands(repository: repo)
        let original = try await commands.save(CardDraft(card: Card(title: "原版本", now: date(1))), now: date(1))
        var edited = original; edited.title = "已经提交的修改"
        let current = try await commands.save(CardDraft(card: edited, isEditing: true), now: date(2))
        var prepared = original; prepared.title = "过时写入"; prepared.revisionID = UUID()
        do {
            _ = try await repo.save(prepared, parents: [original.revisionID], now: date(3), expectedRevisionIDs: [original.revisionID])
            XCTFail("The write transaction must recheck the prepared revision")
        } catch let error as ShiriError {
            guard case .conflict = error else { return XCTFail("Expected a conflict, got \(error)") }
        }
        let snapshot = try await repo.library()
        XCTAssertEqual(snapshot.cards, [current]); XCTAssertEqual(snapshot.revisions.count, 2)
    }

    func testConflictResolutionRequiresAllCurrentHeads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriResolveRevision-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "resolve-revision")
        let commands = CardCommands(repository: repo)
        let original = try await commands.save(CardDraft(card: Card(title: "原版本", now: date(1))), now: date(1))
        var first = original; first.title = "设备一"; first.revisionID = UUID()
        _ = try await repo.save(first, parents: [original.revisionID], now: date(2))
        var second = original; second.title = "设备二"; second.revisionID = UUID()
        _ = try await repo.save(second, parents: [original.revisionID], now: date(2))
        let observedHeads = [first.revisionID, second.revisionID]
        var third = original; third.title = "稍后到达的修改"; third.revisionID = UUID()
        _ = try await repo.save(third, parents: [original.revisionID], now: date(3))
        do {
            _ = try await commands.save(CardDraft(card: first, isEditing: true), now: date(4), resolvingHeads: observedHeads)
            XCTFail("Resolving two heads must not discard a third unseen edit")
        } catch let error as ShiriError {
            guard case .conflict = error else { return XCTFail("Expected a conflict, got \(error)") }
        }
        let unresolved = try await repo.library()
        XCTAssertEqual(unresolved.conflicts[original.id]?.count, 3)
        let resolved = try await commands.save(CardDraft(card: first, isEditing: true), now: date(5), resolvingHeads: observedHeads + [third.revisionID])
        let final = try await repo.library()
        XCTAssertEqual(final.cards, [resolved]); XCTAssertTrue(final.conflicts.isEmpty)
    }

    func testWidgetCompletionSupportsOldAndFarFutureSingleOccurrences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriWidgetOccurrence-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "widget-occurrence")
        let commands = CardCommands(repository: repo), now = date(5)
        for offset in [-60, 1_000] {
            let target = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now))
            var card = Card(title: "组件待办 \(offset)", now: now)
            card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: calendar), time: DayTime(hour: 9))
            card = try await commands.save(CardDraft(card: card), now: now)
            let library = try await repo.library()
            let widget = try XCTUnwrap(WidgetSnapshot.make(library: library, preferences: AppPreferences(), now: now, calendar: calendar).cards.first { $0.id == card.id })
            XCTAssertTrue(widget.canComplete)
            let occurrenceID = try XCTUnwrap(widget.occurrenceID)
            try await commands.complete(cardID: card.id, occurrenceID: occurrenceID, now: now, calendar: calendar)
            let completed = try await repo.library()
            XCTAssertEqual(EventReducer.state(events: completed.events(for: occurrenceID)), .completed)
            XCTAssertEqual(completed.occurrences.first { $0.id == occurrenceID }?.plannedAt, target)
        }
    }

    func testWidgetCompletionRejectsForeignAndChangedOccurrences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriWidgetInvalid-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "widget-invalid")
        let commands = CardCommands(repository: repo), now = date(5)
        var card = Card(title: "当前安排", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(date(6), calendar: calendar), time: DayTime(hour: 9))
        card = try await commands.save(CardDraft(card: card), now: now)
        let stale = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card, at: now))
        let other = try await commands.save(CardDraft(card: Card(title: "另一张卡片", now: now)), now: now)
        do {
            try await commands.complete(cardID: other.id, occurrenceID: stale.id, now: now, calendar: calendar)
            XCTFail("An occurrence from another card must be rejected")
        } catch { }
        card.schedule?.time = DayTime(hour: 11)
        card = try await commands.save(CardDraft(card: card, isEditing: true), now: now)
        do {
            try await commands.complete(cardID: card.id, occurrenceID: stale.id, now: now, calendar: calendar)
            XCTFail("A stale widget must not complete a replacement schedule")
        } catch { }
        let snapshot = try await repo.library()
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testStaleDraftCannotOverwriteRestoredBackupAndKeepsItsText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriStaleDraft-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "stale-draft")
        let commands = CardCommands(repository: repo)
        let original = try await commands.save(CardDraft(card: Card(title: "备份中的标题", kind: .note, now: date(1))), now: date(1))
        let backup = try await repo.exportBackup(now: date(1))
        var changed = original; changed.title = "恢复前的标题"
        let latest = try await commands.save(CardDraft(card: changed, isEditing: true), now: date(2))
        var draft = CardDraft(card: latest, isEditing: true); draft.card.note = "仍需保留的草稿文字"
        try await repo.saveDraft(draft)
        _ = try await repo.restoreBackup(backup, policy: .replaceMatching, now: date(3))
        do {
            _ = try await commands.save(draft, now: date(4))
            XCTFail("A draft from before restoration must require reconciliation")
        } catch let error as ShiriError {
            guard case .conflict = error else { return XCTFail("Expected a conflict, got \(error)") }
        }
        let snapshot = try await repo.library(), drafts = try await repo.drafts()
        XCTAssertEqual(snapshot.cards.first?.title, original.title)
        XCTAssertEqual(drafts, [draft], "Rejecting a stale draft must preserve its text")
        var fresh = CardDraft(card: try XCTUnwrap(snapshot.cards.first), isEditing: true)
        fresh.card.note = draft.card.note
        let saved = try await commands.save(fresh, now: date(5))
        XCTAssertEqual(saved.title, original.title); XCTAssertEqual(saved.note, draft.card.note)
    }

    func testStaleDraftCannotResurrectDeletedOrPurgedCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriDeletedDraft-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "deleted-draft")
        let commands = CardCommands(repository: repo)
        for purge in [false, true] {
            let card = try await commands.save(CardDraft(card: Card(title: "已删除的卡片", now: date(1))), now: date(1))
            let stale = CardDraft(card: card, isEditing: true)
            try await commands.setLifecycle(card: card, lifecycle: .deleted, now: date(2))
            if purge { try await repo.permanentlyDelete(cardID: card.id, now: date(3)) }
            do {
                _ = try await commands.save(stale, now: date(4))
                XCTFail("A stale editor must not resurrect a deleted card")
            } catch let error as ShiriError {
                guard case .conflict = error else { return XCTFail("Expected a conflict, got \(error)") }
            }
            let current = try await repo.library().cards.first { $0.id == card.id }
            if purge { XCTAssertNil(current) } else { XCTAssertEqual(current?.lifecycle, .deleted) }
        }
    }

    func testLibraryPreservesEmbeddedValuesForLegacyAndConflictingCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriCanonicalRead-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "canonical-read")
        var card = Card(title: "完整保留旧卡片", now: date(1))
        card.note = "计划、提醒和外观都保留"
        card.schedule = ScheduleDefinition(start: CivilDate(date(5), calendar: calendar), time: DayTime(hour: 9))
        card.reminders.isEnabled = true; card.appearance.customHex = "123456"
        card = try await CardCommands(repository: repo).save(CardDraft(card: card), now: date(1))
        let canonical = try await repo.library(cardID: card.id)
        XCTAssertEqual(canonical.cards, [card])
        let id = card.id, store = try repo.persistence.store(for: .local)
        try await repo.transaction { context in
            for row in try DatabaseCodec.fetch("CardRevisionRecord", context: context, stores: [store], predicate: NSPredicate(format: "cardID == %@", id as NSUUID)) { context.delete(row) }
        }
        let legacy = try await repo.library()
        XCTAssertEqual(legacy.cards, [card], "Records without revisions still decode their full schedule and appearance")
        var first = card; first.title = "设备一"; first.revisionID = UUID()
        _ = try await repo.save(first, parents: [], now: date(2))
        var second = card; second.title = "设备二"; second.revisionID = UUID()
        second = try await repo.save(second, parents: [], now: date(3))
        let confirmed = try await repo.library(cardID: id)
        XCTAssertEqual(confirmed.conflicts[id]?.count, 2); XCTAssertEqual(confirmed.cards, [card])
        try await repo.deleteDeviceRecord(entity: "DeviceValueRecord", id: "confirmed/\(id)")
        let unresolved = try await repo.library(cardID: id)
        XCTAssertEqual(unresolved.conflicts[id]?.count, 2); XCTAssertEqual(unresolved.cards, [second])
    }
    func testPayloadReadsSeeUnsavedReplacementAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriPendingRead-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "pending-read")
        try await repo.setDeviceValue("旧值", key: "pending-read")
        let store = try repo.deviceStore
        try await repo.transaction { context in
            let predicate = NSPredicate(format: "id == %@", "pending-read")
            XCTAssertEqual(try DatabaseCodec.values(String.self, entity: "DeviceValueRecord", context: context, stores: [store], predicate: predicate), ["旧值"])
            try DatabaseCodec.put("尚未提交的新值", entity: "DeviceValueRecord", id: "pending-read", context: context, store: store)
            XCTAssertEqual(try DatabaseCodec.values(String.self, entity: "DeviceValueRecord", context: context, stores: [store], predicate: predicate), ["尚未提交的新值"])
            for row in try DatabaseCodec.fetch("DeviceValueRecord", context: context, stores: [store], predicate: predicate) { context.delete(row) }
            XCTAssertTrue(try DatabaseCodec.values(String.self, entity: "DeviceValueRecord", context: context, stores: [store], predicate: predicate).isEmpty)
        }
        let deleted = try await repo.deviceValue(String.self, key: "pending-read")
        XCTAssertNil(deleted)
    }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    func date(_ day: Int, hour: Int = 9) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))! }
    func testSnapshotIgnoresFetchOrderButTracksSnoozeHistoryWithoutAStateChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriReviewRefresh-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: "review-refresh")
        let commands = CardCommands(repository: repo)
        var scheduled = Card(title: "回顾更新检查", now: date(1))
        scheduled.schedule = ScheduleDefinition(start: CivilDate(date(5), calendar: calendar), time: DayTime(hour: 9))
        scheduled = try await commands.save(CardDraft(card: scheduled), now: date(1))
        _ = try await commands.save(CardDraft(card: Card(title: "另一张卡片", now: date(2))), now: date(2))
        let original = try await repo.library()
        let unchanged = try await repo.library()
        XCTAssertEqual(original, unchanged)
        var reordered = original; reordered.cards.reverse(); reordered.revisions.reverse()
        XCTAssertEqual(original, reordered, "Identical records returned in another order must not restart review calculations")

        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: scheduled, at: date(5)))
        try await commands.snooze(occurrence, until: date(5, hour: 10), now: date(5))
        let snoozed = try await repo.library()
        XCTAssertNotEqual(original, snoozed)
        XCTAssertEqual(snoozed.personalReminderEvents.filter { $0.kind == .snoozed }.count, 1)

        let unchangedState = try XCTUnwrap(snoozed.personalStates[occurrence.id])
        let additional = PersonalReminderEvent(operationID: UUID(), occurrenceID: occurrence.id, kind: .snoozed, now: date(5), until: date(5, hour: 10))
        try await repo.savePersonalState(unchangedState, event: additional)
        let historyChanged = try await repo.library()
        XCTAssertEqual(snoozed.personalStates, historyChanged.personalStates)
        XCTAssertNotEqual(snoozed, historyChanged, "An additional snooze must refresh review even when its current reminder state is identical")
        XCTAssertEqual(historyChanged.personalReminderEvents.filter { $0.kind == .snoozed }.count, 2)
        let stable = try await repo.library()
        XCTAssertEqual(historyChanged, stable)
    }

    func testZeroDenominatorAndUndoUseRealEventsAndHistoricalCategory() throws {
        let interval = DateInterval(start: date(1,hour: 0),end: date(30,hour: 0))
        var library = LibrarySnapshot()
        XCTAssertNil(ReviewCalculator.summarize(library: library,interval: interval,calendar: calendar,now: date(29),period: .month).completionRate)
        var card = Card(title: "原来的重要事项",now: date(1)); card.category = "家庭"; card.importance = .important
        card.schedule = ScheduleDefinition(start: CivilDate(date(5),calendar: calendar),time: DayTime(hour: 9)); card.schedule?.dueAt = date(5,hour: 10)
        let occurrence = OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card,at: date(5))!
        let completed = TaskEvent(operationID: UUID(),occurrence: occurrence,actorID: "main",kind: .completed,now: date(5))
        card.category = "工作"; card.title = "新标题"
        library.cards = [card]; library.occurrences = [occurrence]; library.events = [completed]
        var review = ReviewCalculator.summarize(library: library,interval: interval,calendar: calendar,now: date(29),period: .month)
        XCTAssertEqual(review.planned.count,1); XCTAssertEqual(review.plannedCompleted,1); XCTAssertEqual(review.onTimeCompleted,1)
        XCTAssertEqual(review.categories,["家庭":1]); XCTAssertEqual(review.importantCompleted,1)
        library.events.append(TaskEvent(operationID: UUID(),occurrence: occurrence,actorID: "main",kind: .reopened,now: date(6),reverses: [completed.id]))
        review = ReviewCalculator.summarize(library: library,interval: interval,calendar: calendar,now: date(29),period: .month)
        XCTAssertEqual(review.completed.count,0); XCTAssertEqual(review.completionRate,0)
    }
    func testPastScheduleSurvivesConversionToNoteAndFutureScheduleChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriReview-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)),actorID: "review")
        let commands = CardCommands(repository: repo)
        var task = Card(title: "每日阅读",now: date(1)); task.schedule = ScheduleDefinition(start: CivilDate(date(1),calendar: calendar),time: DayTime(hour: 9),frequency: .daily)
        task = try await commands.save(CardDraft(card: task),now: date(1,hour: 8))
        task.kind = .note; task.schedule = nil
        _ = try await commands.save(CardDraft(card: task,isEditing: true),now: date(4,hour: 0))
        let library = try await repo.library()
        let review = ReviewCalculator.summarize(library: library,interval: DateInterval(start: date(1,hour: 0),end: date(8,hour: 0)),calendar: calendar,now: date(8),period: .week)
        XCTAssertEqual(review.planned.count,3)
        XCTAssertTrue(review.planned.allSatisfy { $0.plannedAt! < date(4,hour: 0) })
    }
    func testTwoIndependentContextsCompleteOnceAndUndoObservedCompletions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriConcurrent-" + UUID().uuidString)
        let first = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)),actorID: "notification")
        let second = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root,isExtension: true)),actorID: "widget")
        let card = try await CardCommands(repository: first).save(CardDraft(card: Card(title: "只计一次",now: date(5))),now: date(5))
        let occurrence = OccurrenceEngine(calendar: calendar).next(for: card,after: date(5))!
        async let a: Void = CardCommands(repository: first).complete(occurrence,now: date(5))
        async let b: Void = CardCommands(repository: second).complete(occurrence,now: date(5))
        _ = try await (a,b)
        let library = try await first.library()
        let summary = ReviewCalculator.summarize(library: library,interval: DateInterval(start: date(1),end: date(8)),calendar: calendar,now: date(8),period: .week)
        XCTAssertEqual(summary.completed.count,1); XCTAssertEqual(summary.longTermCompleted,1)
        try await CardCommands(repository: second).undo(occurrence,now: date(6))
        let after = try await first.library(); XCTAssertEqual(EventReducer.state(events: after.events),.pending)
    }
    func testSingleOccurrenceRemainsActionableAndFarFutureIsVisible() throws {
        var card = Card(title: "到期检查",now: date(1)); card.schedule = ScheduleDefinition(start: CivilDate(date(2),calendar: calendar),time: DayTime(hour: 9))
        let engine = OccurrenceEngine(calendar: calendar)
        let original = engine.next(for: card,after: date(1))!
        XCTAssertEqual(engine.relevantOccurrence(for: card,at: date(20))?.id,original.id)
        card.schedule?.start = CivilDate(year: 2040,month: 9,day: 1)
        XCTAssertEqual(engine.next(for: card,after: date(1)).map { calendar.component(.year,from: $0.plannedAt!) },2040)
    }
    func testBackupRestoresCanonicalAttachmentAndMetadataExactly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriMediaBackup-" + UUID().uuidString)
        let repo = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)),actorID: "backup")
        var draft = CardDraft(card: Card(title: "旅行的照片",kind: .note,now: date(1)))
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jSucAAAAASUVORK5CYII=")!
        let attachment = Attachment(cardID: draft.card.id,data: bytes,width: 1,height: 1,mediaType: "image/png")
        draft.attachments = [attachment]; draft.card.attachmentIDs = [attachment.id]
        _ = try await CardCommands(repository: repo).save(draft,now: date(1))
        let backup = try FileTransport.decodeBackup(FileTransport.encode(try await repo.exportBackup(now: date(2))))
        let target = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root.appendingPathComponent("Restored"))),actorID: "restored")
        _ = try await target.restoreBackup(backup,policy: .requireChoice,now: date(2))
        let result = try await target.attachments(cardID: draft.card.id)
        XCTAssertEqual(result,[attachment])
    }
}
