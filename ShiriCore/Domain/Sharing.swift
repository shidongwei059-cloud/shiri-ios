import Foundation

public enum ShareExtent: String, Codable, CaseIterable, Sendable {
    case currentOccurrence, entireRule
    public var title: String { self == .currentOccurrence ? "仅这一次" : "整个重复规则" }
}
public enum ShareSessionStatus: String, Codable, Sendable { case prepared, invited, accepted, stopped, revoked }
public struct SharedCardSnapshot: Codable, Equatable, Sendable {
    public var sourceCardID: UUID
    public var sourceOccurrenceKey: String?
    public var card: Card
    public var attachments: [Attachment]
    public var extent: ShareExtent
    public init(card: Card, attachments: [Attachment], occurrence: Occurrence?, extent: ShareExtent, includeNote: Bool, includePhotos: Bool, calendar: Calendar = .current) {
        sourceCardID = card.id; sourceOccurrenceKey = occurrence?.semanticKey; self.card = card; self.extent = extent
        self.attachments = includePhotos ? attachments : []
        self.card.attachmentIDs = self.attachments.map(\.id)
        if !includeNote { self.card.note = "" }
        self.card.scope = .local; self.card.isPinned = false; self.card.deletedAt = nil
        self.card.recurrenceClosedAt = nil
        self.card.occasionLink = nil; self.card.memoryDate = nil; self.card.memory = nil
        if !includePhotos { self.card.appearance.backgroundAttachmentID = nil }
        if extent == .currentOccurrence, let occurrence, let date = occurrence.plannedAt {
            let calendar = card.schedule?.calendar(fallback: calendar) ?? calendar
            let time = DayTime(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date))
            if card.birthday != nil {
                self.card.birthday?.repeatsYearly = false
                self.card.birthday?.oneTimeDate = CivilDate(date, calendar: calendar)
                if card.birthday?.dayTime != nil { self.card.birthday?.dayTime = time }
                self.card.schedule = nil
            } else {
                var rule = ScheduleDefinition(start: CivilDate(date, calendar: calendar), time: card.schedule?.time == nil ? nil : time, timeZone: calendar.timeZone)
                rule.timeZoneMode = card.schedule?.timeZoneMode ?? .floating
                if rule.timeZoneMode == .elapsed { rule.absoluteInstant = date }
                rule.dueAt = occurrence.dueAt
                self.card.schedule = rule
            }
        }
    }
}
public struct ShareSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var snapshot: SharedCardSnapshot
    public var recipientLabel: String
    public var status: ShareSessionStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var feedbackOffered: Bool
    public var shareURL: URL?
    public var role: String
    public init(snapshot: SharedCardSnapshot, recipientLabel: String, feedback: Bool, now: Date) {
        id = UUID(); self.snapshot = snapshot; self.recipientLabel = recipientLabel
        status = .prepared; createdAt = now; updatedAt = now; feedbackOffered = feedback; role = "sender"
    }
}
public struct SharePackage: Codable, Equatable, Sendable {
    public let format: String
    public let version: Int
    public var sessionID: UUID
    public var createdAt: Date
    public var senderLabel: String
    public var snapshot: SharedCardSnapshot
    public var feedbackURL: URL?
    public init(session: ShareSession, senderLabel: String = "一位朋友") {
        format = "app.nianyi.schedule"; version = 1; sessionID = session.id; createdAt = session.createdAt
        self.senderLabel = senderLabel; snapshot = session.snapshot; feedbackURL = session.shareURL
    }
    public func validate() throws {
        guard format == "app.nianyi.schedule", version == 1 else { throw ShiriError.invalidFile("暂时无法打开这份日程文件，请让对方重新分享。") }
        _ = try snapshot.card.validated()
        guard snapshot.attachments.count <= AppLimits.attachmentCount else { throw ShiriError.invalidFile("日程中的图片过多") }
        for attachment in snapshot.attachments { try attachment.validate() }
        guard Set(snapshot.attachments.map(\.id)).count == snapshot.attachments.count,
              Set(snapshot.card.attachmentIDs).count == snapshot.card.attachmentIDs.count,
              snapshot.attachments.allSatisfy({ $0.cardID == snapshot.sourceCardID }),
              snapshot.card.id == snapshot.sourceCardID else { throw ShiriError.invalidFile("日程附件标识或归属不正确") }
        guard Set(snapshot.card.attachmentIDs) == Set(snapshot.attachments.map(\.id)) else { throw ShiriError.invalidFile("日程附件不完整") }
        if let feedbackURL { guard feedbackURL.scheme == "https", feedbackURL.host == "www.icloud.com" || feedbackURL.host == "icloud.com" else { throw ShiriError.invalidFile("反馈邀请地址不正确") } }
    }
    public func independentCopy(now: Date, scope: DataScope) -> (Card, [Attachment]) {
        var card = snapshot.card; card.id = UUID(); card.revisionID = UUID(); card.scope = scope
        card.createdAt = now; card.updatedAt = now; card.lifecycle = .active; card.deletedAt = nil; card.isPinned = false
        card.schedule?.id = UUID(); card.schedule?.version = 1
        card.occasionLink = nil; card.memoryDate = nil; card.memory = nil
        // Device capabilities and permissions must be confirmed by the recipient before scheduling.
        card.reminders.isEnabled = false
        let attachments = snapshot.attachments.map { original -> Attachment in
            var a = original; a.id = UUID(); a.cardID = card.id; return a
        }
        if let old = card.appearance.backgroundAttachmentID, let index = snapshot.attachments.firstIndex(where: { $0.id == old }) {
            card.appearance.backgroundAttachmentID = attachments[index].id
        }
        card.attachmentIDs = attachments.map(\.id)
        return (card, attachments)
    }
}
public struct ImportLink: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var cardID: UUID
    public var sessionID: UUID
    public var sourceCardID: UUID
    public var sourceOccurrenceKey: String?
    public var extent: ShareExtent
    public var feedbackConsent: Bool
    public var feedbackAvailable: Bool
    public var importedAt: Date
    public var feedbackAccountKey: String?
    public init(cardID: UUID, package: SharePackage, feedbackConsent: Bool, now: Date) {
        id = UUID(); self.cardID = cardID; sessionID = package.sessionID; sourceCardID = package.snapshot.sourceCardID
        sourceOccurrenceKey = package.snapshot.sourceOccurrenceKey; extent = package.snapshot.extent
        self.feedbackConsent = feedbackConsent; feedbackAvailable = package.feedbackURL != nil; importedAt = now
    }
}
/// The only receiver-originating cloud payload. It deliberately cannot contain title, note, location, pictures or snoozes.
public struct ReceiptEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, completed, reopened, feedbackStopped }
    public var id: UUID
    public var sessionID: UUID
    public var semanticKey: String?
    public var kind: Kind
    public var happenedAt: Date
    /// IDs of observed completion receipts. Never infer undo ordering from device wall clocks.
    public var reverses: [UUID]?
    public init(operationID: UUID, sessionID: UUID, semanticKey: String?, kind: Kind, now: Date, reverses: [UUID] = []) {
        id = StableID.uuid("receipt|\(operationID)"); self.sessionID = sessionID; self.semanticKey = semanticKey
        self.kind = kind; happenedAt = now; self.reverses = reverses
    }
}

