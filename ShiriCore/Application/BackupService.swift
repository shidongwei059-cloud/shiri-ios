import Foundation
import CoreData

public struct BackupPayload: Codable, Equatable, Sendable {
    public var cards: [Card]
    public var revisions: [CardRevision]
    public var occurrences: [Occurrence]
    public var events: [TaskEvent]
    public var overrides: [OccurrenceOverride]
    public var attachments: [Attachment]
    public var importLinks: [ImportLink]
    public init(library: LibrarySnapshot, attachments: [Attachment]) {
        cards = library.cards; revisions = library.revisions; occurrences = library.occurrences; events = library.events
        overrides = library.overrides; self.attachments = attachments
        importLinks = library.importLinks.map { var link = $0; link.feedbackAccountKey = nil; return link }
    }
    public func validate() throws {
        guard cards.count <= 100_000, events.count <= 2_000_000, attachments.count <= cards.count * AppLimits.attachmentCount else { throw ShiriError.invalidFile("备份记录数量超出支持范围") }
        let cardIDs = Set(cards.map(\.id)); let attachmentIDs = Set(attachments.map(\.id))
        guard Set(events.map(\.id)).count == events.count, Set(events.map(\.operationID)).count == events.count,
              Set(occurrences.map(\.id)).count == occurrences.count, Set(revisions.map(\.id)).count == revisions.count,
              Set(overrides.map(\.id)).count == overrides.count, Set(importLinks.map(\.id)).count == importLinks.count else { throw ShiriError.invalidFile("备份中有重复记录，暂时无法恢复。请选择其他备份文件。") }
        let occurrenceMap = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.id, $0) })
        let eventMap = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        guard events.allSatisfy({ event in
            occurrenceMap[event.occurrenceID]?.cardID == event.cardID && event.reverses.allSatisfy { reference in
                guard let original = eventMap[reference] else { return false }
                return original.cardID == event.cardID && original.occurrenceID == event.occurrenceID &&
                    ((event.kind == .reopened && original.kind == .completed) || (event.kind == .unskipped && original.kind == .skipped))
            }
        }), overrides.allSatisfy({ value in value.original.map { $0.id == value.occurrenceID && $0.cardID == value.cardID } ?? true }) else { throw ShiriError.invalidFile("备份中的完成或改期记录不完整，暂时无法恢复。") }
        guard cardIDs.count == cards.count, attachmentIDs.count == attachments.count,
              events.allSatisfy({ cardIDs.contains($0.cardID) }), occurrences.allSatisfy({ cardIDs.contains($0.cardID) }),
              revisions.allSatisfy({ cardIDs.contains($0.cardID) && $0.snapshot.id == $0.cardID }),
              overrides.allSatisfy({ cardIDs.contains($0.cardID) }), importLinks.allSatisfy({ cardIDs.contains($0.cardID) }) else { throw ShiriError.invalidFile("备份内容不完整或有重复记录，暂时无法恢复。") }
        for card in cards {
            _ = try card.validated()
            guard Set(card.attachmentIDs).isSubset(of: attachmentIDs), attachments.filter({ card.attachmentIDs.contains($0.id) }).allSatisfy({ $0.cardID == card.id }) else { throw ShiriError.invalidFile("备份中有图片缺失或归属不正确") }
        }
        for attachment in attachments { try attachment.validate(); guard cardIDs.contains(attachment.cardID) else { throw ShiriError.invalidFile("部分图片无法对应到卡片，暂时无法恢复。") } }
    }
}
public struct BackupDocument: Codable, Sendable {
    public var format = "app.nianyi.backup"
    public var version = 1
    public var exportedAt: Date
    public var payload: BackupPayload
    public var digest: String
    public init(payload: BackupPayload, now: Date) throws {
        self.payload = payload; exportedAt = now; digest = StableID.digest(try FileTransport.encoder().encode(payload))
    }
    public func validate() throws {
        guard format == "app.nianyi.backup", version == 1 else { throw ShiriError.invalidFile("暂时无法读取这份备份，请选择其他备份文件。") }
        guard StableID.digest(try FileTransport.encoder().encode(payload)) == digest else { throw ShiriError.invalidFile("备份可能不完整或已被修改，请重新导出后再试。") }
        try payload.validate()
    }
}
public enum FileTransport {
    public static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    public static func decodeShare(_ data: Data) throws -> SharePackage {
        guard data.count <= AppLimits.shareBytes else { throw ShiriError.invalidFile("日程文件过大") }
        do { let package = try JSONDecoder().decode(SharePackage.self, from: data); try package.validate(); return package }
        catch let error as ShiriError { throw error }
        catch { throw ShiriError.invalidFile("无法读取这份日程，请选择拾日导出的日程文件") }
    }
    public static func decodeBackup(_ data: Data) throws -> BackupDocument {
        guard data.count <= AppLimits.backupBytes else { throw ShiriError.invalidFile("备份超过 200 MB，无法导入") }
        do { let backup = try JSONDecoder().decode(BackupDocument.self, from: data); try backup.validate(); return backup }
        catch let error as ShiriError { throw error }
        catch { throw ShiriError.invalidFile("备份格式不正确，现有数据没有改变") }
    }
    public static func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else { throw ShiriError.invalidFile("文件类型或大小不符合要求") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit else { throw ShiriError.invalidFile("文件过大") }; return data
    }
}
public enum BackupConflictPolicy: Sendable { case requireChoice, keepExisting, replaceMatching }

