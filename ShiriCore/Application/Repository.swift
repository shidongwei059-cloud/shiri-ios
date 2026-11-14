import Foundation
import CoreData

public struct LibrarySnapshot: Equatable, Sendable {
    public var cards: [Card] = []
    public var events: [TaskEvent] = []
    public var occurrences: [Occurrence] = []
    public var overrides: [OccurrenceOverride] = []
    public var revisions: [CardRevision] = []
    public var importLinks: [ImportLink] = []
    public var personalStates: [String: PersonalReminderState] = [:]
    public var personalReminderEvents: [PersonalReminderEvent] = []
    public var conflicts: [UUID: [CardRevision]] = [:]
    public init() {}
    public func events(for occurrenceID: String) -> [TaskEvent] { events.filter { $0.occurrenceID == occurrenceID } }
    public static func == (lhs: LibrarySnapshot, rhs: LibrarySnapshot) -> Bool {
        // Fetch ordering is not a content change, including conflicts with multiple revision heads.
        lhs.cards.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.cards.sorted { $0.id.uuidString < $1.id.uuidString } &&
        lhs.events.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.events.sorted { $0.id.uuidString < $1.id.uuidString } &&
        lhs.occurrences.sorted { $0.id < $1.id } == rhs.occurrences.sorted { $0.id < $1.id } &&
        lhs.overrides.sorted { $0.id < $1.id } == rhs.overrides.sorted { $0.id < $1.id } &&
        lhs.revisions.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.revisions.sorted { $0.id.uuidString < $1.id.uuidString } &&
        lhs.importLinks.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.importLinks.sorted { $0.id.uuidString < $1.id.uuidString } &&
        lhs.personalStates == rhs.personalStates &&
        lhs.personalReminderEvents.sorted { $0.id.uuidString < $1.id.uuidString } == rhs.personalReminderEvents.sorted { $0.id.uuidString < $1.id.uuidString } &&
        lhs.conflicts.mapValues { $0.sorted { $0.id.uuidString < $1.id.uuidString } } == rhs.conflicts.mapValues { $0.sorted { $0.id.uuidString < $1.id.uuidString } }
    }
}

public final class ShiriRepository: @unchecked Sendable {
    public let persistence: PersistenceController
    public let actorID: String
    public init(persistence: PersistenceController, actorID: String) { self.persistence = persistence; self.actorID = actorID }
    var cardStores: [NSPersistentStore] { [persistence.stores[.local], persistence.stores[.personal]].compactMap { $0 } }
    var deviceStore: NSPersistentStore {
        get throws {
            guard let store = persistence.stores[.device] else { throw ShiriError.unavailable("正在更改保存位置，请稍后再试") }
            return store
        }
    }