public enum ReceiptReducer {
    public enum State: String, Sendable { case unknown, added, pending, completed, stopped }
    public static func state(_ events: [ReceiptEvent], semanticKey: String?) -> State {
        if events.contains(where: { $0.kind == .feedbackStopped }) { return .stopped }
        let scoped = events.filter { $0.semanticKey == semanticKey }
        if scoped.contains(where: { $0.kind == .reopened && $0.reverses == nil }) { return .unknown }
        let reversed = Set(scoped.filter { $0.kind == .reopened }.flatMap { $0.reverses ?? [] })
        if scoped.contains(where: { $0.kind == .completed && !reversed.contains($0.id) }) { return .completed }
        if scoped.contains(where: { $0.kind == .reopened }) { return .pending }
        return events.contains(where: { $0.kind == .added }) ? .added : .unknown
    }
    public static func receipt(for event: TaskEvent, link: ImportLink, semanticKey: String?, events: [TaskEvent]) -> ReceiptEvent {
        let reversed = events.filter { $0.cardID == event.cardID && event.reverses.contains($0.id) }.map { StableID.uuid("receipt|\($0.operationID)") }
        return ReceiptEvent(operationID: event.operationID, sessionID: link.sessionID, semanticKey: semanticKey, kind: event.kind == .completed ? .completed : .reopened, now: event.happenedAt, reverses: reversed)
    }
}

public struct ReceiptOutboxItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { receipt.id }
    public var receipt: ReceiptEvent
    public var retryCount = 0
    public var nextAttemptAt: Date
    public var lastError: String?
    public init(receipt: ReceiptEvent) { self.receipt = receipt; nextAttemptAt = receipt.happenedAt }
}
