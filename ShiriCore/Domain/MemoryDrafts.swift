import Foundation

/// Drafts use the existing device-only DraftRecord store, including their photo bytes.
public enum MemoryDrafts {
    public static func hasContent(_ draft: CardDraft) -> Bool {
        !draft.card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !draft.card.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !(draft.memorySpeechText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }

    public static func matching(_ drafts: [CardDraft], editingID: UUID?, source: MemoryCandidate?, previousID: UUID?, occasionID: UUID?) -> CardDraft? {
        drafts.filter { draft in
            guard draft.card.isMemory else { return false }
            if let editingID { return draft.isEditing && draft.card.id == editingID }
            guard !draft.isEditing else { return false }
            if let source {
                return draft.card.memory?.sourceCardID == source.card.id && draft.card.memory?.sourceOccurrenceID == source.occurrence?.id
            }
            return draft.card.memory?.sourceCardID == nil && draft.card.memory?.previousMemoryID == previousID && draft.card.occasionLink?.cardID == occasionID
        }.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    public static func title(_ draft: CardDraft) -> String {
        if !draft.card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return draft.card.title }
        let note = draft.card.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draft.memorySpeechText ?? "" : draft.card.note
        let suggested = MemoryFactory.suggestedTitle(note: note, hasPhotos: !draft.attachments.isEmpty)
        return suggested.isEmpty ? "未写完的回忆" : suggested
    }
}

public struct MemoryReunionSkip: Codable, Equatable, Sendable {
    public var day: CivilDate
    public var cardIDs: Set<UUID>
    public init(day: CivilDate, cardIDs: Set<UUID> = []) { self.day = day; self.cardIDs = cardIDs }
    public func skippedIDs(on date: Date, calendar: Calendar) -> Set<UUID> {
        day == CivilDate(date, calendar: calendar) ? cardIDs : []
    }
}
