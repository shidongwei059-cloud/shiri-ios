import Foundation

public enum ReviewPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, year
    public var id: String { rawValue }
    public var title: String { switch self { case .week: return "周"; case .month: return "月"; case .year: return "年" } }
    public var component: Calendar.Component { switch self { case .week: return .weekOfYear; case .month: return .month; case .year: return .year } }
}
public struct ReviewBucket: Identifiable, Equatable, Sendable {
    public var id: Date
    public var count: Int
}
public struct ReviewSummary: Sendable {
    public var interval: DateInterval
    public var completed: [TaskEvent]
    public var planned: [Occurrence]
    public var plannedCompleted: Int
    public var onTimeCompleted: Int
    public var withDeadline: Int
    public var longTermCompleted: Int
    public var importantPlanned: Int
    public var importantCompleted: Int
    public var categories: [String: Int]
    public var buckets: [ReviewBucket]
    public var completionRate: Double? { planned.isEmpty ? nil : Double(plannedCompleted) / Double(planned.count) }
}
public enum ReviewCalculator {
    public static func summarize(library: LibrarySnapshot, interval: DateInterval, calendar: Calendar, now: Date, period: ReviewPeriod) -> ReviewSummary {
        let events = Dictionary(grouping: library.events.filter { $0.happenedAt <= now }, by: \.occurrenceID)
        let allCompleted = events.values.compactMap { EventReducer.completion(events: $0) }.filter { $0.snapshot.kind == .task }
        let completed = allCompleted.filter { interval.containsHalfOpen($0.happenedAt) }.sorted { $0.happenedAt > $1.happenedAt }
        var occurrences = library.occurrences.filter { $0.plannedAt.map(interval.containsHalfOpen) == true }
        let engine = OccurrenceEngine(calendar: calendar)
        let histories = Dictionary(grouping: library.revisions, by: \.cardID)
        for card in library.cards {
            if Task.isCancelled { break }
            let history = (histories[card.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            if history.count < 2 {
                if card.kind == .task && card.birthday == nil { occurrences += engine.occurrences(for: card, in: interval, overrides: library.overrides, limit: 400) }
                continue
            }
            for (index, revision) in history.enumerated() {
                guard revision.snapshot.kind == .task && revision.snapshot.birthday == nil else { continue }
                let lower = index == 0 ? interval.start : max(interval.start, revision.createdAt)
                let upper = index + 1 < history.count ? min(interval.end, history[index + 1].createdAt) : interval.end
                if upper > lower { occurrences += engine.occurrences(for: revision.snapshot, in: DateInterval(start: lower, end: upper), overrides: library.overrides, limit: 400) }
            }
        }
        var seen: Set<String> = []
        let planned = occurrences.filter {
            seen.insert($0.id).inserted && $0.plannedAt != nil && $0.snapshot.kind == .task && EventReducer.state(events: events[$0.id] ?? []) != .skipped
        }
        let completedIDs = Set(allCompleted.map(\.occurrenceID))
        let important = planned.filter { $0.snapshot.importance != .normal }
        let deadlines = planned.filter { $0.dueAt != nil }
        let onTime = deadlines.filter { occurrence in
            guard let date = EventReducer.completion(events: events[occurrence.id] ?? [])?.happenedAt, let due = occurrence.dueAt else { return false }
            return date <= due
        }.count
        var cursor = interval.start; var buckets: [ReviewBucket] = []
        let unit: Calendar.Component = period == .year ? .month : .day
        while cursor < interval.end {
            if Task.isCancelled { break }
            guard let end = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
            buckets.append(ReviewBucket(id: cursor, count: completed.filter { $0.happenedAt >= cursor && $0.happenedAt < end }.count)); cursor = end
        }
        return ReviewSummary(interval: interval, completed: completed, planned: planned,
                             plannedCompleted: planned.filter { completedIDs.contains($0.id) }.count, onTimeCompleted: onTime, withDeadline: deadlines.count,
                             longTermCompleted: completed.filter { $0.snapshot.plannedAt == nil && $0.snapshot.dueAt == nil }.count,
                             importantPlanned: important.count, importantCompleted: important.filter { completedIDs.contains($0.id) }.count,
                             categories: Dictionary(grouping: completed, by: { $0.snapshot.category }).mapValues(\.count), buckets: buckets)
    }
}
