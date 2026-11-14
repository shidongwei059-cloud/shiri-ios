import Foundation

public struct ExtensionBootstrap: Codable, Sendable {
    public var cloudAccountKey: String?
    public var cloudContainerID: String?
    public init(cloudAccountKey: String? = nil, cloudContainerID: String? = nil) { self.cloudAccountKey = cloudAccountKey; self.cloudContainerID = cloudContainerID }
}
public enum ExtensionStore {
    public static func directory(bundle: Bundle = .main) throws -> URL {
        let group = bundle.object(forInfoDictionaryKey: "ShiriAppGroup") as? String ?? "group.com.jianmutianyi.nianyi"
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw ShiriError.unavailable("暂时无法读取卡片，请先打开拾日后重试") }
        return base.appendingPathComponent("NianYi", isDirectory: true)
    }
    public static func open(directory: URL? = nil, author: String = "NianYiExtension") async throws -> ShiriRepository {
        let root = try directory ?? self.directory()
        let bootstrap = (try? Data(contentsOf: root.appendingPathComponent("ExtensionBootstrap.plist"))).flatMap { try? ValueCodec.decode(ExtensionBootstrap.self, $0) }
        var verifiedAccount: String?
        if let expected = bootstrap?.cloudAccountKey, let containerID = bootstrap?.cloudContainerID,
           let current = try? await CloudSharingCoordinator.availableAccount(containerID: containerID), current == expected { verifiedAccount = current }
        let persistence = try await PersistenceController.open(PersistenceConfiguration(directory: root, cloudContainerID: bootstrap?.cloudContainerID, enablesCloudMirroring: false, loadsCloudStores: verifiedAccount != nil, isExtension: true, cloudAccountKey: verifiedAccount))
        return ShiriRepository(persistence: persistence, actorID: author)
    }
    public static func publish(_ bootstrap: ExtensionBootstrap, at root: URL) throws {
        try ValueCodec.encode(bootstrap).write(to: root.appendingPathComponent("ExtensionBootstrap.plist"), options: .atomic)
    }
}
public struct WidgetCard: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var note: String
    public var plannedAt: Date?
    public var occurrenceID: String?
    public var canComplete: Bool
    public var theme: CardTheme
    public var isPinned: Bool
    // Older snapshots omit this field. A date-only arrangement must not look like a midnight deadline.
    public var isDateOnly: Bool? = nil
    public var url: URL { URL(string: "nianyi://card/\(id)")! }
}
public struct WidgetSnapshot: Codable, Sendable {
    public var createdAt: Date
    public var pendingCount: Int
    public var hidesContent: Bool
    public var cards: [WidgetCard]
    public static func make(library: LibrarySnapshot, preferences: AppPreferences, now: Date, calendar: Calendar) -> WidgetSnapshot {
        let engine = OccurrenceEngine(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let byOccurrence = Dictionary(grouping: library.events, by: \.occurrenceID)
        var count = 0
        let cards = library.cards.filter { $0.lifecycle == .active && !$0.isMemory }.compactMap { card -> (card: WidgetCard, handled: Bool)? in
            let occurrence = engine.relevantOccurrence(for: card, at: today, overrides: library.overrides)
            let pending = occurrence.map { EventReducer.state(events: byOccurrence[$0.id] ?? []) == .pending } ?? false
            if pending && card.canComplete { count += 1 }
            guard card.isPinned || pending else { return nil }
            let item = WidgetCard(id: card.id, title: preferences.widgetPrivacy == .hidden ? "打开拾日查看" : card.title, note: preferences.widgetPrivacy == .full ? String(card.note.prefix(120)) : "", plannedAt: occurrence?.plannedAt, occurrenceID: occurrence?.id, canComplete: pending && card.canComplete && preferences.widgetPrivacy != .hidden, theme: card.appearance.theme, isPinned: card.isPinned, isDateOnly: card.schedule?.time == nil && card.schedule?.absoluteInstant == nil && card.birthday?.dayTime == nil)
            return (item, card.kind == .task && card.birthday == nil && !pending)
        }.sorted { a, b in
            if a.handled != b.handled { return !a.handled }
            if a.card.isPinned != b.card.isPinned { return a.card.isPinned }
            if a.card.plannedAt != b.card.plannedAt { return (a.card.plannedAt ?? .distantFuture) < (b.card.plannedAt ?? .distantFuture) }
            return a.card.id.uuidString < b.card.id.uuidString
        }.map(\.card)
        return WidgetSnapshot(createdAt: now, pendingCount: count, hidesContent: preferences.widgetPrivacy == .hidden, cards: Array(cards.prefix(8)))
    }
    public static func read(at directory: URL) throws -> Self { try ValueCodec.decode(Self.self, Data(contentsOf: directory.appendingPathComponent("WidgetSnapshot.plist"))) }
    public func write(at directory: URL) throws { try ValueCodec.encode(self).write(to: directory.appendingPathComponent("WidgetSnapshot.plist"), options: .atomic) }
}
