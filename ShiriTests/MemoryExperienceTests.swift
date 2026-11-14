import XCTest
@testable import ShiriCore

final class MemoryExperienceTests: IsolatedStoreTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10))! }
    func repo() async throws -> ShiriRepository {
        let persistence = try await openTestPersistence(PersistenceConfiguration(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ShiriMemoryTests-" + UUID().uuidString)))
        return ShiriRepository(persistence: persistence, actorID: "memory-tests")
    }
    func photo(_ card: Card) -> Attachment {
        Attachment(cardID: card.id, data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jSucAAAAASUVORK5CYII=")!, width: 1, height: 1, mediaType: "image/png")
    }
    func testSnapshotKeepsTextAndOwnsPhotosAfterSourceEditAndDeletion() async throws {
        let repo = try await repo(), commands = CardCommands(repository: repo)
        var source = Card(title: "和妈妈吃饭", now: now); source.note = "一起吃了生日面"
        let attachment = photo(source); source.attachmentIDs = [attachment.id]; source.appearance.backgroundAttachmentID = attachment.id
        var original = CardDraft(card: source); original.attachments = [attachment]
        source = try await commands.save(original, now: now)
        let draft = try MemoryFactory.draft(from: source, attachments: [attachment], date: now, now: now)
        let memory = try await commands.save(draft, now: now)
        XCTAssertNotEqual(memory.id, source.id); XCTAssertNotEqual(memory.attachmentIDs, source.attachmentIDs)
        XCTAssertEqual(memory.appearance.backgroundAttachmentID, draft.attachments.first?.id)
        source.title = "下次再聚"; source.note = "新的安排"; source.attachmentIDs = []
        source = try await commands.save(CardDraft(card: source, isEditing: true), now: now)
        try await commands.setLifecycle(card: source, lifecycle: .deleted, now: now)
        _ = try await repo.purgeExpiredTrash(now: now.addingTimeInterval(40 * 86400), calendar: calendar)
        let library = try await repo.library(), photos = try await repo.attachments(cardID: memory.id)
        XCTAssertEqual(MemoryCollection.cards(in: library).first?.note, "一起吃了生日面")
        XCTAssertEqual(photos.first?.data, attachment.data); XCTAssertFalse(memory.reminders.isEnabled)
        XCTAssertNil(memory.schedule); XCTAssertFalse(memory.canComplete)
        var pinned = memory; pinned.isPinned = true
        var snapshot = LibrarySnapshot(); snapshot.cards = [pinned]
        XCTAssertTrue(WidgetSnapshot.make(library: snapshot, preferences: AppPreferences(), now: now, calendar: calendar).cards.isEmpty)
    }
    func testLegacyMigrationIsAtomicRepeatableAndKeepsSource() async throws {
        let repo = try await repo(), commands = CardCommands(repository: repo)
        var old = Card(title: "旧收藏", now: now); old.memoryDate = now.addingTimeInterval(-86400)
        let image = photo(old); old.attachmentIDs = [image.id]
        var draft = CardDraft(card: old); draft.attachments = [image]
        old = try await commands.save(draft, now: now)
        let first = try await repo.migrateLegacyMemories(now: now)
        let second = try await repo.migrateLegacyMemories(now: now)
        XCTAssertEqual(first, 1); XCTAssertEqual(second, 0)
        let library = try await repo.library(), memory = try XCTUnwrap(MemoryCollection.cards(in: library).first)
        XCTAssertEqual(library.cards.count, 2); XCTAssertNil(library.cards.first { $0.id == old.id }?.memoryDate)
        XCTAssertEqual(memory.memoryDate, old.memoryDate); XCTAssertEqual(memory.memory?.sourceCardID, old.id)
        let copiedPhotos = try await repo.attachments(cardID: memory.id)
        XCTAssertEqual(copiedPhotos.count, 1)
        let backup = try await repo.exportBackup(now: now), restored = try await self.repo()
        _ = try await restored.restoreBackup(FileTransport.decodeBackup(FileTransport.encode(backup)), policy: .requireChoice, now: now)
        let after = try await restored.library()
        XCTAssertEqual(MemoryCollection.cards(in: after).first, memory)
    }
    func testMissingPhotoDoesNotClearLegacyBookmarkOrSavePartialCopies() async throws {
        let repo = try await repo(), commands = CardCommands(repository: repo)
        var old = Card(title: "尚未下载完整的旧照片", now: now); old.memoryDate = now; old.attachmentIDs = [UUID()]
        _ = try await commands.save(CardDraft(card: old), now: now)
        do { _ = try await repo.migrateLegacyMemories(now: now); XCTFail("Missing photos must preserve the old bookmark") } catch {}
        let library = try await repo.library()
        XCTAssertEqual(library.cards.count, 1); XCTAssertEqual(library.cards.first?.memoryDate, now)
        XCTAssertThrowsError(try MemoryFactory.draft(from: old, attachments: [], date: now, now: now))
    }
    func testEachCompletedOccurrenceRemainsASeparateCandidateAndUndoRemovesCandidate() async throws {
        let repo = try await repo(), commands = CardCommands(repository: repo)
        var card = Card(title: "晚饭后散步", now: now)
        card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 8)); card.schedule?.frequency = .daily
        card = try await commands.save(CardDraft(card: card), now: now)
        let occurrences = OccurrenceEngine(calendar: calendar).occurrences(for: card, in: DateInterval(start: calendar.startOfDay(for: now), duration: 2 * 86400))
        XCTAssertEqual(occurrences.count, 2)
        for occurrence in occurrences { try await commands.complete(occurrence, now: occurrence.plannedAt!) }
        let library = try await repo.library()
        let candidates = MemoryCollection.candidates(in: library, now: now.addingTimeInterval(2 * 86400))
        XCTAssertEqual(candidates.count, 2); XCTAssertNotEqual(candidates[0].id, candidates[1].id)
        let detailCandidate = MemoryCollection.candidate(for: card, occurrence: candidates[0].occurrence, in: library, now: now.addingTimeInterval(30 * 86400))
        XCTAssertEqual(detailCandidate.date, candidates[0].date, "Later visits retain the actual completion date")
        XCTAssertEqual(detailCandidate.title, candidates[0].title)
        let first = try MemoryFactory.draft(from: card, attachments: [], occurrence: candidates[0].occurrence, date: candidates[0].date, now: now)
        let second = try MemoryFactory.draft(from: card, attachments: [], occurrence: candidates[1].occurrence, date: candidates[1].date, now: now)
        XCTAssertNotEqual(first.card.memory?.sourceOccurrenceID, second.card.memory?.sourceOccurrenceID)
        try await commands.undo(occurrences[0], now: now.addingTimeInterval(3 * 86400))
        let undone = try await repo.library()
        XCTAssertEqual(MemoryCollection.candidates(in: undone, now: now.addingTimeInterval(4 * 86400)).count, 1)
    }
    func testReunionHonorsAnniversaryPrivacyArchiveFutureAndDeterminism() {
        func memory(_ days: Int, _ title: String) -> Card {
            var card = Card(title: title, kind: .note, now: now); card.memory = MemoryMetadata()
            card.memoryDate = calendar.date(byAdding: .day, value: days, to: now); return card
        }
        let anniversary = memory(-365, "去年的今天"), older = memory(-15, "普通旧片刻")
        var hidden = anniversary; hidden.id = UUID(); hidden.memory?.excludedFromReunion = true
        var archived = anniversary; archived.id = UUID(); archived.lifecycle = .archived
        XCTAssertEqual(MemoryCollection.reunion(in: [older, anniversary, hidden, archived, memory(1, "未来")], now: now, calendar: calendar)?.id, anniversary.id)
        XCTAssertNil(MemoryCollection.reunion(in: [hidden, archived, memory(0, "今天"), memory(-2, "前天")], now: now, calendar: calendar))
        let another = memory(-20, "更早")
        let chosen = MemoryCollection.reunion(in: [older, another], now: now, calendar: calendar)
        XCTAssertEqual(chosen?.id, MemoryCollection.reunion(in: [another, older], now: now, calendar: calendar)?.id)
    }
    func testSearchAndSharingDoNotLeakMemoryProvenance() throws {
        var card = Card(title: "山里的日落", kind: .note, now: now); card.note = "和朋友喝茶"; card.category = "旅行"; card.memoryDate = now
        card.memory = MemoryMetadata(sourceCardID: UUID(), sourceTitle: "秘密的安排", previousMemoryID: UUID(), excludedFromReunion: true)
        XCTAssertEqual(MemoryCollection.filtered([card], query: "朋友 喝茶", category: "旅行").count, 1)
        XCTAssertTrue(MemoryCollection.filtered([card], interval: DateInterval(start: now.addingTimeInterval(-1), end: now)).isEmpty)
        let shared = SharedCardSnapshot(card: card, attachments: [], occurrence: nil, extent: .entireRule, includeNote: true, includePhotos: false)
        XCTAssertNil(shared.card.memory); XCTAssertNil(shared.card.memoryDate)
        XCTAssertEqual(MemoryFactory.suggestedTitle(note: "今天看到了彩虹。想记住这一刻", hasPhotos: false), "今天看到了彩虹")
        XCTAssertEqual(MemoryFactory.suggestedTitle(note: "", hasPhotos: true), "照片里的这一天")
    }
    func testTenThousandMemoriesFilterWithoutChangingOrderOrPrivateReunionChoice() {
        var library = LibrarySnapshot()
        for index in 0..<10_000 {
            var card = Card(id: StableID.uuid("memory-performance-\(index)"), title: String(format: "生活片刻 %05d", index), kind: .note, now: now)
            card.memoryDate = now.addingTimeInterval(-Double(index + 1) * 86400)
            card.memory = MemoryMetadata(excludedFromReunion: index % 2 == 0)
            card.note = "和朋友散步，慢慢记录日子"; card.category = index % 2 == 0 ? "生活" : "旅行"
            library.cards.append(card)
        }
        let started = Date()
        let all = MemoryCollection.cards(in: library)
        let results = MemoryCollection.filtered(all, query: "09999 朋友", category: "旅行")
        let reunion = MemoryCollection.reunion(in: all, now: now, calendar: calendar)
        print("Memory 10k sort + search + reunion: \(Date().timeIntervalSince(started)) seconds")
        XCTAssertEqual(results.map(\.title), ["生活片刻 09999"])
        XCTAssertEqual(all.first?.title, "生活片刻 00000")
        XCTAssertNotNil(reunion); XCTAssertFalse(reunion?.memory?.excludedFromReunion == true)
    }

    func testLegacyConversionProducesTheSameSnapshotsAcrossTwoDevices() async throws {
        let first = try await repo(), second = try await repo()
        var original = Card(title: "两台设备上的同一段旧回忆", now: now); original.memoryDate = now.addingTimeInterval(-86400)
        _ = try await first.save(original, parents: [], now: now)
        _ = try await second.save(original, parents: [], now: now)
        _ = try await first.migrateLegacyMemories(now: now)
        _ = try await second.migrateLegacyMemories(now: now.addingTimeInterval(86400))
        let a = try await first.library(), b = try await second.library()
        XCTAssertEqual(a.cards.sorted { $0.id.uuidString < $1.id.uuidString }, b.cards.sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(a.revisions.sorted { $0.id.uuidString < $1.id.uuidString }, b.revisions.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    func testMemoryDraftReopensWithTextSpeechDateAndPhotoOrderWithoutCreatingContent() async throws {
        let original = try await repo()
        var card = Card(title: "", kind: .note, now: now)
        card.memory = MemoryMetadata(); card.memoryDate = now.addingTimeInterval(-400 * 86400)
        card.note = "留住当时的感受"
        var draft = CardDraft(card: card); draft.memorySpeechText = "妈妈喊我吃饭，回忆不清理叙述"
        var first = photo(card), second = photo(card)
        first.sortIndex = 1; second.sortIndex = 0
        draft.attachments = [second, first]; draft.card.attachmentIDs = draft.attachments.map(\.id)
        try await original.saveDraft(draft)
        let reopenedPersistence = try await openTestPersistence(original.persistence.configuration)
        let reopened = ShiriRepository(persistence: reopenedPersistence, actorID: "reopened-memory")
        let drafts = try await reopened.drafts(), library = try await reopened.library()
        XCTAssertEqual(drafts, [draft]); XCTAssertEqual(drafts.first?.attachments.map(\.data), [second.data, first.data])
        XCTAssertTrue(library.cards.isEmpty); XCTAssertTrue(library.events.isEmpty)
        XCTAssertTrue(MemoryCollection.cards(in: library).isEmpty)
        XCTAssertTrue(WidgetSnapshot.make(library: library, preferences: AppPreferences(), now: now, calendar: calendar).cards.isEmpty)
        try await reopened.deleteDeviceRecord(entity: "DraftRecord", id: draft.id)
        let discarded = try await original.drafts(); XCTAssertTrue(discarded.isEmpty)
    }
    func testDraftRecoveryDoesNotMixNewEditingSourceOccurrenceAndFollowUpContexts() throws {
        var card = Card(title: "新回忆", kind: .note, now: now); card.memory = MemoryMetadata(); card.memoryDate = now
        let general = CardDraft(card: card)
        var task = Card(title: "每天散步", now: now)
        task.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 8)); task.schedule?.frequency = .daily
        let occurrences = OccurrenceEngine(calendar: calendar).occurrences(for: task, in: DateInterval(start: calendar.startOfDay(for: now), duration: 2 * 86400))
        let sourceA = MemoryCandidate(card: task, occurrence: occurrences[0], date: now)
        let sourceB = MemoryCandidate(card: task, occurrence: occurrences[1], date: now)
        let a = try MemoryFactory.draft(from: task, attachments: [], occurrence: sourceA.occurrence, date: now, now: now)
        let b = try MemoryFactory.draft(from: task, attachments: [], occurrence: sourceB.occurrence, date: now, now: now)
        var editing = CardDraft(card: card, isEditing: true); editing.card.note = "编辑草稿"
        var nextCard = card; nextCard.id = UUID(); nextCard.memory?.previousMemoryID = card.id
        let next = CardDraft(card: nextCard)
        let drafts = [next, b, editing, a, general]
        func match(edit: UUID? = nil, source: MemoryCandidate? = nil, previous: UUID? = nil) -> CardDraft? {
            MemoryDrafts.matching(drafts, editingID: edit, source: source, previousID: previous, occasionID: nil)
        }
        XCTAssertEqual(match(), general); XCTAssertEqual(match(edit: card.id), editing)
        XCTAssertEqual(match(source: sourceA), a); XCTAssertEqual(match(source: sourceB), b)
        XCTAssertEqual(match(previous: card.id), next); XCTAssertNil(match(previous: UUID()))
    }
    func testOldDraftPayloadStillDecodesAndSpeechOnlyDraftHasContent() throws {
        var card = Card(title: "", kind: .note, now: now); card.memory = MemoryMetadata(); card.memoryDate = now
        var draft = CardDraft(card: card)
        XCTAssertFalse(MemoryDrafts.hasContent(draft))
        let decoded = try JSONDecoder().decode(CardDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertNil(decoded.memorySpeechText)
        draft.card.note = " \n "
        draft.memorySpeechText = "还没确认的一段话"
        XCTAssertTrue(MemoryDrafts.hasContent(draft)); XCTAssertEqual(MemoryDrafts.title(draft), "还没确认的一段话")
    }
    func testSkippingReunionOnlyAffectsTodayAndDoesNotChangeTheMemory() throws {
        var card = Card(title: "过去的片刻", kind: .note, now: now); card.memory = MemoryMetadata(); card.memoryDate = now.addingTimeInterval(-365 * 86400)
        var excluded = card; excluded.id = UUID(); excluded.memory?.excludedFromReunion = true
        let skip = MemoryReunionSkip(day: CivilDate(now, calendar: calendar), cardIDs: [card.id])
        let stored = try JSONDecoder().decode(MemoryReunionSkip.self, from: JSONEncoder().encode(skip))
        XCTAssertNil(MemoryCollection.reunion(in: [card, excluded], now: now, calendar: calendar, skippedIDs: stored.skippedIDs(on: now, calendar: calendar)))
        let tomorrow = now.addingTimeInterval(86400)
        XCTAssertEqual(MemoryCollection.reunion(in: [card, excluded], now: tomorrow, calendar: calendar, skippedIDs: stored.skippedIDs(on: tomorrow, calendar: calendar))?.id, card.id)
        XCTAssertFalse(card.memory!.excludedFromReunion); XCTAssertEqual(card.lifecycle, .active)
    }
    func testSuggestedTitleRespectsSentencesAndEnglishWords() {
        XCTAssertEqual(MemoryFactory.suggestedTitle(note: "  和妈妈一起吃面！还记得那个味道。", hasPhotos: false), "和妈妈一起吃面")
        XCTAssertEqual(MemoryFactory.suggestedTitle(note: "Backdated memory audit 0123456789", hasPhotos: false), "Backdated memory audit")
        XCTAssertEqual(MemoryFactory.suggestedTitle(note: "我们一起走过城市里长长的小路，看到一个一直没有发现的新角落", hasPhotos: false), "我们一起走过城市里长长的小路")
        XCTAssertTrue(MemoryFactory.suggestedTitle(note: String(repeating: "长", count: 40), hasPhotos: false).hasSuffix("…"))
        XCTAssertEqual(MemoryFactory.suggestedTitle(note: "Supercalifragilisticexpialidocious memories", hasPhotos: false), "Supercalifragilisticexpialidocious")
    }

}
