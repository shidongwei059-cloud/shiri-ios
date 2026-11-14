import XCTest
import CoreData
@testable import ShiriCore

final class PersistenceAndBackupTests: IsolatedStoreTestCase {
    let now = Date(timeIntervalSince1970: 1_789_092_000)
    func repository(cloudStores: Bool = false, directory: URL? = nil) async throws -> ShiriRepository {
        let url = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShiriCoreTests-" + UUID().uuidString)
        let p = try await openTestPersistence(PersistenceConfiguration(directory: url, loadsCloudStores: cloudStores))
        return ShiriRepository(persistence: p, actorID: "integration-test")
    }
    func testLocalCardRelaunchCompletionUndoAndSnoozeDoesNotMoveDueDate() async throws {
        let repository = try await repository()
        let commands = CardCommands(repository: repository)
        var card = Card(title: "整理旅行照片", now: now)
        card.note = "保留旧照片"; card.appearance.overriddenFields = ["theme", "illustration"]
        let saved = try await commands.save(CardDraft(card: card), now: now)
        let reopened = try await self.repository(directory: repository.persistence.configuration.directory)
        let restored = try await reopened.library()
        XCTAssertEqual(restored.cards.first, saved)
        let occurrence = Occurrence(card: saved, semanticKey: "undated", plannedAt: nil)
        let op = UUID()
        try await commands.complete(occurrence, operationID: op, now: now)
        try await commands.complete(occurrence, operationID: op, now: now)
        let completed = try await repository.library()
        XCTAssertEqual(completed.events.count, 1)
        XCTAssertEqual(EventReducer.state(events: completed.events), .completed)
        do { try await commands.snooze(occurrence, until: now.addingTimeInterval(60), now: now); XCTFail("Completed occurrences must not be resurrected") } catch {}
        try await commands.undo(occurrence, now: now.addingTimeInterval(10))
        try await commands.snooze(occurrence, until: now.addingTimeInterval(600), now: now.addingTimeInterval(20))
        let final = try await repository.library()
        XCTAssertEqual(EventReducer.state(events: final.events), .pending)
        XCTAssertNil(final.cards.first?.schedule)
        XCTAssertEqual(final.personalStates[occurrence.id]?.snoozedUntil, now.addingTimeInterval(600))
    }
    func testIndependentImportDoesNotCompleteSenderOrEmitWithoutConsent() async throws {
        let repository = try await repository()
        let commands = CardCommands(repository: repository)
        let card = try await commands.save(CardDraft(card: Card(title: "周末看展", now: now)), now: now)
        let snapshot = SharedCardSnapshot(card: card, attachments: [], occurrence: nil, extent: .entireRule, includeNote: true, includePhotos: false)
        let session = ShareSession(snapshot: snapshot, recipientLabel: "朋友", feedback: false, now: now)
        let package = try FileTransport.decodeShare(FileTransport.encode(SharePackage(session: session)))
        let (copy, _) = package.independentCopy(now: now, scope: .local)
        let imported = try await commands.importPackage(package, draft: CardDraft(card: copy), allowsDuplicate: false, feedbackConsent: false, now: now)
        XCTAssertNotEqual(imported.id, card.id)
        try await commands.complete(Occurrence(card: imported, semanticKey: "undated", plannedAt: nil), now: now)
        let library = try await repository.library()
        XCTAssertEqual(library.events.map(\.cardID), [imported.id])
        let outbox = try await repository.outbox(); XCTAssertTrue(outbox.isEmpty)
        let (another, _) = package.independentCopy(now: now, scope: .local)
        do { _ = try await commands.importPackage(package, draft: CardDraft(card: another), allowsDuplicate: false, feedbackConsent: false, now: now); XCTFail("Duplicate import needs a choice") } catch {}
    }
    func testBackupRoundTripWithSetRulesAndTamperFailsBeforeMutation() async throws {
        let source = try await repository(); let commands = CardCommands(repository: source)
        var card = Card(title: "学习", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(year: 2026, month: 9, day: 11), time: DayTime(hour: 20), frequency: .weekly)
        card.schedule?.weekdays = [2,4,6]; card.appearance.overriddenFields = ["theme", "illustration", "background"]
        _ = try await commands.save(CardDraft(card: card), now: now)
        let exported = try await source.exportBackup(now: now)
        let bytes = try FileTransport.encode(exported)
        let decoded = try FileTransport.decodeBackup(bytes)
        let destination = try await repository()
        let count = try await destination.restoreBackup(decoded, policy: .requireChoice, now: now)
        XCTAssertEqual(count, 1)
        let restored = try await destination.exportBackup(now: now)
        XCTAssertEqual(restored.payload, decoded.payload)
        var tampered = decoded; tampered.payload.cards[0].title = "被改过的标题"
        XCTAssertThrowsError(try FileTransport.decodeBackup(FileTransport.encode(tampered)))
        let final = try await destination.library(); XCTAssertEqual(final.cards.first?.title, "学习")
    }
    func testScopeMigrationVerifiesBeforeRemovingSourceAndPreservesEvents() async throws {
        let repository = try await repository(cloudStores: true)
        let commands = CardCommands(repository: repository)
        let card = try await commands.save(CardDraft(card: Card(title: "迁移完整历史", now: now)), now: now)
        try await commands.complete(Occurrence(card: card, semanticKey: "undated", plannedAt: nil), now: now)
        try await repository.migrateCard(card.id, to: .privateCloud, now: now)
        let cloud = try await repository.library()
        XCTAssertEqual(cloud.cards.count, 1); XCTAssertEqual(cloud.cards.first?.scope, .privateCloud); XCTAssertEqual(cloud.events.count, 1)
        try await repository.resumeMigrations()
        try await repository.migrateCard(card.id, to: .local, now: now)
        let local = try await repository.library()
        XCTAssertEqual(local.cards.count, 1); XCTAssertEqual(local.cards.first?.scope, .local); XCTAssertEqual(local.events.count, 1)
    }
    func testMissingInitializedDatabaseFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriMissingStoreTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("NianYiV1".utf8).write(to: directory.appendingPathComponent("LocalCards.initialized"))
        do { _ = try await repository(directory: directory); XCTFail("Must not present a new empty library") } catch { XCTAssertTrue(error.localizedDescription.contains("无法找到")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("LocalCards.sqlite").path))
    }
    func testReplacementCreatesReadableRecoveryPointAndPreservesUnrelatedCards() async throws {
        let repository = try await repository(); let commands = CardCommands(repository: repository)
        var original = try await commands.save(CardDraft(card: Card(title: "旧备份版本", now: now)), now: now)
        let oldBackup = try await repository.exportBackup(now: now)
        original.title = "覆盖前最新内容"
        let latest = try await commands.save(CardDraft(card: original, isEditing: true), now: now.addingTimeInterval(1))
        let extra = try await commands.save(CardDraft(card: Card(title: "备份外的新卡片", now: now)), now: now)
        let preview = try await repository.previewBackup(oldBackup)
        XCTAssertEqual(preview.newCount, 0); XCTAssertEqual(preview.matchingCount, 1); XCTAssertEqual(preview.cloudMatchingCount, 0)
        let count = try await repository.restoreBackup(oldBackup, policy: .replaceMatching, now: now, expectedPreview: preview)
        XCTAssertEqual(count, 1)
        let after = try await repository.library()
        XCTAssertEqual(after.cards.first { $0.id == original.id }?.title, "旧备份版本")
        XCTAssertTrue(after.cards.contains { $0.id == extra.id })
        let point = try XCTUnwrap(repository.recoveryPoints().first)
        XCTAssertGreaterThan(point.byteCount, 0)
        let recovery = try repository.recoveryBackup(id: point.id)
        XCTAssertEqual(recovery.payload.cards.first { $0.id == original.id }, latest)
        XCTAssertTrue(recovery.payload.cards.contains { $0.id == extra.id })
        _ = try await repository.restoreBackup(recovery, policy: .replaceMatching, now: now)
        let restored = try await repository.library()
        XCTAssertEqual(restored.cards.first { $0.id == original.id }, latest)
        XCTAssertEqual(restored.cards.count, 2)
        XCTAssertEqual(try repository.recoveryPoints().count, 2)
    }
    func testInvalidBackupAndFailedRecoveryPointNeverReplaceExistingContent() async throws {
        let repository = try await repository(); let commands = CardCommands(repository: repository)
        var card = try await commands.save(CardDraft(card: Card(title: "原始内容", now: now)), now: now)
        let backup = try await repository.exportBackup(now: now)
        card.title = "必须保留的修改"; _ = try await commands.save(CardDraft(card: card, isEditing: true), now: now)
        var invalid = backup; invalid.payload.cards[0].title = "校验被破坏"
        do { _ = try await repository.restoreBackup(invalid, policy: .replaceMatching, now: now); XCTFail("Invalid backup must fail before creating a recovery point") } catch {}
        XCTAssertTrue(try repository.recoveryPoints().isEmpty)
        let folder = repository.persistence.configuration.directory.appendingPathComponent("Recovery")
        try Data("A file prevents creating the recovery directory".utf8).write(to: folder)
        do { _ = try await repository.restoreBackup(backup, policy: .replaceMatching, now: now); XCTFail("Replacement requires a durable recovery point") } catch {}
        let after = try await repository.library()
        XCTAssertEqual(after.cards.first?.title, "必须保留的修改")
        XCTAssertThrowsError(try repository.recoveryBackup(id: "../LocalCards.sqlite"))
    }
    func testBackupPreviewMustBeReconfirmedAfterCurrentCardChanges() async throws {
        let repository = try await repository(); let commands = CardCommands(repository: repository)
        var card = try await commands.save(CardDraft(card: Card(title: "初始内容", now: now)), now: now)
        let backup = try await repository.exportBackup(now: now)
        let preview = try await repository.previewBackup(backup)
        card.title = "预览后又有修改"; _ = try await commands.save(CardDraft(card: card, isEditing: true), now: now)
        do { _ = try await repository.restoreBackup(backup, policy: .replaceMatching, now: now, expectedPreview: preview); XCTFail("Changed content requires a fresh preview") } catch {}
        let after = try await repository.library()
        XCTAssertEqual(after.cards.first?.title, "预览后又有修改")
        XCTAssertTrue(try repository.recoveryPoints().isEmpty)
    }
    func testRestoreWithoutRemindersRetainsScheduleAndHistoryAndPastRemindersStayPast() async throws {
        let repository = try await repository(); let commands = CardCommands(repository: repository)
        let calendar = Calendar.current
        var card = Card(title: "恢复后保留安排", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now.addingTimeInterval(-86400), calendar: calendar), time: DayTime(hour: 9))
        card.reminders.isEnabled = true; card.reminders.enablesLiveActivity = true; card.reminders.scheduledLiveActivity = true
        card = try await commands.save(CardDraft(card: card), now: now)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card, at: now))
        try await commands.complete(occurrence, now: now)
        try await commands.setLifecycle(card: card, lifecycle: .deleted, now: now)
        let deletedLibrary = try await repository.library()
        let deleted = try XCTUnwrap(deletedLibrary.cards.first)
        let restored = try await commands.restore(deleted, keepingReminders: false, now: now)
        XCTAssertEqual(restored.lifecycle, .active); XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.schedule, card.schedule)
        XCTAssertFalse(restored.reminders.isEnabled); XCTAssertFalse(restored.reminders.enablesLiveActivity); XCTAssertFalse(restored.reminders.scheduledLiveActivity)
        let snapshot = try await repository.library()
        XCTAssertEqual(EventReducer.state(events: snapshot.events), .completed)
        do { _ = try await commands.restore(deleted, keepingReminders: true, now: now); XCTFail("A stale restore sheet must not overwrite the current card") } catch {}
        var past = Card(title: "过去的提醒不补发", now: now)
        past.schedule = card.schedule; past.reminders.isEnabled = true
        past = try await commands.save(CardDraft(card: past), now: now)
        try await commands.setLifecycle(card: past, lifecycle: .archived, now: now)
        let archivedLibrary = try await repository.library()
        let archived = try XCTUnwrap(archivedLibrary.cards.first { $0.id == past.id })
        _ = try await commands.restore(archived, keepingReminders: true, now: now)
        let final = try await repository.library()
        let desired = ReminderPlanner(calendar: calendar).plan(library: final, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: true, alarmAllowed: true))
        XCTAssertTrue(desired.requests.isEmpty); XCTAssertTrue(desired.deferred.isEmpty)
    }

    func testBackupPreviewRejectsCompletionAndOccurrenceChangesWithoutCardRevisionChanges() async throws {
        let repository = try await repository(); let commands = CardCommands(repository: repository)
        let date = now, calendar = Calendar.current
        var card = Card(title: "处理历史必须重新确认", now: date)
        card.schedule = ScheduleDefinition(start: CivilDate(date.addingTimeInterval(86400), calendar: calendar), time: DayTime(hour: 9))
        card = try await commands.save(CardDraft(card: card), now: date)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: calendar).next(for: card, after: date))
        let backup = try await repository.exportBackup(now: date)
        let beforeCompletion = try await repository.previewBackup(backup)
        try await commands.complete(occurrence, now: date)
        do { _ = try await repository.restoreBackup(backup, policy: .replaceMatching, now: date, expectedPreview: beforeCompletion); XCTFail("A completion changes what would be replaced even when the card revision is unchanged") } catch {}
        var current = try await repository.library()
        XCTAssertEqual(current.cards.first?.revisionID, card.revisionID)
        XCTAssertEqual(EventReducer.state(events: current.events), .completed)
        try await commands.undo(occurrence, now: date)
        let beforeReschedule = try await repository.previewBackup(backup)
        let newDate = date.addingTimeInterval(172800)
        try await commands.rescheduleOccurrence(occurrence, to: newDate, now: date)
        do { _ = try await repository.restoreBackup(backup, policy: .replaceMatching, now: date, expectedPreview: beforeReschedule); XCTFail("A single occurrence change requires a new confirmation") } catch {}
        current = try await repository.library()
        XCTAssertEqual(current.cards.first?.revisionID, card.revisionID)
        XCTAssertEqual(current.overrides.first?.newDate, newDate)
        XCTAssertTrue(try repository.recoveryPoints().isEmpty)
    }
    func testChangesWhileRecoveryPointIsWrittenAbortWithoutDeletingConcurrentHistory() async throws {
        let repository = try await repository(); let commands = CardCommands(repository: repository)
        let date = now
        let card = try await commands.save(CardDraft(card: Card(title: "并发操作不能被覆盖", now: date)), now: date)
        let occurrence = Occurrence(card: card, semanticKey: "undated", plannedAt: nil)
        let event = TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "another-writer", kind: .completed, now: date)
        let backup = try await repository.exportBackup(now: date)
        let preview = try await repository.previewBackup(backup)
        do {
            _ = try await repository.restoreBackup(backup, policy: .replaceMatching, now: date, expectedPreview: preview, beforeReplacement: {
                let context = repository.persistence.context(author: "concurrent-insert")
                try context.performAndWait {
                    let store = try repository.persistence.store(for: .local)
                    try DatabaseCodec.put(occurrence, entity: "OccurrenceRecord", id: occurrence.id, context: context, store: store, fields: ["cardID":card.id])
                    try DatabaseCodec.put(event, entity: "TaskEventRecord", id: event.id, context: context, store: store, fields: ["cardID":card.id, "occurrenceID":occurrence.id, "operationID":event.operationID, "happenedAt":date, "kind":event.kind.rawValue])
                    try context.save()
                }
            })
            XCTFail("A concurrent history insert must stop restoration")
        } catch {}
        let inserted = try await repository.library()
        XCTAssertEqual(inserted.events, [event]); XCTAssertEqual(inserted.occurrences, [occurrence])
        let updatedPreview = try await repository.previewBackup(backup)
        let changed = TaskEvent(operationID: event.operationID, occurrence: occurrence, actorID: event.actorID, kind: .skipped, now: date)
        do {
            _ = try await repository.restoreBackup(backup, policy: .replaceMatching, now: date, expectedPreview: updatedPreview, beforeReplacement: {
                let context = repository.persistence.context(author: "concurrent-update")
                try context.performAndWait {
                    let store = try repository.persistence.store(for: .local)
                    try DatabaseCodec.put(changed, entity: "TaskEventRecord", id: event.id, context: context, store: store, fields: ["cardID":card.id, "occurrenceID":occurrence.id, "operationID":event.operationID, "happenedAt":date, "kind":changed.kind.rawValue])
                    try context.save()
                }
            })
            XCTFail("A concurrent existing-row change must stop restoration")
        } catch {}
        let updated = try await repository.library()
        XCTAssertEqual(updated.cards.first, card)
        XCTAssertEqual(updated.events.first?.kind, .skipped)
        XCTAssertEqual(updated.occurrences, [occurrence])
    }

}
