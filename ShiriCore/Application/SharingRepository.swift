import Foundation

extension ShiriRepository {
    public func localShareSessions() async throws -> [ShareSession] {
        let context = persistence.context(author: actorID)
        return try await context.perform {
            let sessions = try DatabaseCodec.values(ShareSession.self, entity: "DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id BEGINSWITH %@", "share/"))
            return try sessions.filter { session in
                guard session.feedbackOffered else { return true }
                let key = try DatabaseCodec.values(String.self, entity: "DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id == %@", "share-account/\(session.id)")).first
                return key != nil && key == self.persistence.configuration.cloudAccountKey
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    public func saveLocalShareSession(_ session: ShareSession) async throws {
        if session.feedbackOffered, let key = persistence.configuration.cloudAccountKey { try await setDeviceValue(key, key: "share-account/\(session.id)") }
        try await setDeviceValue(session, key: "share/\(session.id)")
    }
}
extension SharePackage: Identifiable { public var id: UUID { sessionID } }
