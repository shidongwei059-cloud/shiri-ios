import Foundation
import CoreData

/// An independent note owns its content and attachments. Source identifiers are links only.
public struct MemoryMetadata: Codable, Equatable, Sendable {
    public var sourceCardID: UUID?
    public var sourceOccurrenceID: String?
    public var sourceTitle: String?
    public var previousMemoryID: UUID?
    public var excludedFromReunion: Bool
    public init(sourceCardID: UUID? = nil, sourceOccurrenceID: String? = nil, sourceTitle: String? = nil, previousMemoryID: UUID? = nil, excludedFromReunion: Bool = false) {
        self.sourceCardID = sourceCardID; self.sourceOccurrenceID = sourceOccurrenceID
        self.sourceTitle = sourceTitle; self.previousMemoryID = previousMemoryID; self.excludedFromReunion = excludedFromReunion
    }
}

public struct MemoryCandidate: Identifiable, Sendable {
    public var id: String { occurrence?.id ?? card.id.uuidString }
    public let card: Card
    public let occurrence: Occurrence?
    public let date: Date
    public var title: String { occurrence?.snapshot.title ?? card.title }
    public init(card: Card, occurrence: Occurrence? = nil, date: Date) { self.card = card; self.occurrence = occurrence; self.date = date }
}

public enum MemoryFactory {
    public static func draft(from source: Card, attachments: [Attachment], occurrence: Occurrence? = nil, date: Date, now: Date, id: UUID = UUID()) throws -> CardDraft {
        guard occurrence == nil || occurrence?.cardID == source.id else { throw ShiriError.validation("回忆来源与这次经历不一致") }
        var card = Card(id: id, title: occurrence?.snapshot.title ?? source.title, kind: .note, now: now)
        card.note = source.note; card.category = occurrence?.snapshot.category ?? source.category
        card.memoryDate = date; card.appearance = source.appearance; card.occasionLink = source.occasionLink
        card.memory = MemoryMetadata(sourceCardID: source.id, sourceOccurrenceID: occurrence?.id, sourceTitle: card.title)
        if source.birthday != nil { card.occasionLink = OccasionLink(cardID: source.id, date: CivilDate(date, calendar: .current)) }
        var copied: [Attachment] = []
        for (index, originalID) in source.attachmentIDs.enumerated() {
            guard let original = attachments.first(where: { $0.id == originalID && $0.cardID == source.id }) else {
                throw ShiriError.storage("来源照片尚未读取完整，请稍后重试；原记录已保留")
            }
            try original.validate()
            let photo = Attachment(id: StableID.uuid("memory-photo|\(id)|\(originalID)"), cardID: id, data: original.data, width: original.width, height: original.height, mediaType: original.mediaType, sortIndex: index)
            copied.append(photo)
            if card.appearance.backgroundAttachmentID == originalID { card.appearance.backgroundAttachmentID = photo.id }
        }
        card.attachmentIDs = copied.map(\.id)
        var draft = CardDraft(card: try card.validated()); draft.attachments = copied
        return draft
    }

    public static func suggestedTitle(note: String, hasPhotos: Bool) -> String {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = text.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n")).first ?? text
        guard !first.isEmpty else { return hasPhotos ? "照片里的这一天" : "" }
        guard first.count > 24 else { return first }
        let prefix = String(first.prefix(24))
        // Prefer a phrase boundary; avoid cutting an English word in half.
        if let boundary = prefix.lastIndex(where: { "，,；;、 ".contains($0) }), prefix.distance(from: prefix.startIndex, to: boundary) >= 6 {
            return String(prefix[..<boundary]).trimmingCharacters(in: .whitespaces)
        }
        let firstWord = first.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "'-_".contains($0)) }
        if firstWord.count > 24 && firstWord.count <= AppLimits.titleLength { return String(firstWord) }
        return prefix + "…"
    }
}

