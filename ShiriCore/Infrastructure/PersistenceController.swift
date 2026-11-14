import Foundation
import CoreData
import CloudKit

public struct PersistenceConfiguration: Sendable {
    public var directory: URL
    public var cloudContainerID: String?
    public var enablesCloudMirroring: Bool
    public var loadsCloudStores: Bool
    public var isExtension: Bool
    public var cloudAccountKey: String?
    public init(directory: URL, cloudContainerID: String? = nil, enablesCloudMirroring: Bool = false, loadsCloudStores: Bool = false, isExtension: Bool = false, cloudAccountKey: String? = nil) {
        self.directory = directory; self.cloudContainerID = cloudContainerID; self.enablesCloudMirroring = enablesCloudMirroring
        self.loadsCloudStores = loadsCloudStores; self.isExtension = isExtension
        self.cloudAccountKey = cloudAccountKey
    }
}

public final class PersistenceController: @unchecked Sendable {
    public let container: NSPersistentCloudKitContainer
    public let configuration: PersistenceConfiguration
    public private(set) var stores: [StoreKind: NSPersistentStore] = [:]
    public var isCloudLoaded: Bool { stores[.personal] != nil && stores[.shared] != nil }
    private init(configuration: PersistenceConfiguration) {
        self.configuration = configuration
        container = NSPersistentCloudKitContainer(name: "NianYi", managedObjectModel: PersistentModel.make())
    }
    public static func open(_ configuration: PersistenceConfiguration) async throws -> PersistenceController {
        let controller = PersistenceController(configuration: configuration)
        do { try await controller.load(); return controller }
        catch { try? await controller.detachStores(); throw error }
    }
    private func load() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let kinds: [StoreKind] = configuration.loadsCloudStores ? [.local, .device, .personal, .shared] : [.local, .device]
        var descriptions: [NSPersistentStoreDescription] = []
        for kind in kinds {
            let storeDirectory: URL
            if [.personal, .shared].contains(kind), let account = configuration.cloudAccountKey { storeDirectory = configuration.directory.appendingPathComponent("Cloud-" + String(StableID.hash(account).prefix(24)), isDirectory: true) }
            else { storeDirectory = configuration.directory }
            try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let url = storeDirectory.appendingPathComponent(kind.rawValue + ".sqlite")
            let marker = storeDirectory.appendingPathComponent(kind.rawValue + ".initialized")
            if fm.fileExists(atPath: marker.path) && !fm.fileExists(atPath: url.path) {
                throw ShiriError.storage("部分数据文件无法找到，现有文件未被替换。请保留当前数据，并尝试从备份恢复。")
            }
            if fm.fileExists(atPath: url.path) {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
                if !container.managedObjectModel.isConfiguration(withName: kind.rawValue, compatibleWithStoreMetadata: metadata) {
                    try migrateKnownModel(at: url, kind: kind, metadata: metadata)
                }
            }
            let d = NSPersistentStoreDescription(url: url); d.configuration = kind.rawValue
            d.shouldMigrateStoreAutomatically = false; d.shouldInferMappingModelAutomatically = false
            d.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            d.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            #if os(iOS)
            d.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject, forKey: NSPersistentStoreFileProtectionKey)
            #endif
            if [.personal, .shared].contains(kind), configuration.enablesCloudMirroring, !configuration.isExtension,
               let identifier = configuration.cloudContainerID {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
                options.databaseScope = kind == .personal ? .private : .shared
                d.cloudKitContainerOptions = options
            }
            descriptions.append(d)
        }
        container.persistentStoreDescriptions = descriptions
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock(); var remaining = descriptions.count; var firstError: Error?
            container.loadPersistentStores { _, error in
                lock.lock(); defer { lock.unlock() }
                if let error, firstError == nil { firstError = error }
                remaining -= 1
                if remaining == 0 { if let error = firstError { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
        }
        for store in container.persistentStoreCoordinator.persistentStores {
            if let kind = StoreKind(rawValue: store.configurationName) {
                stores[kind] = store
                let marker = (store.url?.deletingLastPathComponent() ?? configuration.directory).appendingPathComponent(kind.rawValue + ".initialized")
                if !fm.fileExists(atPath: marker.path) { try Data(PersistentModel.currentVersion.utf8).write(to: marker, options: .atomic) }
            }
        }
        container.viewContext.mergePolicy = NSErrorMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.name = "view"; container.viewContext.transactionAuthor = "NianYiApp"
    }
    private func migrateKnownModel(at url: URL, kind: StoreKind, metadata: [String: Any]) throws {
        let old = PersistentModel.make(version: 0)
        guard old.isConfiguration(withName: kind.rawValue, compatibleWithStoreMetadata: metadata) else {
            throw ShiriError.storage("暂时无法读取现有数据，原有文件已保留。请更新拾日后重试，或从备份恢复。")
        }
        let fm = FileManager.default
        let backup = configuration.directory.appendingPathComponent("BeforeMigration-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: backup.appendingPathComponent(source.lastPathComponent)) }
        }
        let destination = url.appendingPathExtension("migrating")
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: container.managedObjectModel)
        let manager = NSMigrationManager(sourceModel: old, destinationModel: container.managedObjectModel)
        try manager.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: nil, with: mapping, toDestinationURL: destination, destinationType: NSSQLiteStoreType, destinationOptions: nil)
        let newMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: destination)
        guard container.managedObjectModel.isConfiguration(withName: kind.rawValue, compatibleWithStoreMetadata: newMetadata) else { throw ShiriError.storage("数据更新未完成，原有内容和备份已保留。请稍后重试。") }
        try container.persistentStoreCoordinator.replacePersistentStore(at: url, destinationOptions: nil, withPersistentStoreFrom: destination, sourceOptions: nil, ofType: NSSQLiteStoreType)
    }
    public func detachStores() async throws {
        let coordinator = container.persistentStoreCoordinator
        try await coordinator.perform {
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        stores = [:]
    }
    public func context(author: String = "NianYi") -> NSManagedObjectContext {
        let c = container.newBackgroundContext(); c.mergePolicy = NSErrorMergePolicy; c.transactionAuthor = author; return c
    }
    public func store(for scope: DataScope) throws -> NSPersistentStore {
        guard let store = stores[scope == .local ? .local : .personal] else { throw ShiriError.unavailable("请先在设置中连接 iCloud，再更改卡片的保存位置") }
        return store
    }
}
