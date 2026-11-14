import Foundation
@preconcurrency import CoreData

public struct ScopeRoute: Codable, Sendable { public var cardID: UUID; public var scope: DataScope }
public struct ScopeMigrationJournal: Identifiable, Codable, Sendable {
    public var id: UUID
    public var cardID: UUID
    public var source: DataScope
    public var destination: DataScope
    public var accountKey: String?
    public var fingerprint: String
    public var phase: String
    public var createdAt: Date
    public var retainsCloudSource: Bool?
}
extension ShiriRepository {
    public func migrateCard(_ cardID: UUID, to destination: DataScope, now: Date, retainCloudCopy: Bool = false) async throws {
        let journals = try await migrationJournals()
        if let pending = journals.first(where: { $0.cardID == cardID && $0.phase != "complete" && $0.accountKey == persistence.configuration.cloudAccountKey }) {
            guard pending.destination == destination else { throw ShiriError.conflict("这张卡片上次更改保存位置尚未完成，请先在 iCloud 设置中继续处理") }
            try await continueMigration(pending); return
        }
        guard let card = try await library().cards.first(where: { $0.id == cardID }) else { throw ShiriError.notFound }
        guard card.scope != destination else { return }
        let sourceStore = try persistence.store(for: card.scope)
        let destinationStore = try persistence.store(for: destination)
        let payload = try await cardPayload(cardID, store: sourceStore)
        let existing = try await cardPayload(cardID, store: destinationStore)
        let sourceFingerprint = try fingerprint(payload)
        let destinationFingerprint = try fingerprint(existing)
        guard existing.cards.isEmpty || destinationFingerprint == sourceFingerprint else {
            throw ShiriError.conflict("新的保存位置已有这张卡片，且内容不同。两份内容均已保留，请先备份并确认要保留哪一份。")
        }
        let journal = ScopeMigrationJournal(id: UUID(), cardID: cardID, source: card.scope, destination: destination,
                                            accountKey: persistence.configuration.cloudAccountKey, fingerprint: sourceFingerprint, phase: "prepared", createdAt: now, retainsCloudSource: retainCloudCopy && card.scope == .privateCloud)
        try await setDeviceValue(ScopeRoute(cardID: cardID, scope: card.scope), key: "route/\(cardID)")
        try await saveJournal(journal)
        try await continueMigration(journal)
    }
    public func resumeMigrations() async throws {
        for journal in try await migrationJournals() where journal.phase != "complete" && journal.accountKey == persistence.configuration.cloudAccountKey {
            guard (try? persistence.store(for: journal.source)) != nil, (try? persistence.store(for: journal.destination)) != nil else { continue }
            try await continueMigration(journal)
        }
    }
    private func continueMigration(_ input: ScopeMigrationJournal) async throws {
        var journal = input
        let source = try persistence.store(for: journal.source), destination = try persistence.store(for: journal.destination)
        if journal.phase == "prepared" {
            let payload = try await cardPayload(journal.cardID, store: source)
            guard try fingerprint(payload) == journal.fingerprint else { throw ShiriError.conflict("更改保存位置时卡片发生了变化，两份内容均已保留。请先确认要保留哪一份。") }
            try await transaction { context in try self.copy(payload, to: destination, scope: journal.destination, context: context) }
            let copied = try await cardPayload(journal.cardID, store: destination)
            guard try fingerprint(copied) == journal.fingerprint else { throw ShiriError.storage("未能完成保存位置的更改，原卡片已保留。请稍后重试。") }
            journal.phase = "verified"; try await saveJournal(journal)
        }
        if journal.phase == "verified" {
            let destinationPayload = try await cardPayload(journal.cardID, store: destination)
            guard try fingerprint(destinationPayload) == journal.fingerprint else { throw ShiriError.conflict("新位置的卡片发生了变化，原卡片仍然保留。") }
            let sourcePayload = try await cardPayload(journal.cardID, store: source)
            if !sourcePayload.cards.isEmpty, try fingerprint(sourcePayload) != journal.fingerprint { throw ShiriError.conflict("原卡片发生了变化，两份内容均已保留。") }
            try await setDeviceValue(ScopeRoute(cardID: journal.cardID, scope: journal.destination), key: "route/\(journal.cardID)")
            if journal.retainsCloudSource != true { try await transaction { context in try self.deleteAggregate(journal.cardID, store: source, context: context) } }
            journal.phase = "complete"; try await saveJournal(journal)
        }
    }
    public func migrationJournals() async throws -> [ScopeMigrationJournal] {
        let context = persistence.context(author: actorID)
        return try await context.perform { try DatabaseCodec.values(ScopeMigrationJournal.self, entity: "MigrationJournalRecord", context: context, stores: [self.deviceStore]) }
    }
    public func keepOriginalScope(for journalID: UUID) async throws {
        guard var journal = try await migrationJournals().first(where: { $0.id == journalID }), journal.phase != "complete" else { return }
        guard journal.accountKey == persistence.configuration.cloudAccountKey else { throw ShiriError.unavailable("请先连接更改保存位置时使用的 iCloud 账户") }
        let source = try persistence.store(for: journal.source)
        guard !(try await cardPayload(journal.cardID, store: source)).cards.isEmpty else { throw ShiriError.conflict("卡片已不在原保存位置，请在 iCloud 设置中继续完成保存") }
        try await setDeviceValue(ScopeRoute(cardID: journal.cardID, scope: journal.source), key: "route/\(journal.cardID)")
        // Keep both physical copies. Only the original route is visible and allowed to schedule.
        journal.phase = "complete"; try await saveJournal(journal)
    }
    private func saveJournal(_ journal: ScopeMigrationJournal) async throws {
        try await transaction { context in try DatabaseCodec.put(journal, entity: "MigrationJournalRecord", id: journal.id, context: context, store: self.deviceStore) }
    }
    func cardPayload(_ id: UUID, store: NSPersistentStore) async throws -> BackupPayload {
        let context = persistence.context(author: actorID)
        return try await context.perform {
            var library = LibrarySnapshot()
            let predicate = NSPredicate(format: "cardID == %@", id as NSUUID)
            library.cards = try DatabaseCodec.fetch("CardRecord", context: context, stores: [store], predicate: NSPredicate(format: "id == %@", id as NSUUID)).map(DatabaseCodec.card)
            library.revisions = try DatabaseCodec.values(CardRevision.self, entity: "CardRevisionRecord", context: context, stores: [store], predicate: predicate)
            library.occurrences = try DatabaseCodec.values(Occurrence.self, entity: "OccurrenceRecord", context: context, stores: [store], predicate: predicate)
            library.events = try DatabaseCodec.values(TaskEvent.self, entity: "TaskEventRecord", context: context, stores: [store], predicate: predicate)
            library.overrides = try DatabaseCodec.values(OccurrenceOverride.self, entity: "OccurrenceOverrideRecord", context: context, stores: [store], predicate: predicate)
            library.importLinks = try DatabaseCodec.values(ImportLink.self, entity: "ImportLinkRecord", context: context, stores: [store], predicate: predicate)
            let usedIDs = Set(library.cards.flatMap(\.attachmentIDs))
            let attachments = try DatabaseCodec.fetch("AttachmentRecord", context: context, stores: [store], predicate: predicate).map(DatabaseCodec.attachment).filter { usedIDs.contains($0.id) }
            return BackupPayload(library: library, attachments: attachments)
        }
    }
    private func fingerprint(_ payload: BackupPayload) throws -> String {
        var value = payload
        value.cards = value.cards.map { var card = $0; card.scope = .local; return card }.sorted { $0.id.uuidString < $1.id.uuidString }
        value.revisions = value.revisions.map { var revision = $0; revision.snapshot.scope = .local; return revision }.sorted { $0.id.uuidString < $1.id.uuidString }
        value.events.sort { $0.id.uuidString < $1.id.uuidString }; value.occurrences.sort { $0.id < $1.id }; value.overrides.sort { $0.id < $1.id }
        value.attachments.sort { $0.id.uuidString < $1.id.uuidString }; value.importLinks.sort { $0.id.uuidString < $1.id.uuidString }
        return StableID.digest(try FileTransport.encode(value))
    }
    func copy(_ payload: BackupPayload, to store: NSPersistentStore, scope: DataScope, context: NSManagedObjectContext) throws {
        for var card in payload.cards { card.scope = scope; try DatabaseCodec.write(card, context: context, store: store)
            if let schedule = card.schedule { try DatabaseCodec.put(schedule, entity: "ScheduleVersionRecord", id: schedule.id, context: context, store: store, fields: ["cardID":card.id]) }
        }
        for var revision in payload.revisions { revision.snapshot.scope = scope; try DatabaseCodec.put(revision, entity: "CardRevisionRecord", id: revision.id, context: context, store: store, fields: ["cardID":revision.cardID]) }
        for occurrence in payload.occurrences { try DatabaseCodec.put(occurrence, entity: "OccurrenceRecord", id: occurrence.id, context: context, store: store, fields: ["cardID":occurrence.cardID]) }
        for event in payload.events { try DatabaseCodec.put(event, entity: "TaskEventRecord", id: event.id, context: context, store: store, fields: ["cardID":event.cardID, "occurrenceID":event.occurrenceID, "operationID":event.operationID, "happenedAt":event.happenedAt, "kind":event.kind.rawValue]) }
        for override in payload.overrides { try DatabaseCodec.put(override, entity: "OccurrenceOverrideRecord", id: override.id, context: context, store: store, fields: ["cardID":override.cardID]) }
        for attachment in payload.attachments { try DatabaseCodec.write(attachment, context: context, store: store) }
        for link in payload.importLinks { try DatabaseCodec.put(link, entity: "ImportLinkRecord", id: link.id, context: context, store: store, fields: ["cardID":link.cardID, "sessionID":link.sessionID]) }
    }
    func deleteAggregate(_ id: UUID, store: NSPersistentStore, context: NSManagedObjectContext) throws {
        for entity in ["CardRecord", "CardRevisionRecord", "ScheduleVersionRecord", "OccurrenceRecord", "TaskEventRecord", "OccurrenceOverrideRecord", "AttachmentRecord", "ImportLinkRecord"] {
            let predicate = NSPredicate(format: "\(entity == "CardRecord" ? "id" : "cardID") == %@", id as NSUUID)
            for object in try DatabaseCodec.fetch(entity, context: context, stores: [store], predicate: predicate) { context.delete(object) }
        }
    }
}