public struct BackupRestorePreview: Equatable, Sendable {
    public let newCount: Int
    public let matchingCount: Int
    public let cloudMatchingCount: Int
    private let sourceState: LibrarySnapshot
    private let backupDigest: String
    init(backup: BackupDocument, current: LibrarySnapshot) {
        let existing = Set(current.cards.map(\.id))
        let incoming = Set(backup.payload.cards.map(\.id))
        newCount = incoming.subtracting(existing).count
        matchingCount = incoming.intersection(existing).count
        cloudMatchingCount = current.cards.filter { incoming.contains($0.id) && $0.scope == .privateCloud }.count
        sourceState = current; backupDigest = backup.digest
    }
}

public struct BackupRecoveryPoint: Identifiable, Sendable {
    public let id: String
    public let createdAt: Date
    public let byteCount: Int
}


extension ShiriRepository {
    public func exportBackup(now: Date) async throws -> BackupDocument {
        let snapshot = try await library(); var allAttachments: [Attachment] = []
        for card in snapshot.cards { allAttachments += try await attachments(cardID: card.id).filter { card.attachmentIDs.contains($0.id) } }
        let payload = BackupPayload(library: snapshot, attachments: Self.unique(allAttachments, id: \.id))
        try payload.validate(); return try BackupDocument(payload: payload, now: now)
    }
    public func previewBackup(_ backup: BackupDocument) async throws -> BackupRestorePreview {
        try backup.validate()
        return BackupRestorePreview(backup: backup, current: try await library())
    }

