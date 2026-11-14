import Foundation
import CloudKit
@preconcurrency import CoreData

/// NSPersistentCloudKitContainer owns mirroring. This coordinator only manages private invitations
/// and the separate ShareSession graph; it never shares a CardRecord or copies private relationships.
public final class CloudSharingCoordinator: @unchecked Sendable {
    public let repository: ShiriRepository
    public let cloud: CKContainer
    public init(repository: ShiriRepository, containerID: String) { self.repository = repository; cloud = CKContainer(identifier: containerID) }
    public static func availableAccount(containerID: String) async throws -> String {
        let cloud = CKContainer(identifier: containerID)
        let status = try await cloud.accountStatus()
        guard status == .available else {
            let message: String
            switch status { case .noAccount: message = "请先在系统设置中登录 iCloud"; case .restricted: message = "这台设备的 iCloud 访问受到限制"; default: message = "暂时无法连接 iCloud，请稍后重试" }
            throw ShiriError.unavailable(message)
        }
        return try await cloud.userRecordID().recordName
    }
    public func create(_ session: ShareSession, participantAddress: String) async throws -> ShareSession {
        guard !participantAddress.trimmingCharacters(in: .whitespaces).isEmpty else { throw ShiriError.validation("请填写这位接收者的 iCloud 邮箱") }
        guard let store = repository.persistence.stores[.personal] else { throw ShiriError.unavailable("请先连接 iCloud") }
        let participant = try await cloud.shareParticipant(forEmailAddress: participantAddress)
        participant.permission = .readWrite
        let context = repository.persistence.context(author: repository.actorID)
        let objectID = try await context.perform {
            let root = try DatabaseCodec.object("ShareSessionRecord", id: session.id, context: context, store: store)
            var metadata = session; metadata.snapshot.attachments = []
            root.setValue(try ValueCodec.encode(metadata), forKey: "payload"); root.setValue("sender", forKey: "role")
            root.setValue(session.status.rawValue, forKey: "status"); root.setValue(session.updatedAt, forKey: "lastUpdatedAt")
            let snapshot = try DatabaseCodec.object("SharedSnapshotRecord", id: session.id, context: context, store: store)
            snapshot.setValue(try ValueCodec.encode(session.snapshot), forKey: "payload")
            snapshot.setValue(root, forKey: "session")
            try context.save(); return root.objectID
        }
        let container = repository.persistence.container
        let share: CKShare = try await withCheckedThrowingContinuation { continuation in
            context.perform {
                do {
                    let root = try context.existingObject(with: objectID)
                    container.share([root], to: nil) { _, share, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let share { continuation.resume(returning: share) }
                        else { continuation.resume(throwing: ShiriError.unavailable("无法创建私有邀请")) }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        share.publicPermission = .none
        // Exactly one recipient per session. No common family graph or anonymous public invitation.
        for old in share.participants where old.role != .owner { share.removeParticipant(old) }
        share.addParticipant(participant)
        share[CKShare.SystemFieldKey.title] = session.snapshot.card.title as CKRecordValue
        let saved: CKShare = try await withCheckedThrowingContinuation { continuation in
            container.persistUpdatedShare(share, in: store) { saved, error in
                if let error { continuation.resume(throwing: error) }
                else if let saved { continuation.resume(returning: saved) }
                else { continuation.resume(throwing: ShiriError.unavailable("邀请尚未保存，请稍后重试")) }
            }
        }
        guard let url = saved.url else { throw ShiriError.unavailable("iCloud 尚未返回邀请链接，请稍后重试") }
        var result = session; result.shareURL = url; result.status = .invited; result.updatedAt = Date()
        try await repository.saveLocalShareSession(result); return result
    }
    public func accept(_ metadata: CKShare.Metadata) async throws {
        guard metadata.containerIdentifier == cloud.containerIdentifier,
              metadata.share.publicPermission == .none,
              let store = repository.persistence.stores[.shared] else { throw ShiriError.validation("这不是当前应用的私有日程邀请") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            repository.persistence.container.acceptShareInvitations(from: [metadata], into: store) { accepted, error in
                if let error { continuation.resume(throwing: error) }
                else if accepted?.isEmpty == false { continuation.resume() }
                else { continuation.resume(throwing: ShiriError.unavailable("邀请尚未接受")) }
            }
        }
    }
    public func sessions(received: Bool) async throws -> [ShareSession] {
        guard let store = repository.persistence.stores[received ? .shared : .personal] else { return [] }
        let context = repository.persistence.context(author: repository.actorID)
        return try await context.perform {
            try DatabaseCodec.fetch("ShareSessionRecord", context: context, stores: [store]).map { root in
                guard let payload = root.value(forKey: "payload") as? Data else { throw ShiriError.storage("分享尚未下载完整") }
                var session = try ValueCodec.decode(ShareSession.self, payload)
                if let objects = root.value(forKey: "snapshots") as? Set<NSManagedObject>, let snapshot = objects.first?.value(forKey: "payload") as? Data { session.snapshot = try ValueCodec.decode(SharedCardSnapshot.self, snapshot) }
                if let share = try self.repository.persistence.container.fetchShares(matching: [root.objectID])[root.objectID] { session.shareURL = share.url }
                if received { session.role = "recipient"; session.status = .accepted }
                return session
            }
        }
    }
    public func receipts(sessionID: UUID) async throws -> [ReceiptEvent] {
        let stores = [repository.persistence.stores[.personal], repository.persistence.stores[.shared]].compactMap { $0 }
        let context = repository.persistence.context(author: repository.actorID)
        return try await context.perform { try DatabaseCodec.values(ReceiptEvent.self, entity: "ReceiptEventRecord", context: context, stores: stores, predicate: NSPredicate(format: "sessionID == %@", sessionID as NSUUID)).sorted { $0.happenedAt < $1.happenedAt } }
    }
    public func flushReceipts(now: Date) async throws {
        guard let store = repository.persistence.stores[.shared] else { return }
        let library = try await repository.library()
        let ackKey = "receipt-persisted/" + StableID.hash(repository.persistence.configuration.cloudAccountKey ?? "local")
        var acknowledged = Set(try await repository.deviceValue([UUID].self, key: ackKey) ?? [])
        let accountLinks = library.importLinks.filter { $0.feedbackAccountKey != nil && $0.feedbackAccountKey == repository.persistence.configuration.cloudAccountKey }
        let allowed = Set(accountLinks.filter { $0.feedbackConsent && $0.feedbackAvailable }.map(\.sessionID))
        // Recover a process interruption between the business-store commit and the device outbox.
        for link in library.importLinks where allowed.contains(link.sessionID) {
            let added = ReceiptEvent(operationID: link.id, sessionID: link.sessionID, semanticKey: link.sourceOccurrenceKey, kind: .added, now: link.importedAt)
            if !acknowledged.contains(added.id) { try await repository.enqueue(added) }
            for event in library.events where event.cardID == link.cardID && [.completed, .reopened].contains(event.kind) {
                let occurrence = library.occurrences.first { $0.id == event.occurrenceID }
                let key = link.extent == .currentOccurrence ? link.sourceOccurrenceKey : occurrence?.semanticKey
                let receipt = ReceiptReducer.receipt(for: event, link: link, semanticKey: key, events: library.events)
                if !acknowledged.contains(receipt.id) { try await repository.enqueue(receipt) }
            }
        }
        let items = try await repository.outbox()
        for item in items where item.nextAttemptAt <= now {
            let freshLinks = try await repository.library().importLinks
            guard freshLinks.contains(where: { $0.sessionID == item.receipt.sessionID && $0.feedbackAccountKey != nil && $0.feedbackAccountKey == repository.persistence.configuration.cloudAccountKey && (($0.feedbackConsent && $0.feedbackAvailable) || item.receipt.kind == .feedbackStopped) }) else {
                try await repository.deleteDeviceRecord(entity: "ReceiptOutboxRecord", id: item.id); continue
            }
            let context = repository.persistence.context(author: repository.actorID)
            let wrote = try await context.perform {
                guard let root = try DatabaseCodec.fetch("ShareSessionRecord", context: context, stores: [store], predicate: NSPredicate(format: "id == %@", item.receipt.sessionID as NSUUID)).first else { return false }
                let object = try DatabaseCodec.object("ReceiptEventRecord", id: item.receipt.id, context: context, store: store)
                object.setValue(try ValueCodec.encode(item.receipt), forKey: "payload"); object.setValue(item.receipt.sessionID, forKey: "sessionID")
                object.setValue(item.receipt.happenedAt, forKey: "happenedAt"); object.setValue(root, forKey: "session")
                if context.hasChanges { try context.save() }; return true
            }
            // This acknowledges local persistence; NSPersistentCloudKitContainer handles cloud retries.
            if wrote {
                acknowledged.insert(item.id)
                try await repository.setDeviceValue(acknowledged.sorted { $0.uuidString < $1.uuidString }, key: ackKey)
                try await repository.deleteDeviceRecord(entity: "ReceiptOutboxRecord", id: item.id)
            } else {
                var retry = item; retry.retryCount += 1; retry.nextAttemptAt = now.addingTimeInterval(min(3600, pow(2, Double(min(retry.retryCount, 10))) * 15)); retry.lastError = "分享内容尚未同步，请稍后重试"
                try await repository.updateOutbox(retry)
            }
        }
    }
    public func leaveOrRevoke(sessionID: UUID, received: Bool) async throws {
        guard let store = repository.persistence.stores[received ? .shared : .personal] else { throw ShiriError.unavailable("请先连接 iCloud") }
        let context = repository.persistence.context(author: repository.actorID)
        let objectID = try await context.perform { try DatabaseCodec.fetch("ShareSessionRecord", context: context, stores: [store], predicate: NSPredicate(format: "id == %@", sessionID as NSUUID)).first?.objectID }
        guard let objectID, let share = try repository.persistence.container.fetchShares(matching: [objectID])[objectID] else { throw ShiriError.unavailable("这份分享尚未同步，请稍后重试") }
        // The zone contains only this session's snapshot and receipt graph. Imported Card records are elsewhere.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            repository.persistence.container.purgeObjectsAndRecordsInZone(with: share.recordID.zoneID, in: store) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
