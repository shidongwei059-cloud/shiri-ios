import XCTest
import CoreData
@testable import ShiriCore

final class MaintenanceTests: IsolatedStoreTestCase {
    func testReschedulingAfterAlarmStopClearsOldConfirmationAndRestartsReminder() async throws {
        let repo = try await repository(), commands = CardCommands(repository: repo)
        var card = Card(title: "停响后改时间", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: .current), time: DayTime(hour: 10))
        card.reminders.isEnabled = true; card.reminders.channel = .alarm
        card = try await commands.save(CardDraft(card: card), now: now)
        let occurrence = try XCTUnwrap(OccurrenceEngine(calendar: .current).relevantOccurrence(for: card, at: now))
        try await commands.stopReminder(occurrence, now: now, alarmOnly: true)
        var library = try await repo.library()
        XCTAssertEqual(library.personalStates[occurrence.id]?.isStopped, true)
        XCTAssertEqual(EventReducer.state(events: library.events(for: occurrence.id)), .pending)
        let newDate = now.addingTimeInterval(3600)
        try await commands.rescheduleOccurrence(occurrence, to: newDate, now: now)
        library = try await repo.library()
        XCTAssertEqual(library.personalStates[occurrence.id]?.isStopped, false)
        XCTAssertNil(library.personalStates[occurrence.id]?.snoozedUntil)
        let plan = ReminderPlanner(calendar: .current).plan(library: library, preferences: AppPreferences(), now: now, capabilities: ReminderCapabilities(notificationsAllowed: true, alarmAllowed: true))
        XCTAssertEqual(plan.requests.first { $0.channel == .alarm }?.firesAt, newDate)
        XCTAssertEqual(plan.requests.first { $0.isCompletionConfirmation == true }?.firesAt, newDate.addingTimeInterval(300))
        XCTAssertFalse(plan.requests.contains { $0.firesAt == now.addingTimeInterval(2) })
    }

    let now = Date(timeIntervalSince1970: 1_789_092_000)
    func repository(directory: URL? = nil, author: String = "test-main") async throws -> ShiriRepository {
        let root = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShiriMaintenance-" + UUID().uuidString)
        return ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: root)), actorID: author)
    }
    func testHistoryConsumerDoesNotCreateSelfSustainingHistoryAndSeesOtherContext() async throws {
        let first = try await repository(); let reader = PersistentHistoryConsumer(repository: first,consumer: "test-history")
        _ = try await reader.consume()
        let second = try await repository(directory: first.persistence.configuration.directory,author: "widget")
        _ = try await CardCommands(repository: second).save(CardDraft(card: Card(title: "组件写入",now: now)),now: now)
        let changes = try await reader.consume(); XCTAssertGreaterThan(changes.transactions,0)
        let after = try await reader.consume(); XCTAssertEqual(after.transactions,0)
        let afterAgain = try await reader.consume(); XCTAssertEqual(afterAgain.transactions,0)
    }
    func testReplaceBackupRemovesSupersededRevisionAndUnrelatedCardSurvives() async throws {
        let repo = try await repository(); let commands = CardCommands(repository: repo)
        let first = try await commands.save(CardDraft(card: Card(title: "原始内容",now: now)),now: now)
        let backup = try await repo.exportBackup(now: now)
        var edited = first; edited.title = "后来的修改"
        _ = try await commands.save(CardDraft(card: edited,isEditing: true),now: now.addingTimeInterval(1))
        let independent = try await commands.save(CardDraft(card: Card(title: "无关的卡片",now: now)),now: now)
        _ = try await repo.restoreBackup(backup,policy: .replaceMatching,now: now)
        let library = try await repo.library()
        XCTAssertEqual(library.cards.first { $0.id == first.id }?.title,"原始内容")
        XCTAssertTrue(library.cards.contains { $0.id == independent.id })
        XCTAssertEqual(library.revisions.filter { $0.cardID == first.id }.count,1)
        XCTAssertTrue(library.conflicts.isEmpty)
    }
    func testTrashRetentionDeletesOnlyExpiredSoftDeletedCards() async throws {
        let repo = try await repository(); let commands = CardCommands(repository: repo)
        let old = try await commands.save(CardDraft(card: Card(title: "已过保留期",now: now)),now: now)
        let recent = try await commands.save(CardDraft(card: Card(title: "仍可恢复",now: now)),now: now)
        let active = try await commands.save(CardDraft(card: Card(title: "正常卡片",now: now)),now: now)
        try await commands.setLifecycle(card: old,lifecycle: .deleted,now: now.addingTimeInterval(-31*86400))
        try await commands.setLifecycle(card: recent,lifecycle: .deleted,now: now.addingTimeInterval(-29*86400))
        let count = try await repo.purgeExpiredTrash(now: now,calendar: .current)
        XCTAssertEqual(count,1)
        let remaining = try await repo.library(); XCTAssertEqual(Set(remaining.cards.map(\.id)),Set([recent.id,active.id]))
    }
    func testAttachmentHeaderCannotSpoofDimensions() throws {
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jSucAAAAASUVORK5CYII=")!
        let valid = Attachment(cardID: UUID(),data: data,width: 1,height: 1,mediaType: "image/png")
        XCTAssertNoThrow(try valid.validate())
        var forged = valid; forged.width = 2048
        XCTAssertThrowsError(try forged.validate())
    }
    func testTenThousandCardSearchUsesNativeColumns() async throws {
        let repo = try await repository(); let store = repo.persistence.stores[.local]!
        try await repo.transaction { context in
            for index in 0..<10_000 {
                var card = Card(title: "日常记录 \(index)",kind: .note,now: self.now)
                card.note = index == 9876 ? "目标关键词 银杏雨" : "普通正文"
                let object = NSEntityDescription.insertNewObject(forEntityName: "CardRecord",into: context); context.assign(object,to: store)
                for (key,value) in ["title":card.title,"note":card.note,"kind":card.kind.rawValue,"category":card.category,"importance":card.importance.rawValue,"lifecycle":card.lifecycle.rawValue,"scope":card.scope.rawValue] { object.setValue(value,forKey: key) }
                object.setValue(card.id,forKey: "id"); object.setValue(card.revisionID,forKey: "revisionID"); object.setValue(card.createdAt,forKey: "createdAt"); object.setValue(card.updatedAt,forKey: "updatedAt")
            }
        }
        let start = Date()
        let result = try await repo.searchCardIDs("银杏雨")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.count,1)
        print("Shiri 10k native search: \(elapsed) seconds")
        XCTAssertLessThan(elapsed,2,"Local Mac test threshold; device latency is recorded separately")
    }
    func testBirthdayAdvanceOnlyNeverCreatesMidnightReminder() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026,month: 9,day: 11,hour: 10))!
        var card = Card(title: "妈妈生日",kind: .note,now: now)
        var birthday = BirthdayRule(name: "妈妈",calendar: .gregorian,month: 9,day: 20)
        birthday.advanceDays = [1]; birthday.advanceTime = DayTime(hour: 9); card.birthday = birthday; card.reminders.isEnabled = true
        var library = LibrarySnapshot(); library.cards = [card]
        let desired = ReminderPlanner(calendar: calendar).plan(library: library,preferences: AppPreferences(),now: now,capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertFalse(desired.requests.isEmpty)
        XCTAssertTrue(desired.requests.allSatisfy { calendar.component(.hour,from: $0.firesAt) == 9 })
        XCTAssertTrue(desired.requests.contains( where: \.isPrimary ))
        XCTAssertTrue(desired.issues.isEmpty)
    }
    func testPrimitiveDeviceValuesAndLegacyValueContainersRoundTrip() throws {
        XCTAssertEqual(try ValueCodec.decode(Bool.self,ValueCodec.encode(true)),true)
        XCTAssertEqual(try ValueCodec.decode(String.self,ValueCodec.encode("等待同步")),"等待同步")
        XCTAssertEqual(try ValueCodec.decode(Date.self,ValueCodec.encode(now)),now)
        let legacy = try PropertyListEncoder().encode(AppPreferences())
        XCTAssertEqual(try ValueCodec.decode(AppPreferences.self,legacy),AppPreferences())
    }
    func testRetainCloudCopyDoesNotDeleteCloudRowsOrMergeLaterCloudEventsIntoLocal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriRetain-" + UUID().uuidString)
        let persistence = try await openTestPersistence(PersistenceConfiguration(directory: directory,loadsCloudStores: true))
        let repo = ShiriRepository(persistence: persistence,actorID: "local")
        var card = Card(title: "保留云副本",now: now); card.scope = .privateCloud
        let saved = try await CardCommands(repository: repo).save(CardDraft(card: card),now: now)
        try await repo.migrateCard(saved.id,to: .local,now: now,retainCloudCopy: true)
        let cloud = persistence.stores[.personal]!
        let stillThere = try await repo.cardPayload(saved.id,store: cloud)
        XCTAssertEqual(stillThere.cards.count,1)
        let occurrence = Occurrence(card: saved,semanticKey: "undated",plannedAt: nil)
        let event = TaskEvent(operationID: UUID(),occurrence: occurrence,actorID: "other-device",kind: .completed,now: now)
        try await repo.transaction { context in try DatabaseCodec.put(event,entity: "TaskEventRecord",id: event.id,context: context,store: cloud,fields: ["cardID":saved.id,"occurrenceID":occurrence.id]) }
        let local = try await repo.library()
        XCTAssertEqual(local.cards.first?.scope,.local)
        XCTAssertTrue(local.events.isEmpty)
    }
    func testKnownV0DatabaseUpgradesWithoutDeletingItsCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriV0-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: PersistentModel.make(version: 0))
        let url = root.appendingPathComponent("LocalCards.sqlite")
        let oldStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType,configurationName: StoreKind.local.rawValue,at: url)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
        let id = UUID()
        try context.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "CardRecord",into: context); context.assign(row,to: oldStore)
            row.setValue(id,forKey: "id"); row.setValue("旧版仍然在",forKey: "title"); row.setValue("note",forKey: "kind"); row.setValue(self.now,forKey: "createdAt"); row.setValue(UUID(),forKey: "revisionID")
            try context.save()
        }
        try coordinator.remove(oldStore)
        let repo = try await repository(directory: root)
        let library = try await repo.library()
        XCTAssertEqual(library.cards.first?.id,id); XCTAssertEqual(library.cards.first?.title,"旧版仍然在")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("BeforeMigration-") })
    }

    func testMigrationNeverOverwritesADifferentRetainedCloudCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriMigrationConflict-" + UUID().uuidString)
        let persistence = try await openTestPersistence(PersistenceConfiguration(directory: directory,loadsCloudStores: true))
        let repo = ShiriRepository(persistence: persistence,actorID: "test")
        var card = Card(title: "云端原文",now: now); card.scope = .privateCloud
        card = try await CardCommands(repository: repo).save(CardDraft(card: card),now: now)
        try await repo.migrateCard(card.id,to: .local,now: now,retainCloudCopy: true)
        card.scope = .local; card.title = "本机独立修改"
        _ = try await CardCommands(repository: repo).save(CardDraft(card: card,isEditing: true),now: now.addingTimeInterval(1))
        do { try await repo.migrateCard(card.id,to: .privateCloud,now: now); XCTFail("A different destination must require a version decision") }
        catch ShiriError.conflict { }
        let cloud = try await repo.cardPayload(card.id,store: persistence.stores[.personal]!)
        let local = try await repo.library()
        XCTAssertEqual(cloud.cards.first?.title,"云端原文"); XCTAssertEqual(local.cards.first?.title,"本机独立修改")
        let journals = try await repo.migrationJournals(); XCTAssertTrue(journals.allSatisfy { $0.phase == "complete" })
    }

    func testFeedbackSessionHistoryIsBoundToItsCloudIdentityAndDetachedRepositoryThrows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiriAccountIsolation-" + UUID().uuidString)
        let oldPersistence = try await openTestPersistence(PersistenceConfiguration(directory: directory,loadsCloudStores: true,cloudAccountKey: "account-a"))
        let old = ShiriRepository(persistence: oldPersistence,actorID: "old")
        let snapshot = SharedCardSnapshot(card: Card(title: "隔离的邀请",now: now),attachments: [],occurrence: nil,extent: .entireRule,includeNote: false,includePhotos: false)
        let cloudSession = ShareSession(snapshot: snapshot,recipientLabel: "收件人",feedback: true,now: now)
        let localSession = ShareSession(snapshot: snapshot,recipientLabel: "日程文件",feedback: false,now: now)
        try await old.saveLocalShareSession(cloudSession); try await old.saveLocalShareSession(localSession)
        let before = try await old.localShareSessions(); XCTAssertEqual(before.count,2)
        try await oldPersistence.detachStores()
        do { _ = try await old.deviceValue(String.self,key: "anything"); XCTFail("A detached store must return an error") }
        catch ShiriError.unavailable { }
        let fresh = ShiriRepository(persistence: try await openTestPersistence(PersistenceConfiguration(directory: directory,loadsCloudStores: true,cloudAccountKey: "account-b")),actorID: "new")
        let visible = try await fresh.localShareSessions(); XCTAssertEqual(visible.map(\.id),[localSession.id])
    }

    func testSnoozeOfOlderPendingOccurrenceIsActuallyPlannedWithoutMovingDeadline() async throws {
        let repo = try await repository(); let calendar = Calendar.current
        let past = now.addingTimeInterval(-5*86400)
        var card = Card(title: "之前没完成的事项",now: past)
        card.schedule = ScheduleDefinition(start: CivilDate(past,calendar: calendar),time: DayTime(hour: 9)); card.schedule?.dueAt = past
        card.reminders.isEnabled = true
        card = try await CardCommands(repository: repo).save(CardDraft(card: card),now: past)
        let occurrence = OccurrenceEngine(calendar: calendar).relevantOccurrence(for: card,at: now)!
        let until = now.addingTimeInterval(600)
        try await CardCommands(repository: repo).snooze(occurrence,until: until,now: now)
        let library = try await repo.library()
        let desired = ReminderPlanner(calendar: calendar).plan(library: library,preferences: AppPreferences(),now: now,capabilities: ReminderCapabilities(notificationsAllowed: true))
        XCTAssertEqual(desired.requests.count,2); XCTAssertEqual(desired.requests.first?.firesAt,until)
        XCTAssertEqual(desired.requests.first { $0.isCompletionConfirmation == true }?.firesAt, until.addingTimeInterval(300))
        XCTAssertEqual(library.cards.first?.schedule?.dueAt,past)
    }

    func testOldBirthdayNotificationCannotActOnAnEditedBirthdayRule() throws {
        var card = Card(title: "生日",kind: .note,now: now)
        var birthday = BirthdayRule(name: "妈妈",calendar: .gregorian,month: 10,day: 12); birthday.dayTime = DayTime(hour: 9)
        card.birthday = birthday
        let occurrence = OccurrenceEngine(calendar: .current).next(for: card,after: now)!
        let payload = NotificationPayload(card: card,occurrence: occurrence,scope: .occurrence,offset: 0)
        card.birthday?.day = 13
        var library = LibrarySnapshot(); library.cards = [card]
        XCTAssertThrowsError(try payload.resolve(in: library,deliveredAt: now,calendar: .current))
    }

}
