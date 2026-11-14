import XCTest
@testable import ShiriCore

final class LifeMomentsTests: IsolatedStoreTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 14))! }
    func repo() async throws -> ShiriRepository {
        let p = try await openTestPersistence(PersistenceConfiguration(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ShiriMoments-" + UUID().uuidString)))
        return ShiriRepository(persistence: p, actorID: "moments-tests")
    }
    func parent() -> Card {
        var card = Card(title: "妈妈的生日", kind: .note, now: now)
        card.birthday = BirthdayRule(name: "妈妈", calendar: .gregorian, month: 10, day: 18)
        return card
    }
    func testOldCardsAndPreferencesDecodeWithoutNewFields() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(parent())) as? [String: Any])
        object.removeValue(forKey: "occasionLink"); object.removeValue(forKey: "memoryDate")
        let old = try decoder.decode(Card.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.occasionLink); XCTAssertNil(old.memoryDate); XCTAssertEqual(old.birthday, parent().birthday)
        var preferences = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(AppPreferences())) as? [String: Any])
        preferences.removeValue(forKey: "showsReviewComparison")
        XCTAssertNil(try decoder.decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: preferences)).showsReviewComparison)
    }
    func testPreparationDatesAreOneOffAndDuplicateBatchDoesNotPartiallySave() async throws {
        let repo = try await repo(), commands = CardCommands(repository: repo)
        let parent = try await commands.save(CardDraft(card: parent()), now: now)
        let anchor = CivilDate(year: 2026, month: 10, day: 18), choices = PreparationChoice.suggestions(anniversary: false)
        let created = try await repo.createPreparations(parentID: parent.id, revisionID: parent.revisionID, date: anchor, choices: [choices[0]], now: now, calendar: calendar)
        let gift = try XCTUnwrap(created.first)
        XCTAssertEqual(gift.schedule?.start, CivilDate(year: 2026, month: 10, day: 11)); XCTAssertEqual(gift.schedule?.frequency, .never)
        XCTAssertEqual(gift.occasionLink?.cardID, parent.id); XCTAssertEqual(gift.occasionLink?.date, anchor); XCTAssertFalse(gift.reminders.isEnabled)
        do {
            _ = try await repo.createPreparations(parentID: parent.id, revisionID: parent.revisionID, date: anchor, choices: [choices[1], choices[0]], now: now, calendar: calendar)
            XCTFail("A mixed duplicate batch must roll back together")
        } catch {}
        let library = try await repo.library(); XCTAssertEqual(library.cards.count, 2)
        XCTAssertEqual(library.cards.filter { $0.occasionLink != nil }.map(\.id), [gift.id])
    }
    func testChangedParentRequiresNewConfirmationAndPreservesExistingPreparations() async throws {
        let repo = try await repo(), commands = CardCommands(repository: repo)
        var card = try await commands.save(CardDraft(card: parent()), now: now)
        let originalRevision = card.revisionID, oldDate = CivilDate(year: 2026, month: 10, day: 18)
        let first = try await repo.createPreparations(parentID: card.id, revisionID: originalRevision, date: oldDate, choices: [PreparationChoice.suggestions(anniversary: false)[0]], now: now, calendar: calendar)
        card.birthday?.day = 20
        card = try await commands.save(CardDraft(card: card, isEditing: true), now: now)
        do { _ = try await repo.createPreparations(parentID: card.id, revisionID: originalRevision, date: oldDate, choices: [PreparationChoice.suggestions(anniversary: false)[1]], now: now, calendar: calendar); XCTFail("Stale parent must fail") } catch {}
        try await commands.setLifecycle(card: card, lifecycle: .deleted, now: now)
        let library = try await repo.library()
        XCTAssertEqual(library.cards.first { $0.id == first[0].id }, first[0]); XCTAssertEqual(library.cards.count, 2)
    }
    func testInvalidOrPastChoiceRejectsWholeBatchAndNoDateForClosedRule() async throws {
        let repo = try await repo(), commands = CardCommands(repository: repo)
        var card = try await commands.save(CardDraft(card: parent()), now: now)
        let choices = [PreparationChoice(id: "okay", title: "安排见面", daysBefore: 1), PreparationChoice(id: "past", title: "选礼物", daysBefore: 100)]
        do { _ = try await repo.createPreparations(parentID: card.id, revisionID: card.revisionID, date: CivilDate(year: 2026, month: 10, day: 18), choices: choices, now: now, calendar: calendar); XCTFail("Past preparation cannot be silently moved") } catch {}
        let library = try await repo.library(); XCTAssertEqual(library.cards.count, 1)
        card.recurrenceClosedAt = now; XCTAssertNil(OccasionPlanner.nextDate(for: card, now: now, calendar: calendar))
    }
    func testCalendarDayOffsetSurvivesDaylightSavingBoundary() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        var card = parent(); card.birthday?.month = 11; card.birthday?.day = 3
        let drafts = try OccasionPlanner.drafts(for: card, date: CivilDate(year: 2026, month: 11, day: 3), choices: [PreparationChoice(id: "gift", title: "准备礼物", daysBefore: 3)], now: now, calendar: calendar)
        XCTAssertEqual(drafts[0].card.schedule?.start, CivilDate(year: 2026, month: 10, day: 31)); XCTAssertEqual(drafts[0].card.schedule?.time, DayTime(hour: 9))
    }
    func testMemoriesBackupAndIndependentSharingPreservePrivateBoundaries() async throws {
        let source = try await repo(), commands = CardCommands(repository: source)
        let parent = try await commands.save(CardDraft(card: parent()), now: now)
        var memory = Card(title: "一起吃的生日面", kind: .note, now: now); memory.note = "好好记住这一刻"
        memory.memoryDate = now; memory.occasionLink = OccasionLink(cardID: parent.id, date: CivilDate(now, calendar: calendar))
        memory = try await commands.save(CardDraft(card: memory), now: now)
        let backup = try await source.exportBackup(now: now), destination = try await repo()
        _ = try await destination.restoreBackup(FileTransport.decodeBackup(FileTransport.encode(backup)), policy: .requireChoice, now: now)
        let restored = try await destination.library()
        XCTAssertEqual(MemoryCollection.cards(in: restored, occasionID: parent.id).first, memory)
        let shared = SharedCardSnapshot(card: memory, attachments: [], occurrence: nil, extent: .entireRule, includeNote: true, includePhotos: false)
        XCTAssertNil(shared.card.memoryDate); XCTAssertNil(shared.card.occasionLink)
        let package = SharePackage(session: ShareSession(snapshot: shared, recipientLabel: "朋友", feedback: false, now: now))
        let copy = package.independentCopy(now: now, scope: .local).0
        XCTAssertNil(copy.memoryDate); XCTAssertNil(copy.occasionLink); XCTAssertEqual(copy.note, memory.note)
    }
    func testMemoryFiltersExcludeDeletedAndUseChosenMemoryDateWithHalfOpenBounds() {
        var first = Card(title: "记录在之前，记忆在今天", kind: .note, now: now.addingTimeInterval(-86400)); first.memoryDate = now
        var next = Card(title: "下一期", kind: .note, now: now); next.memoryDate = now.addingTimeInterval(60)
        var deleted = first; deleted.id = UUID(); deleted.lifecycle = .deleted
        var library = LibrarySnapshot(); library.cards = [next, deleted, first, parent()]
        XCTAssertEqual(MemoryCollection.cards(in: library, interval: DateInterval(start: now, duration: 60)).map(\.id), [first.id])
    }
    func testScreenshotProposalKeepsSourceAndRequiresAmbiguousDateConfirmation() throws {
        let source = "预约名称：去看展\n2026-10-20 15:00\n地点：城市美术馆"
        let draft = try ScreenshotDraftBuilder.make(text: source, now: now, calendar: calendar)
        XCTAssertEqual(draft.card.title, "去看展"); XCTAssertEqual(draft.card.note, source); XCTAssertEqual(draft.originalText, source)
        XCTAssertEqual(draft.card.schedule?.start, CivilDate(year: 2026, month: 10, day: 20)); XCTAssertEqual(draft.card.schedule?.time, DayTime(hour: 15))
        let many = try ScreenshotDraftBuilder.make(text: "行程\n10月20日15:00出发\n10月22日返回", now: now, calendar: calendar)
        XCTAssertTrue(many.questions.contains(.ambiguousDates))
        XCTAssertThrowsError(try ScreenshotDraftBuilder.make(text: "  \n ", now: now, calendar: calendar))
        XCTAssertThrowsError(try ScreenshotDraftBuilder.make(text: String(repeating: "字", count: 2001), now: now, calendar: calendar))
    }
}
