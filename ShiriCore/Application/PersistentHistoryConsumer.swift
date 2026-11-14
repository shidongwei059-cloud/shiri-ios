import Foundation
@preconcurrency import CoreData

public struct HistoryConsumption: Sendable { public var transactions: Int; public var changedObjectCount: Int }
public actor PersistentHistoryConsumer {
    private let repository: ShiriRepository
    private let consumer: String
    public init(repository: ShiriRepository, consumer: String) { self.repository = repository; self.consumer = consumer }
    public func consume() async throws -> HistoryConsumption {
        var total = 0; var objects = 0
        for (kind, store) in repository.persistence.stores {
            let storeIdentity = StableID.hash(store.url?.path ?? kind.rawValue)
            let folder = repository.persistence.configuration.directory.appendingPathComponent("HistoryTokens/" + consumer, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tokenURL = folder.appendingPathComponent(storeIdentity + ".token")
            let data = try? Data(contentsOf: tokenURL)
            let token = try data.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: $0) }
            let context = repository.persistence.context(author: consumer)
            let result: (Int, Int, Data?) = try await context.perform {
                let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                request.affectedStores = [store]
                let response = try context.execute(request) as? NSPersistentHistoryResult
                let transactions = response?.result as? [NSPersistentHistoryTransaction] ?? []
                let changed = transactions.filter { $0.author != self.consumer && $0.author != self.repository.actorID }
                // Save the tail token even when this batch only contains this consumer's own writes.
                return (changed.count, changed.reduce(0) { $0 + ($1.changes?.count ?? 0) }, try transactions.last.map { try NSKeyedArchiver.archivedData(withRootObject: $0.token, requiringSecureCoding: true) })
            }
            if let next = result.2, next != data { try next.write(to: tokenURL, options: .atomic) }
            total += result.0; objects += result.1
        }
        return HistoryConsumption(transactions: total, changedObjectCount: objects)
    }
}