    /// Recovery points are durable user data, not disposable export files.
    public func recoveryPoints() throws -> [BackupRecoveryPoint] {
        let folder = persistence.configuration.directory.appendingPathComponent("Recovery", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]).compactMap { url in
            guard Self.isRecoveryPointName(url.lastPathComponent) else { return nil }
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true else { return nil }
            return BackupRecoveryPoint(id: url.lastPathComponent, createdAt: value.contentModificationDate ?? .distantPast, byteCount: value.fileSize ?? 0)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func recoveryBackup(id: String) throws -> BackupDocument {
        guard Self.isRecoveryPointName(id) else { throw ShiriError.invalidFile("恢复点名称无效") }
        let url = persistence.configuration.directory.appendingPathComponent("Recovery", isDirectory: true).appendingPathComponent(id)
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ShiriError.invalidFile("恢复点文件无效") }
        return try FileTransport.decodeBackup(FileTransport.read(url, limit: AppLimits.backupBytes))
    }
    @discardableResult public func createRecoveryPoint(now: Date) async throws -> BackupRecoveryPoint {
        try writeRecoveryPoint(try await exportBackup(now: now), now: now)
    }
    private func writeRecoveryPoint(_ backup: BackupDocument, now: Date) throws -> BackupRecoveryPoint {
        let data = try FileTransport.encode(backup)
        guard data.count <= AppLimits.backupBytes else { throw ShiriError.storage("当前数据超过恢复点大小限制，尚未替换任何卡片。请先单独备份和整理数据。") }
        let folder = persistence.configuration.directory.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "BeforeRestore-\(UUID().uuidString).nianyibackup"
        let url = folder.appendingPathComponent(id)
        try data.write(to: url, options: .atomic)
        // Verify the durable file before allowing the replacement transaction to start.
        _ = try recoveryBackup(id: id)
        return BackupRecoveryPoint(id: id, createdAt: now, byteCount: data.count)
    }
    private static func isRecoveryPointName(_ value: String) -> Bool {
        let prefix = "BeforeRestore-", suffix = ".nianyibackup"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return false }
        return UUID(uuidString: String(value.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }
    public func restoreBackup(_ backup: BackupDocument, policy: BackupConflictPolicy, now: Date, expectedPreview: BackupRestorePreview? = nil) async throws -> Int {
        try await restoreBackup(backup, policy: policy, now: now, expectedPreview: expectedPreview, beforeReplacement: nil)
    }
    /// The callback is an internal synchronization seam for deterministic concurrent-write tests.
    func restoreBackup(_ backup: BackupDocument, policy: BackupConflictPolicy, now: Date, expectedPreview: BackupRestorePreview?, beforeReplacement: (@Sendable () throws -> Void)?) async throws -> Int {
        try backup.validate()
        do {
            return try await transaction(retryOnConflict: false) { context in
                // Keep every fetch, including upsert lookups, on the source generation. A row
                // inserted after this snapshot cannot be fetched and overwritten by this restore.
                try context.setQueryGenerationFrom(.current)
                let store = try self.persistence.store(for: .local)
                let incomingIDs = Set(backup.payload.cards.map(\.id))
                // Capture the exact objects before taking the recovery snapshot. New rows are never
                // swept into a later broad delete, even if another context commits while we write it.
                let entities = ["CardRevisionRecord", "ScheduleVersionRecord", "OccurrenceRecord", "TaskEventRecord", "OccurrenceOverrideRecord", "AttachmentRecord", "ImportLinkRecord"]
                var replacementRows: [UUID: [NSManagedObject]] = [:]
                if policy == .replaceMatching {
                    for id in incomingIDs {
                        for entity in entities {
                            replacementRows[id, default: []] += try DatabaseCodec.fetch(entity, context: context, stores: [store], predicate: NSPredicate(format: "cardID == %@", id as NSUUID))
                        }
                    }
                }
                let current = try self.library(in: context)
                let sourcePreview = BackupRestorePreview(backup: backup, current: current)
                if let expectedPreview, expectedPreview != sourcePreview { throw ShiriError.conflict("现有卡片或处理历史已变化，请重新查看恢复预览后确认。") }
                let existing = Set(current.cards.map(\.id))
                let duplicates = existing.intersection(incomingIDs)
                if !duplicates.isEmpty && policy == .requireChoice { throw ShiriError.conflict("备份中有 \(duplicates.count) 张已有卡片，请选择保留现有内容或用备份替换") }
                if policy == .replaceMatching && current.cards.contains(where: { duplicates.contains($0.id) && $0.scope == .privateCloud }) {
                    throw ShiriError.conflict("请先将对应的 iCloud 卡片保存到本机，再用备份替换")
                }
                if policy == .replaceMatching && !duplicates.isEmpty {
                    var attachments: [Attachment] = []
                    for card in current.cards {
                        let source = try self.persistence.store(for: card.scope)
                        attachments += try DatabaseCodec.fetch("AttachmentRecord", context: context, stores: [source], predicate: NSPredicate(format: "cardID == %@", card.id as NSUUID)).map(DatabaseCodec.attachment).filter { card.attachmentIDs.contains($0.id) }
                    }
                    let payload = BackupPayload(library: current, attachments: Self.unique(attachments, id: \.id))
                    try payload.validate()
                    _ = try self.writeRecoveryPoint(BackupDocument(payload: payload, now: now), now: now)
                    try beforeReplacement?()
                    // Use a fresh context so the original objects retain their optimistic-locking
                    // snapshots. A changed source requires a new user confirmation, never a retry.
                    let check = self.persistence.context(author: self.actorID + "-restore-check")
                    let latest = try check.performAndWait { try self.library(in: check) }
                    guard sourcePreview == BackupRestorePreview(backup: backup, current: latest) else {
                        throw ShiriError.conflict("保存恢复点期间卡片或处理历史有更新，尚未覆盖内容。请重新查看预览后确认。")
                    }
                }
                let cards = backup.payload.cards.filter { policy != .keepExisting || !existing.contains($0.id) }
                let restoredIDs = Set(cards.map(\.id))
                if policy == .replaceMatching { for id in duplicates { for row in replacementRows[id] ?? [] { context.delete(row) } } }
                for var card in cards {
                    card.scope = .local
                    try DatabaseCodec.put(ScopeRoute(cardID: card.id, scope: .local), entity: "DeviceValueRecord", id: "route/\(card.id)", context: context, store: self.deviceStore)
                    try DatabaseCodec.write(card, context: context, store: store)
                }
                for var revision in backup.payload.revisions where restoredIDs.contains(revision.cardID) {
                    revision.snapshot.scope = .local
                    try DatabaseCodec.put(revision, entity: "CardRevisionRecord", id: revision.id, context: context, store: store, fields: ["cardID":revision.cardID])
                }
                for occurrence in backup.payload.occurrences where restoredIDs.contains(occurrence.cardID) { try DatabaseCodec.put(occurrence, entity: "OccurrenceRecord", id: occurrence.id, context: context, store: store, fields: ["cardID":occurrence.cardID]) }
                for event in backup.payload.events where restoredIDs.contains(event.cardID) { try DatabaseCodec.put(event, entity: "TaskEventRecord", id: event.id, context: context, store: store, fields: ["cardID":event.cardID, "occurrenceID":event.occurrenceID, "operationID":event.operationID, "happenedAt":event.happenedAt, "kind":event.kind.rawValue]) }
                for override in backup.payload.overrides where restoredIDs.contains(override.cardID) { try DatabaseCodec.put(override, entity: "OccurrenceOverrideRecord", id: override.id, context: context, store: store, fields: ["cardID":override.cardID]) }
                for attachment in backup.payload.attachments where restoredIDs.contains(attachment.cardID) { try DatabaseCodec.write(attachment, context: context, store: store) }
                for var link in backup.payload.importLinks where restoredIDs.contains(link.cardID) {
                    link.feedbackConsent = false; link.feedbackAvailable = false; link.feedbackAccountKey = nil
                    try DatabaseCodec.put(link, entity: "ImportLinkRecord", id: link.id, context: context, store: store, fields: ["cardID":link.cardID, "sessionID":link.sessionID])
                }
                return cards.count
            }
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && [NSManagedObjectMergeError, NSPersistentStoreSaveConflictsError].contains(ns.code) {
                throw ShiriError.conflict("恢复时检测到其他操作更新了内容，尚未覆盖。请重新查看恢复预览后确认。")
            }
            throw error
        }
    }

}


extension CardCommands {
    /// Restore a current archived/deleted card without discarding its schedule or history.
    public func restore(_ card: Card, keepingReminders: Bool, now: Date) async throws -> Card {
        guard var current = try await repository.library().cards.first(where: { $0.id == card.id }), current.lifecycle != .active else { throw ShiriError.conflict("卡片状态已变化，请重新打开后确认。") }
        guard current.revisionID == card.revisionID else { throw ShiriError.conflict("这张卡片有新的修改，请重新打开恢复预览。") }
        current.lifecycle = .active; current.deletedAt = nil
        if !keepingReminders {
            current.reminders.isEnabled = false
            current.reminders.enablesLiveActivity = false
            current.reminders.scheduledLiveActivity = false
        }
        return try await save(CardDraft(card: current, isEditing: true), now: now)
    }
}