    public func library(cardID: UUID? = nil) async throws -> LibrarySnapshot {
        let context = persistence.context(author: actorID)
        return try await context.perform { try self.library(in: context, cardID: cardID) }
    }
    func library(in context: NSManagedObjectContext, cardID: UUID? = nil) throws -> LibrarySnapshot {
            var snapshot = LibrarySnapshot()
            let cardPredicate = cardID.map { NSPredicate(format: "id == %@", $0 as NSUUID) }
            let recordPredicate = cardID.map { NSPredicate(format: "cardID == %@", $0 as NSUUID) }
            let routePredicate = cardID.map { NSPredicate(format: "id == %@", "route/\($0)") } ?? NSPredicate(format: "id BEGINSWITH %@", "route/")
            // Resolve the canonical revision before decoding a second copy of its embedded values.
            // Older records and unresolved conflicts still use the complete stored card below.
            var storedCards = try DatabaseCodec.fetch("CardRecord", context: context, stores: self.cardStores, predicate: cardPredicate).map {
                (object: $0, card: try DatabaseCodec.card($0, includesEmbeddedValues: false))
            }
            let routes = try DatabaseCodec.values(ScopeRoute.self, entity: "DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: routePredicate)
            let routeMap = Dictionary(routes.map { ($0.cardID, $0.scope) }, uniquingKeysWith: { _, latest in latest })
            storedCards.removeAll { row in routeMap[row.card.id].map { $0 != row.card.scope } ?? false }
            snapshot.events = try DatabaseCodec.routedValues(TaskEvent.self, entity: "TaskEventRecord", context: context, stores: self.cardStores, routes: routeMap, predicate: recordPredicate)
            snapshot.occurrences = try DatabaseCodec.routedValues(Occurrence.self, entity: "OccurrenceRecord", context: context, stores: self.cardStores, routes: routeMap, predicate: recordPredicate)
            snapshot.overrides = try DatabaseCodec.routedValues(OccurrenceOverride.self, entity: "OccurrenceOverrideRecord", context: context, stores: self.cardStores, routes: routeMap, predicate: recordPredicate)
            snapshot.revisions = try DatabaseCodec.routedValues(CardRevision.self, entity: "CardRevisionRecord", context: context, stores: self.cardStores, routes: routeMap, predicate: recordPredicate)
            snapshot.importLinks = try DatabaseCodec.routedValues(ImportLink.self, entity: "ImportLinkRecord", context: context, stores: self.cardStores, routes: routeMap, predicate: recordPredicate)
            let states = try DatabaseCodec.values(PersonalReminderState.self, entity: "DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id BEGINSWITH %@", "reminder/"))
            snapshot.personalStates = Dictionary(states.map { ($0.occurrenceID, $0) }, uniquingKeysWith: { a,b in a.updatedAt > b.updatedAt ? a : b })
            snapshot.personalReminderEvents = try DatabaseCodec.values(PersonalReminderEvent.self, entity: "PersonalEventRecord", context: context, stores: [self.deviceStore])
            snapshot.events = Self.unique(snapshot.events, id: \.id)
            snapshot.occurrences = Self.unique(snapshot.occurrences, id: \.id)
            snapshot.revisions = Self.unique(snapshot.revisions, id: \.id)
            snapshot.importLinks = Self.unique(snapshot.importLinks, id: \.id)
            let grouped = Dictionary(grouping: snapshot.revisions, by: \.cardID)
            var seenCardIDs: Set<UUID> = []
            snapshot.cards = try storedCards.sorted { $0.card.updatedAt > $1.card.updatedAt }.filter {
                seenCardIDs.insert($0.card.id).inserted
            }.map { row in
                let stored = row.card
                let revisions = grouped[stored.id] ?? []
                let parents = Set(revisions.flatMap(\.parents))
                let heads = revisions.filter { !parents.contains($0.id) }
                if heads.count == 1 { var card = heads[0].snapshot; card.scope = stored.scope; return card }
                if heads.count > 1 {
                    snapshot.conflicts[stored.id] = heads
                    if let confirmed = try? DatabaseCodec.values(Card.self, entity: "DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id == %@", "confirmed/\(stored.id)")).first { var card = confirmed; card.scope = stored.scope; return card }
                }
                // A conflict does not silently replace the device's last confirmed reminder plan.
                return try DatabaseCodec.card(row.object)
            }.sorted { $0.updatedAt > $1.updatedAt }
            return snapshot
    }
    public func attachments(cardID: UUID) async throws -> [Attachment] {
        let context = persistence.context(author: actorID)
        return try await context.perform {
            let route = try DatabaseCodec.values(ScopeRoute.self, entity: "DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id == %@", "route/\(cardID)")).first
            let stores = try route.map { [try self.persistence.store(for: $0.scope)] } ?? self.cardStores
            return Self.unique(try DatabaseCodec.fetch("AttachmentRecord", context: context, stores: stores, predicate: NSPredicate(format: "cardID == %@", cardID as NSUUID)).map(DatabaseCodec.attachment), id: \.id).sorted { $0.sortIndex < $1.sortIndex }
        }
    }
    public func save(_ input: Card, attachments: [Attachment] = [], parents: [UUID], now: Date, imported: ImportLink? = nil, stoppingFeedback: [ImportLink] = [], expectedRevisionIDs: [UUID]? = nil) async throws -> Card {
        var card = try input.validated(); card.updatedAt = now
        for attachment in attachments { try attachment.validate(); guard attachment.cardID == card.id else { throw ShiriError.validation("图片不属于这张卡片") } }
        guard stoppingFeedback.allSatisfy({ $0.cardID == card.id }) else { throw ShiriError.validation("状态反馈不属于这张卡片") }
        let store = try persistence.store(for: card.scope)
        let revision = CardRevision(card: card, parents: parents, actorID: actorID, now: now)
        try await transaction { context in
            if let expectedRevisionIDs {
                // Check again in the writing context. A later optimistic-locking retry must
                // recheck these same heads rather than overwrite a newly committed version.
                let current = try self.library(in: context, cardID: card.id)
                let existing = current.cards.first
                let heads = current.conflicts[card.id]?.map(\.id) ?? existing.map { [$0.revisionID] } ?? []
                guard Set(heads) == Set(expectedRevisionIDs), existing == nil || existing?.scope == card.scope else {
                    throw ShiriError.conflict("保存时卡片发生了变化，请重新打开后再编辑。草稿仍然保留。")
                }
            }
            try DatabaseCodec.write(card, context: context, store: store)
            try DatabaseCodec.put(revision, entity: "CardRevisionRecord", id: revision.id, context: context, store: store, fields: ["cardID":card.id])
            if let schedule = card.schedule { try DatabaseCodec.put(schedule, entity: "ScheduleVersionRecord", id: schedule.id, context: context, store: store, fields: ["cardID":card.id]) }
            for attachment in attachments { try DatabaseCodec.write(attachment, context: context, store: store) }
            if let imported { try DatabaseCodec.put(imported, entity: "ImportLinkRecord", id: imported.id, context: context, store: store, fields: ["cardID":card.id, "sessionID":imported.sessionID]) }
            for link in stoppingFeedback { try self.writeStoppedFeedback(link, now: now, context: context, store: store) }
        }
        return card
    }
    func transaction<T>(retryOnConflict: Bool = true, _ work: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        var lastError: Error = ShiriError.storage("保存失败")
        for _ in 0..<3 {
            let context = persistence.context(author: actorID)
            do { return try await context.perform { let result = try work(context); if context.hasChanges { try context.save() }; return result } }
            catch { lastError = error; if !retryOnConflict || (error as NSError).domain != NSCocoaErrorDomain || ![NSManagedObjectMergeError, NSPersistentStoreSaveConflictsError].contains((error as NSError).code) { throw error } }
        }
        throw lastError
    }
    static func unique<T, ID: Hashable>(_ values: [T], id: KeyPath<T, ID>) -> [T] {
        var seen: Set<ID> = []; return values.filter { seen.insert($0[keyPath: id]).inserted }
    }
}
