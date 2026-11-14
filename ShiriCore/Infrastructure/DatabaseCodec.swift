import Foundation
import CoreData

enum DatabaseCodec {
    static func fetch(_ entity: String, context: NSManagedObjectContext, stores: [NSPersistentStore], predicate: NSPredicate? = nil) throws -> [NSManagedObject] {
        guard !stores.isEmpty else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.affectedStores = stores; request.predicate = predicate; request.fetchBatchSize = 128
        return try context.fetch(request)
    }
    static func object(_ entity: String, id: Any, context: NSManagedObjectContext, store: NSPersistentStore) throws -> NSManagedObject {
        let predicate = NSPredicate(format: "id == %@", argumentArray: [id])
        if let existing = try fetch(entity, context: context, stores: [store], predicate: predicate).first { return existing }
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        context.assign(object, to: store); object.setValue(id, forKey: "id"); return object
    }
    static func put<T: Encodable>(_ value: T, entity: String, id: Any, context: NSManagedObjectContext, store: NSPersistentStore, fields: [String: Any?] = [:]) throws {
        let object = try self.object(entity, id: id, context: context, store: store)
        object.setValue(try ValueCodec.encode(value), forKey: "payload")
        for (key, value) in fields { object.setValue(value, forKey: key) }
    }
    static func values<T: Decodable>(_ type: T.Type, entity: String, context: NSManagedObjectContext, stores: [NSPersistentStore], predicate: NSPredicate? = nil) throws -> [T] {
        guard !stores.isEmpty else { return [] }
        if !context.hasChanges {
            // Read-only snapshots need payloads, not tens of thousands of managed-object faults.
            // Dictionary fetches cannot see pending edits, so transactions retain the path below.
            let request = NSFetchRequest<NSDictionary>(entityName: entity)
            request.resultType = .dictionaryResultType; request.propertiesToFetch = ["payload"]
            request.affectedStores = stores; request.predicate = predicate; request.includesPendingChanges = false
            return try context.fetch(request).map { row in
                guard let data = row["payload"] as? Data else { throw ShiriError.storage("\(entity) 包含无法读取的记录，已保留原数据") }
                return try ValueCodec.decode(type, data)
            }
        }
        return try fetch(entity, context: context, stores: stores, predicate: predicate).map { object in
            guard let data = object.value(forKey: "payload") as? Data else { throw ShiriError.storage("\(entity) 包含无法读取的记录，已保留原数据") }
            return try ValueCodec.decode(type, data)
        }
    }
    static func routedValues<T: Decodable>(_ type: T.Type, entity: String, context: NSManagedObjectContext, stores: [NSPersistentStore], routes: [UUID: DataScope], predicate: NSPredicate? = nil) throws -> [T] {
        try stores.flatMap { store in
            let scope: DataScope = store.configurationName == StoreKind.local.rawValue ? .local : .privateCloud
            let excluded = routes.filter { $0.value != scope }.map { $0.key as NSUUID }
            let routePredicate = excluded.isEmpty ? nil : NSPredicate(format: "NOT (cardID IN %@)", excluded)
            let predicates = [predicate, routePredicate].compactMap { $0 }
            let combined = predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            return try values(type, entity: entity, context: context, stores: [store], predicate: combined)
        }
    }
    static func write(_ card: Card, context: NSManagedObjectContext, store: NSPersistentStore) throws {
        let object = try self.object("CardRecord", id: card.id, context: context, store: store)
        for (key, value) in ["title":card.title, "note":card.note, "kind":card.kind.rawValue, "category":card.category,
                             "importance":card.importance.rawValue, "lifecycle":card.lifecycle.rawValue, "scope":card.scope.rawValue] { object.setValue(value, forKey: key) }
        object.setValue(card.createdAt, forKey: "createdAt"); object.setValue(card.updatedAt, forKey: "updatedAt")
        object.setValue(card.deletedAt, forKey: "deletedAt"); object.setValue(card.isPinned, forKey: "isPinned")
        object.setValue(card.revisionID, forKey: "revisionID")
        object.setValue(try ValueCodec.encode(card.appearance), forKey: "appearance")
        object.setValue(try ValueCodec.encode(card.reminders), forKey: "reminders")
        object.setValue(try ValueCodec.encode(card.attachmentIDs), forKey: "attachmentIDs")
        object.setValue(try card.schedule.map(ValueCodec.encode), forKey: "schedule")
        object.setValue(try card.birthday.map(ValueCodec.encode), forKey: "birthday")
        object.setValue(try card.place.map(ValueCodec.encode), forKey: "place")
    }
    static func card(_ object: NSManagedObject) throws -> Card {
        try card(object, includesEmbeddedValues: true)
    }
    static func card(_ object: NSManagedObject, includesEmbeddedValues: Bool) throws -> Card {
        guard let id = object.value(forKey: "id") as? UUID, let title = object.value(forKey: "title") as? String,
              let created = object.value(forKey: "createdAt") as? Date, let revision = object.value(forKey: "revisionID") as? UUID,
              let kind = CardKind(rawValue: object.value(forKey: "kind") as? String ?? "") else { throw ShiriError.storage("卡片记录不完整，原数据已保留") }
        var card = Card(id: id, title: title, kind: kind, now: created)
        card.note = object.value(forKey: "note") as? String ?? ""; card.category = object.value(forKey: "category") as? String ?? "生活"
        card.importance = Importance(rawValue: object.value(forKey: "importance") as? String ?? "") ?? .normal
        card.lifecycle = CardLifecycle(rawValue: object.value(forKey: "lifecycle") as? String ?? "") ?? .active
        card.scope = DataScope(rawValue: object.value(forKey: "scope") as? String ?? "") ?? .local
        card.updatedAt = object.value(forKey: "updatedAt") as? Date ?? created; card.deletedAt = object.value(forKey: "deletedAt") as? Date
        card.isPinned = object.value(forKey: "isPinned") as? Bool ?? false; card.revisionID = revision
        guard includesEmbeddedValues else { return card }
        if let data = object.value(forKey: "appearance") as? Data { card.appearance = try ValueCodec.decode(CardAppearance.self, data) }
        if let data = object.value(forKey: "reminders") as? Data { card.reminders = try ValueCodec.decode(ReminderPolicy.self, data) }
        if let data = object.value(forKey: "attachmentIDs") as? Data { card.attachmentIDs = try ValueCodec.decode([UUID].self, data) }
        if let data = object.value(forKey: "schedule") as? Data { card.schedule = try ValueCodec.decode(ScheduleDefinition.self, data) }
        if let data = object.value(forKey: "birthday") as? Data { card.birthday = try ValueCodec.decode(BirthdayRule.self, data) }
        if let data = object.value(forKey: "place") as? Data { card.place = try ValueCodec.decode(PlaceRule.self, data) }
        return card
    }
    static func write(_ attachment: Attachment, context: NSManagedObjectContext, store: NSPersistentStore) throws {
        let object = try self.object("AttachmentRecord", id: attachment.id, context: context, store: store)
        object.setValue(attachment.cardID, forKey: "cardID"); object.setValue(attachment.data, forKey: "data")
        object.setValue(attachment.mediaType, forKey: "mediaType"); object.setValue(attachment.width, forKey: "width")
        object.setValue(attachment.height, forKey: "height"); object.setValue(attachment.digest, forKey: "digest")
        object.setValue(attachment.sortIndex, forKey: "sortIndex")
    }
    static func attachment(_ object: NSManagedObject) throws -> Attachment {
        guard let id = object.value(forKey: "id") as? UUID, let cardID = object.value(forKey: "cardID") as? UUID,
              let data = object.value(forKey: "data") as? Data, let digest = object.value(forKey: "digest") as? String else {
            throw ShiriError.storage("一张图片尚未完整下载或已缺失，请保留卡片并重试")
        }
        var attachment = Attachment(id: id, cardID: cardID, data: data, width: object.value(forKey: "width") as? Int ?? 0,
                                    height: object.value(forKey: "height") as? Int ?? 0, mediaType: object.value(forKey: "mediaType") as? String ?? "image/jpeg", sortIndex: object.value(forKey: "sortIndex") as? Int ?? 0)
        attachment.digest = digest; return attachment
    }
}
