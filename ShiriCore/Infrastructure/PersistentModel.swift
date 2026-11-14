import Foundation
import CoreData

public enum StoreKind: String, CaseIterable, Sendable {
    case local = "LocalCards", personal = "PrivateCloud", shared = "SharedCloud", device = "DeviceState"
}

/// Programmatic, versioned Core Data model. Structured value fields use binary property lists;
/// searchable domain fields and immutable events remain native database entities.
public enum PersistentModel {
    public static let currentVersion = "NianYiV1"
    public static func make(version: Int = 1) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.versionIdentifiers = [version == 0 ? "NianYiV0" : currentVersion]
        let card = entity("CardRecord", [
            attr("id", .UUIDAttributeType), attr("title", .stringAttributeType), attr("note", .stringAttributeType),
            attr("kind", .stringAttributeType), attr("category", .stringAttributeType), attr("importance", .stringAttributeType),
            attr("lifecycle", .stringAttributeType), attr("scope", .stringAttributeType), attr("createdAt", .dateAttributeType),
            attr("updatedAt", .dateAttributeType), attr("deletedAt", .dateAttributeType), attr("isPinned", .booleanAttributeType),
            attr("revisionID", .UUIDAttributeType), attr("appearance", .binaryDataAttributeType), attr("schedule", .binaryDataAttributeType),
            attr("reminders", .binaryDataAttributeType), attr("birthday", .binaryDataAttributeType), attr("place", .binaryDataAttributeType),
            attr("attachmentIDs", .binaryDataAttributeType)
        ])
        let revision = payloadEntity("CardRevisionRecord", extra: [attr("cardID", .UUIDAttributeType)])
        let schedule = payloadEntity("ScheduleVersionRecord", extra: [attr("cardID", .UUIDAttributeType)])
        let occurrence = payloadEntity("OccurrenceRecord", id: .stringAttributeType, extra: [attr("cardID", .UUIDAttributeType), attr("plannedAt", .dateAttributeType)])
        let event = payloadEntity("TaskEventRecord", extra: [attr("cardID", .UUIDAttributeType), attr("occurrenceID", .stringAttributeType), attr("operationID", .UUIDAttributeType), attr("happenedAt", .dateAttributeType), attr("kind", .stringAttributeType)])
        let override = payloadEntity("OccurrenceOverrideRecord", id: .stringAttributeType, extra: [attr("cardID", .UUIDAttributeType)])
        let attachmentData = attr("data", .binaryDataAttributeType); attachmentData.allowsExternalBinaryDataStorage = true
        let attachment = entity("AttachmentRecord", [attr("id", .UUIDAttributeType), attr("cardID", .UUIDAttributeType), attr("mediaType", .stringAttributeType), attr("width", .integer64AttributeType), attr("height", .integer64AttributeType), attr("digest", .stringAttributeType), attr("sortIndex", .integer64AttributeType), attachmentData])
        let imported = payloadEntity("ImportLinkRecord", extra: [attr("cardID", .UUIDAttributeType), attr("sessionID", .UUIDAttributeType)])
        let state = payloadEntity("DeviceValueRecord", id: .stringAttributeType)
        let personalEvent = payloadEntity("PersonalEventRecord", extra: [attr("occurrenceID", .stringAttributeType)])
        let outbox = payloadEntity("ReceiptOutboxRecord", extra: [attr("sessionID", .UUIDAttributeType)])
        let journal = payloadEntity("MigrationJournalRecord")
        let draft = payloadEntity("DraftRecord")
        let session = payloadEntity("ShareSessionRecord", extra: [attr("role", .stringAttributeType), attr("status", .stringAttributeType), attr("lastUpdatedAt", .dateAttributeType)])
        let snapshot = payloadEntity("SharedSnapshotRecord")
        let receipt = payloadEntity("ReceiptEventRecord", extra: [attr("sessionID", .UUIDAttributeType), attr("happenedAt", .dateAttributeType)])
        connect(parent: session, child: snapshot, childrenKey: "snapshots", parentKey: "session")
        connect(parent: session, child: receipt, childrenKey: "receipts", parentKey: "session")
        let cardEntities = [card, revision, schedule, occurrence, event, override, attachment, imported]
        let sharingEntities = [session, snapshot, receipt]
        let deviceEntities = [state, personalEvent, outbox, journal, draft]
        model.entities = cardEntities + sharingEntities + deviceEntities
        model.setEntities(cardEntities, forConfigurationName: StoreKind.local.rawValue)
        model.setEntities(cardEntities + sharingEntities, forConfigurationName: StoreKind.personal.rawValue)
        model.setEntities(sharingEntities, forConfigurationName: StoreKind.shared.rawValue)
        model.setEntities(deviceEntities, forConfigurationName: StoreKind.device.rawValue)
        if version == 0 { card.properties.removeAll { $0.name == "category" } }
        return model
    }
    private static func attr(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true; return a
    }
    private static func entity(_ name: String, _ properties: [NSPropertyDescription]) -> NSEntityDescription {
        let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = "NSManagedObject"; e.properties = properties
        // CloudKit does not support unique constraints; stable domain IDs and reducers handle replay.
        return e
    }
    private static func payloadEntity(_ name: String, id: NSAttributeType = .UUIDAttributeType, extra: [NSPropertyDescription] = []) -> NSEntityDescription {
        let data = attr("payload", .binaryDataAttributeType); data.allowsExternalBinaryDataStorage = true
        return entity(name, [attr("id", id), data] + extra)
    }
    private static func connect(parent: NSEntityDescription, child: NSEntityDescription, childrenKey: String, parentKey: String) {
        let many = NSRelationshipDescription(); many.name = childrenKey; many.destinationEntity = child
        many.minCount = 0; many.maxCount = 0; many.isOptional = true; many.deleteRule = .cascadeDeleteRule
        let one = NSRelationshipDescription(); one.name = parentKey; one.destinationEntity = parent
        one.minCount = 0; one.maxCount = 1; one.isOptional = true; one.deleteRule = .nullifyDeleteRule
        many.inverseRelationship = one; one.inverseRelationship = many
        parent.properties.append(many); child.properties.append(one)
    }
}

private struct EncodedValue<T: Encodable>: Encodable { var nianyiValue: T }
private struct DecodedValue<T: Decodable>: Decodable { var nianyiValue: T }
public enum ValueCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary; return try encoder.encode(EncodedValue(nianyiValue: value))
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = PropertyListDecoder()
        if let wrapped = try? decoder.decode(DecodedValue<T>.self, from: data) { return wrapped.nianyiValue }
        return try decoder.decode(type, from: data) // Earlier V1 records used unwrapped container values.
    }
}