extension MemoryCollection {
    public static func candidate(for card: Card, occurrence: Occurrence?, in library: LibrarySnapshot, now: Date) -> MemoryCandidate {
        if var occurrence,
           let completed = EventReducer.completion(events: library.events.filter { $0.occurrenceID == occurrence.id && $0.happenedAt <= now }) {
            occurrence.snapshot = completed.snapshot
            return MemoryCandidate(card: card, occurrence: occurrence, date: completed.happenedAt)
        }
        return MemoryCandidate(card: card, occurrence: occurrence, date: card.kind == .note ? min(card.createdAt, now) : now)
    }
    public static func candidates(in library: LibrarySnapshot, interval: DateInterval? = nil, now: Date) -> [MemoryCandidate] {
        let sources = Dictionary(library.cards.filter { !$0.isMemory && $0.lifecycle != .deleted }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let occurrences = Dictionary(library.occurrences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let events = Dictionary(grouping: library.events.filter { $0.happenedAt <= now }, by: \.occurrenceID)
        var result: [MemoryCandidate] = events.values.compactMap { history in
            guard let completed = EventReducer.completion(events: history), let card = sources[completed.cardID],
                  interval?.containsHalfOpen(completed.happenedAt) ?? true,
                  var occurrence = occurrences[completed.occurrenceID] else { return nil }
            occurrence.snapshot = completed.snapshot
            return MemoryCandidate(card: card, occurrence: occurrence, date: completed.happenedAt)
        }
        result += sources.values.filter { $0.kind == .note && $0.birthday == nil && (interval?.containsHalfOpen($0.createdAt) ?? true) && $0.createdAt <= now }.map { MemoryCandidate(card: $0, date: $0.createdAt) }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    public static func savedMemory(for candidate: MemoryCandidate, in cards: [Card]) -> Card? {
        cards.first { $0.lifecycle != .deleted && $0.memory?.sourceCardID == candidate.card.id && $0.memory?.sourceOccurrenceID == candidate.occurrence?.id }
    }

    public static func filtered(_ cards: [Card], query: String = "", category: String? = nil, interval: DateInterval? = nil) -> [Card] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return cards.filter { card in
            guard card.lifecycle != .deleted, let date = card.memoryDate,
                  category == nil || card.category == category,
                  interval?.containsHalfOpen(date) ?? true else { return false }
            let content = [card.title, card.note, card.category, card.memory?.sourceTitle ?? ""].joined(separator: "\n")
            return terms.allSatisfy { content.localizedStandardContains($0) }
        }
    }

    /// A stable daily choice: anniversaries first, then a quiet rotation of older memories.
    public static func reunion(in cards: [Card], now: Date, calendar: Calendar, skippedIDs: Set<UUID> = []) -> Card? {
        let today = calendar.startOfDay(for: now)
        let eligible = cards.filter { $0.lifecycle == .active && $0.memory?.excludedFromReunion != true && !skippedIDs.contains($0.id) && ($0.memoryDate ?? .distantFuture) < today }
        let anniversary = eligible.filter { card in
            guard let date = card.memoryDate else { return false }
            return calendar.component(.month, from: date) == calendar.component(.month, from: today) && calendar.component(.day, from: date) == calendar.component(.day, from: today)
        }.sorted { ($0.memoryDate ?? .distantPast, $0.id.uuidString) < ($1.memoryDate ?? .distantPast, $1.id.uuidString) }
        if let first = anniversary.first { return first }
        let older = eligible.filter { calendar.dateComponents([.day], from: $0.memoryDate!, to: today).day ?? 0 >= 7 }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard !older.isEmpty else { return nil }
        let key = CivilDate(today, calendar: calendar).key
        let offset = key.utf8.reduce(0) { ($0 * 31 + Int($1)) % older.count }
        return older[offset]
    }
}

extension ShiriRepository {
    /// Copies old bookmarks and their images atomically, leaving the original card intact.
    /// Deterministic IDs make retries and repeated imports safe; deleted copies stay deleted.
    public func migrateLegacyMemories(now: Date) async throws -> Int {
        try await transaction { context in
            let library = try self.library(in: context)
            let legacy = library.cards.filter { $0.memoryDate != nil && $0.memory == nil && $0.lifecycle != .deleted && library.conflicts[$0.id] == nil }
            var count = 0
            for source in legacy {
                let id = StableID.uuid("legacy-memory|\(source.id)")
                let store = try self.persistence.store(for: source.scope)
                if !library.cards.contains(where: { $0.id == id }) {
                    let photos = try DatabaseCodec.fetch("AttachmentRecord", context: context, stores: [store], predicate: NSPredicate(format: "cardID == %@", source.id as NSUUID)).map(DatabaseCodec.attachment)
                    var draft = try MemoryFactory.draft(from: source, attachments: photos, date: source.memoryDate!, now: source.updatedAt, id: id)
                    draft.card.revisionID = StableID.uuid("legacy-memory-revision|\(source.revisionID)")
                    draft.card.scope = source.scope; draft.card.lifecycle = source.lifecycle
                    let revision = CardRevision(card: draft.card, parents: [], actorID: "memory-migration-v1", now: source.updatedAt)
                    try DatabaseCodec.write(draft.card, context: context, store: store)
                    try DatabaseCodec.put(revision, entity: "CardRevisionRecord", id: revision.id, context: context, store: store, fields: ["cardID": id])
                    for photo in draft.attachments { try DatabaseCodec.write(photo, context: context, store: store) }
                    count += 1
                }
                var original = source; original.memoryDate = nil; original.revisionID = StableID.uuid("legacy-memory-source|\(source.revisionID)")
                let revision = CardRevision(card: original, parents: [source.revisionID], actorID: "memory-migration-v1", now: source.updatedAt)
                try DatabaseCodec.write(original, context: context, store: store)
                try DatabaseCodec.put(revision, entity: "CardRevisionRecord", id: revision.id, context: context, store: store, fields: ["cardID": source.id])
            }
            return count
        }
    }
}
