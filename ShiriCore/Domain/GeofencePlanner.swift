import Foundation

public struct PlannedGeofence: Identifiable, Equatable, Sendable {
    public var id: String { "ny.place." + place.geofenceKey }
    public var place: PlaceRule
    public var cardIDs: [UUID]
}
public struct GeofencePlan: Sendable {
    public var active: [PlannedGeofence]
    public var deferred: [UUID]
}
public enum GeofencePlanner {
    public static let budget = 20
    public static let cooldownSeconds: TimeInterval = 300
    public static func plan(cards: [Card], now: Date, budget: Int = budget) -> GeofencePlan {
        let eligible = cards.filter { $0.lifecycle == .active && $0.recurrenceClosedAt == nil && $0.reminders.isEnabled && $0.place != nil && ($0.place!.endAt ?? .distantFuture) > now }
            .sorted { a,b in
                if a.isPinned != b.isPinned { return a.isPinned }
                if a.importance != b.importance { return a.importance.rank > b.importance.rank }
                return (a.place!.startAt ?? .distantFuture) < (b.place!.startAt ?? .distantFuture)
            }
        var groups: [PlannedGeofence] = []
        for card in eligible {
            if let index = groups.firstIndex(where: { $0.place.geofenceKey == card.place!.geofenceKey }) { groups[index].cardIDs.append(card.id) }
            else { groups.append(PlannedGeofence(place: card.place!, cardIDs: [card.id])) }
        }
        return GeofencePlan(active: Array(groups.prefix(max(0,budget))), deferred: groups.dropFirst(max(0,budget)).flatMap(\.cardIDs))
    }
    public static func shouldNotify(place: PlaceRule, transition: PlaceTrigger, now: Date, lastTrigger: Date?) -> Bool {
        place.trigger == transition && (place.startAt ?? .distantPast) <= now && (place.endAt ?? .distantFuture) > now && lastTrigger.map { now.timeIntervalSince($0) >= cooldownSeconds } != false
    }
}
