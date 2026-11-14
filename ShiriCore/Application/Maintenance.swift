import Foundation
@preconcurrency import CoreData

extension ShiriRepository {
    public func setSystemBackupExcluded(_ excluded: Bool) throws {
        let fm = FileManager.default
        var root = URL(fileURLWithPath: persistence.configuration.directory.path, isDirectory: true)
        let marker = root.appendingPathComponent("SystemBackupExcluded")
        var values = URLResourceValues(); values.isExcludedFromBackup = excluded
        try root.setResourceValues(values)
        // Also mark existing SQLite sidecars and external binary-data directories explicitly.
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case var url as URL in enumerator {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants(); continue }
                try url.setResourceValues(values)
            }
        }
        if excluded { try Data("1".utf8).write(to: marker, options: .atomic) }
        else if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
    }
    public func deleteAllCards(in scope: DataScope, now: Date) async throws -> Int {
        let library = try await library()
        let routedIDs = Set(library.cards.filter { $0.scope == scope }.map(\.id))
        for link in library.importLinks where routedIDs.contains(link.cardID) && link.feedbackConsent { try await stopFeedback(link: link, now: now) }
        let store = try persistence.store(for: scope)
        return try await transaction { context in
            let cards = try DatabaseCodec.fetch("CardRecord", context: context, stores: [store])
            let count = cards.count
            for entity in ["CardRecord", "CardRevisionRecord", "ScheduleVersionRecord", "OccurrenceRecord", "TaskEventRecord", "OccurrenceOverrideRecord", "AttachmentRecord", "ImportLinkRecord"] {
                for row in try DatabaseCodec.fetch(entity, context: context, stores: [store]) { context.delete(row) }
            }
            for id in routedIDs {
                for key in ["route/\(id)", "confirmed/\(id)"] {
                    for row in try DatabaseCodec.fetch("DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id == %@", key)) { context.delete(row) }
                }
            }
            if scope == .local {
                for row in try DatabaseCodec.fetch("DraftRecord", context: context, stores: [self.deviceStore]) { context.delete(row) }
            }
            return count
        }
    }
    public func searchCardIDs(_ query: String, limit: Int = 10_000) async throws -> Set<UUID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = persistence.context(author: actorID)
        return try await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "CardRecord"); request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]; request.affectedStores = self.cardStores; request.fetchLimit = max(1, min(100_000,limit))
            if !trimmed.isEmpty { request.predicate = NSPredicate(format: "title CONTAINS[cd] %@ OR note CONTAINS[cd] %@",trimmed,trimmed) }
            return Set(try context.fetch(request).compactMap { $0["id"] as? UUID })
        }
    }
    public func personalReminderEvents() async throws -> [PersonalReminderEvent] {
        let context = persistence.context(author: actorID)
        return try await context.perform { try DatabaseCodec.values(PersonalReminderEvent.self, entity: "PersonalEventRecord", context: context, stores: [self.deviceStore]) }
    }
    public func purgeExpiredTrash(now: Date, calendar: Calendar) async throws -> Int {
        let threshold = calendar.date(byAdding: .day, value: -AppLimits.trashRetentionDays, to: now)!
        let context = persistence.context(author: actorID)
        let hasCandidates = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "CardRecord")
            request.affectedStores = self.cardStores; request.fetchLimit = 1
            request.predicate = NSPredicate(format: "lifecycle == %@ AND deletedAt < %@", CardLifecycle.deleted.rawValue, threshold as NSDate)
            return try !context.fetch(request).isEmpty
        }
        // Avoid decoding every card and event at each launch when there is no expired trash.
        // When candidates exist, canonical revision/route resolution still decides deletion.
        guard hasCandidates else { return 0 }
        let expired = try await library().cards.filter { $0.lifecycle == .deleted && ($0.deletedAt ?? .distantFuture) < threshold }
        for card in expired { try await permanentlyDelete(cardID: card.id, now: now) }
        return expired.count
    }
    public func permanentlyDelete(cardID: UUID, now: Date) async throws {
        let snapshot = try await library()
        guard let card = snapshot.cards.first(where: { $0.id == cardID }), card.lifecycle == .deleted else { throw ShiriError.validation("请先将卡片移到最近删除") }
        for link in snapshot.importLinks where link.cardID == cardID && link.feedbackConsent { try await stopFeedback(link: link, now: now) }
        let store = try persistence.store(for: card.scope)
        try await transaction { context in
            for entity in ["CardRevisionRecord","ScheduleVersionRecord","OccurrenceRecord","TaskEventRecord","OccurrenceOverrideRecord","AttachmentRecord","ImportLinkRecord"] {
                for row in try DatabaseCodec.fetch(entity,context: context,stores: [store],predicate: NSPredicate(format: "cardID == %@",cardID as NSUUID)) { context.delete(row) }
            }
            for row in try DatabaseCodec.fetch("CardRecord",context: context,stores: [store],predicate: NSPredicate(format: "id == %@",cardID as NSUUID)) { context.delete(row) }
            for key in ["route/\(cardID)","confirmed/\(cardID)"] {
                for row in try DatabaseCodec.fetch("DeviceValueRecord",context: context,stores: [self.deviceStore],predicate: NSPredicate(format: "id == %@",key)) { context.delete(row) }
            }
        }
    }
}
