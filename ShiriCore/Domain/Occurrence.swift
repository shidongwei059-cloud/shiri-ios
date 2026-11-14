import Foundation

public enum OccurrenceState: String, Codable, CaseIterable, Sendable { case pending, completed, skipped, canceled }

public struct HistorySnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var category: String
    public var importance: Importance
    public var kind: CardKind
    public var plannedAt: Date?
    public var dueAt: Date?
    public init(card: Card, plannedAt: Date?) {
        title = card.title; category = card.category; importance = card.importance; kind = card.kind
        self.plannedAt = plannedAt; dueAt = card.schedule?.dueAt
    }
}

public struct Occurrence: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var semanticKey: String
    public var cardID: UUID
    public var scheduleID: UUID?
    public var plannedAt: Date?
    public var dueAt: Date?
    public var snapshot: HistorySnapshot
    public init(card: Card, semanticKey: String, plannedAt: Date?) {
        self.semanticKey = semanticKey; self.cardID = card.id; self.scheduleID = card.schedulingID
        self.id = StableID.hash("\(card.id)|\(card.schedulingID?.uuidString ?? "unscheduled")|\(semanticKey)")
        self.plannedAt = plannedAt; self.dueAt = card.schedule?.dueAt
        self.snapshot = HistorySnapshot(card: card, plannedAt: plannedAt)
    }
}

public enum OccurrenceOverrideKind: String, Codable, Sendable { case rescheduled, skipped, canceled }

public struct OccurrenceOverride: Identifiable, Codable, Equatable, Sendable {
    public var id: String { occurrenceID }
    public var occurrenceID: String
    public var cardID: UUID
    public var kind: OccurrenceOverrideKind
    public var newDate: Date?
    public var original: Occurrence?
    public var createdAt: Date
    public init(occurrenceID: String, cardID: UUID, kind: OccurrenceOverrideKind, newDate: Date?, now: Date, original: Occurrence? = nil) {
        self.occurrenceID = occurrenceID; self.cardID = cardID; self.kind = kind; self.newDate = newDate; createdAt = now; self.original = original
    }
}

public enum TaskEventKind: String, Codable, Sendable { case completed, reopened, skipped, unskipped }

public struct TaskEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var operationID: UUID
    public var occurrenceID: String
    public var cardID: UUID
    public var actorID: String
    public var kind: TaskEventKind
    public var happenedAt: Date
    /// Causal references: reopening only undoes completions that the user has actually observed.
    public var reverses: [UUID]
    public var snapshot: HistorySnapshot
    public init(operationID: UUID, occurrence: Occurrence, actorID: String, kind: TaskEventKind, now: Date, reverses: [UUID] = []) {
        self.id = StableID.uuid("task-event|\(operationID)"); self.operationID = operationID
        self.occurrenceID = occurrence.id; self.cardID = occurrence.cardID; self.actorID = actorID
        self.kind = kind; self.happenedAt = now; self.reverses = reverses; self.snapshot = occurrence.snapshot
    }
}

public enum EventReducer {
    public static func effectiveCompletions(_ events: [TaskEvent]) -> [TaskEvent] {
        let unique = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let reversed = Set(unique.filter { $0.kind == .reopened }.flatMap(\.reverses))
        return unique.filter { $0.kind == .completed && !reversed.contains($0.id) }.sorted { $0.happenedAt == $1.happenedAt ? $0.id.uuidString < $1.id.uuidString : $0.happenedAt < $1.happenedAt }
    }
    public static func state(events: [TaskEvent]) -> OccurrenceState {
        if !effectiveCompletions(events).isEmpty { return .completed }
        let reversed = Set(events.filter { $0.kind == .unskipped }.flatMap(\.reverses))
        if events.contains(where: { $0.kind == .skipped && !reversed.contains($0.id) }) { return .skipped }
        return .pending
    }
    public static func completion(events: [TaskEvent]) -> TaskEvent? { effectiveCompletions(events).first }
}

public struct PersonalReminderState: Codable, Equatable, Sendable {
    public var occurrenceID: String
    public var snoozedUntil: Date?
    public var snoozedOccurrence: Occurrence?
    public var isStopped: Bool
    public var updatedAt: Date
    public init(occurrenceID: String, now: Date) { self.occurrenceID = occurrenceID; isStopped = false; updatedAt = now }
}

public struct PersonalReminderEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case snoozed, stopped, resumed, alarmStopped, locationTriggered }
    public var id: UUID
    public var occurrenceID: String
    public var kind: Kind
    public var happenedAt: Date
    public var until: Date?
    public init(operationID: UUID, occurrenceID: String, kind: Kind, now: Date, until: Date? = nil) {
        id = operationID; self.occurrenceID = occurrenceID; self.kind = kind; happenedAt = now; self.until = until
    }
}

public struct CardProjection: Identifiable, Equatable, Sendable {
    public var id: UUID { card.id }
    public var card: Card
    public var occurrence: Occurrence?
    public var state: OccurrenceState
    public var completedAt: Date?
    public var reminderState: PersonalReminderState?
    public var hasConflict: Bool
    public init(card: Card, occurrence: Occurrence?, events: [TaskEvent] = [], reminderState: PersonalReminderState? = nil, hasConflict: Bool = false) {
        self.card = card; self.occurrence = occurrence; self.reminderState = reminderState; self.hasConflict = hasConflict
        state = EventReducer.state(events: events); completedAt = EventReducer.completion(events: events)?.happenedAt
    }

    /// Completion is the first sort key, so pinning or a recent edit cannot lift a handled task above pending work.
    public static func libraryOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        func rank(_ value: Self) -> Int {
            guard value.card.kind == .task, value.card.birthday == nil else { return 0 }
            if value.card.recurrenceClosedAt != nil { return 2 }
            switch value.state { case .pending: return 0; case .completed: return 1; case .skipped, .canceled: return 2 }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        if lhs.card.isPinned != rhs.card.isPinned { return lhs.card.isPinned }
        if lhs.card.updatedAt != rhs.card.updatedAt { return lhs.card.updatedAt > rhs.card.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct OccurrenceEngine: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar) { self.calendar = calendar }

    public func occurrences(for card: Card, in interval: DateInterval, overrides: [OccurrenceOverride] = [], limit: Int = 500) -> [Occurrence] {
        guard card.lifecycle == .active, limit > 0 else { return [] }
        let overrideMap = Dictionary(overrides.map { ($0.occurrenceID, $0) }, uniquingKeysWith: { _, last in last })
        var result: [Occurrence] = []
        if let birthday = card.birthday {
            let dates = BirthdayCalendarEngine(calendar: calendar).dates(for: birthday, in: interval)
            result = dates.map { date in
                var occurrence = Occurrence(card: card, semanticKey: "birthday|\(CivilDate(date, calendar: calendar).key)", plannedAt: date)
                occurrence.dueAt = nil; return occurrence
            }
        } else if let definition = card.schedule {
            let cal = definition.calendar(fallback: calendar)
            if definition.timeZoneMode == .elapsed, let instant = definition.absoluteInstant {
                if interval.containsHalfOpen(instant) { result = [Occurrence(card: card, semanticKey: "instant|\(Int(instant.timeIntervalSince1970))", plannedAt: instant)] }
            } else if let startDate = date(definition.start, time: DayTime(hour: 0), calendar: cal) {
                var day = max(cal.startOfDay(for: interval.start), startDate)
                let end = min(interval.end, card.recurrenceClosedAt ?? interval.end)
                let jumpsByMonth = [.monthly, .yearly].contains(definition.frequency)
                if jumpsByMonth { day = cal.dateInterval(of: .month, for: day)?.start ?? day }
                while day < end && result.count < limit + overrides.count {
                    var candidate = day
                    if jumpsByMonth, let count = cal.range(of: .day, in: .month, for: day)?.count {
                        let dayNumber = min(definition.monthDay, count)
                        candidate = cal.date(byAdding: .day, value: dayNumber - 1, to: day) ?? day
                    }
                    let civil = CivilDate(candidate, calendar: cal)
                    if let until = definition.end, civil.key > until.key { break }
                    if candidate >= startDate, matches(day: candidate, startDate: startDate, rule: definition, calendar: cal),
                       let planned = date(civil, time: definition.time ?? DayTime(hour: 0), calendar: cal), interval.containsHalfOpen(planned), planned < end {
                        let timeKey = definition.time?.display ?? "date"
                        result.append(Occurrence(card: card, semanticKey: "\(civil.key)|\(timeKey)", plannedAt: planned))
                    }
                    guard let next = cal.date(byAdding: jumpsByMonth ? .month : .day, value: 1, to: day), next > day else { break }
                    day = next
                    if definition.frequency == .never && day > startDate { break }
                }
            }
        } else if card.kind == .task || card.place != nil {
            result = [Occurrence(card: card, semanticKey: card.place == nil ? "undated" : "place", plannedAt: nil)]
        }
        let existingIDs = Set(result.map(\.id))
        for override in overrides where override.cardID == card.id && !existingIDs.contains(override.occurrenceID) {
            if let original = override.original, original.scheduleID == card.schedulingID, let target = override.newDate, interval.containsHalfOpen(target), override.kind == .rescheduled { result.append(original) }
        }
        return Array(result.compactMap { original in
            if let closed = card.recurrenceClosedAt, (original.plannedAt ?? closed) >= closed { return nil }
            guard let override = overrideMap[original.id] else { return original }
            guard override.kind == .rescheduled, let newDate = override.newDate else { return nil }
            guard interval.containsHalfOpen(newDate), newDate < (card.recurrenceClosedAt ?? .distantFuture) else { return nil }
            var updated = original; updated.plannedAt = newDate; updated.snapshot.plannedAt = newDate; return updated
        }.sorted { ($0.plannedAt ?? .distantFuture) < ($1.plannedAt ?? .distantFuture) }.prefix(limit))
    }

    public func next(for card: Card, after date: Date, overrides: [OccurrenceOverride] = []) -> Occurrence? {
        guard card.lifecycle == .active else { return nil }
        if let rule = card.schedule, rule.frequency == .never {
            let cal = rule.calendar(fallback: calendar)
            let target = rule.absoluteInstant ?? self.date(rule.start, time: rule.time ?? DayTime(hour: 0), calendar: cal)
            let latestOverride = overrides.filter { $0.cardID == card.id }.compactMap(\.newDate).max()
            let end = max(target ?? date, latestOverride ?? date).addingTimeInterval(2 * 86400)
            return occurrences(for: card, in: DateInterval(start: date, end: max(date, end)), overrides: overrides, limit: 1).first
        }
        if card.birthday != nil {
            let end = calendar.date(byAdding: .year, value: 40, to: date) ?? date
            return occurrences(for: card, in: DateInterval(start: date, end: end), overrides: overrides, limit: 1).first
        }
        let spacing = card.schedule?.interval ?? 1
        let years: Int
        switch card.schedule?.frequency {
        case .yearly: years = spacing * 4 + 4
        case .monthly: years = spacing / 12 * 4 + 4
        case .weekly: years = spacing * 7 / 365 + 2
        default: years = 2
        }
        let end = calendar.date(byAdding: .year, value: years, to: date) ?? date
        return occurrences(for: card, in: DateInterval(start: date, end: end), overrides: overrides, limit: 1).first
    }

    /// A pending single occurrence remains actionable after its date; repeating cards use the next occurrence.
    public func relevantOccurrence(for card: Card, at date: Date, overrides: [OccurrenceOverride] = []) -> Occurrence? {
        guard card.lifecycle == .active else { return nil }
        if let rule = card.schedule, rule.frequency == .never {
            let cal = rule.calendar(fallback: calendar)
            guard let start = rule.absoluteInstant ?? self.date(rule.start, time: DayTime(hour: 0), calendar: cal) else { return nil }
            let moved = overrides.filter { $0.cardID == card.id && $0.kind == .rescheduled }.compactMap(\.newDate)
            let low = min(start, moved.min() ?? start).addingTimeInterval(-1)
            let high = max(start.addingTimeInterval(86400), moved.max() ?? start).addingTimeInterval(1)
            return occurrences(for: card, in: DateInterval(start: low, end: high), overrides: overrides, limit: 1).first
        }
        return next(for: card, after: calendar.startOfDay(for: date), overrides: overrides)
    }

    public func date(_ day: CivilDate, time: DayTime, calendar: Calendar? = nil) -> Date? {
        let cal = calendar ?? self.calendar
        guard time.isValid,
              let start = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              CivilDate(start, calendar: cal) == day else { return nil }
        let match = DateComponents(hour: time.hour, minute: time.minute, second: 0)
        // A DST gap preserves minutes by advancing to the next valid local time; a repeated time uses its first occurrence.
        guard let value = cal.nextDate(after: start.addingTimeInterval(-1), matching: match,
                                       matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first),
              cal.isDate(value, inSameDayAs: start) else { return nil }
        return value
    }

    private func matches(day: Date, startDate: Date, rule: ScheduleDefinition, calendar: Calendar) -> Bool {
        let civil = CivilDate(day, calendar: calendar)
        switch rule.frequency {
        case .never: return civil == rule.start
        case .daily:
            return (calendar.dateComponents([.day], from: startDate, to: day).day ?? -1) % max(1, rule.interval) == 0
        case .weekly:
            guard rule.weekdays.contains(calendar.component(.weekday, from: day)),
                  let weekStart = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start,
                  let currentWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { return false }
            return (calendar.dateComponents([.weekOfYear], from: weekStart, to: currentWeek).weekOfYear ?? -1) % max(1, rule.interval) == 0
        case .monthly:
            let months = (civil.year - rule.start.year) * 12 + civil.month - rule.start.month
            return months >= 0 && months % max(1, rule.interval) == 0 && isMatchingMonthDay(day, desired: rule.monthDay, policy: rule.missingDatePolicy, calendar: calendar)
        case .yearly:
            return civil.month == rule.month && (civil.year - rule.start.year) % max(1, rule.interval) == 0 && isMatchingMonthDay(day, desired: rule.monthDay, policy: rule.missingDatePolicy, calendar: calendar)
        }
    }
    private func isMatchingMonthDay(_ day: Date, desired: Int, policy: MissingDatePolicy, calendar: Calendar) -> Bool {
        guard let count = calendar.range(of: .day, in: .month, for: day)?.count else { return false }
        let target = desired <= count ? desired : (policy == .lastValidDay ? count : -1)
        return calendar.component(.day, from: day) == target
    }
}

public struct BirthdayCalendarEngine: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar) { self.calendar = calendar }

    public func dates(for rule: BirthdayRule, in interval: DateInterval) -> [Date] {
        guard (try? rule.validate()) != nil, let kind = rule.calendar else { return [] }
        let time = rule.dayTime ?? DayTime(hour: 0)
        if !rule.repeatsYearly, let day = rule.oneTimeDate,
           let date = OccurrenceEngine(calendar: calendar).date(day, time: time) {
            return interval.containsHalfOpen(date) ? [date] : []
        }
        var result: [Date] = []
        if kind == .gregorian {
            let firstYear = calendar.component(.year, from: interval.start)
            let lastYear = min(firstYear + 40, calendar.component(.year, from: interval.end))
            for year in firstYear...max(firstYear, lastYear) {
                guard let monthStart = calendar.date(from: DateComponents(year: year, month: rule.month, day: 1)),
                      let days = calendar.range(of: .day, in: .month, for: monthStart)?.count else { continue }
                let day = rule.day <= days ? rule.day : (rule.missingDatePolicy == .lastValidDay ? days : 0)
                if day > 0, let date = OccurrenceEngine(calendar: calendar).date(CivilDate(year: year, month: rule.month, day: day), time: time), interval.containsHalfOpen(date) { result.append(date) }
            }
        } else {
            var lunar = Calendar(identifier: .chinese); lunar.timeZone = calendar.timeZone
            let lower = calendar.date(byAdding: .year, value: -1, to: interval.start) ?? interval.start
            let upper = calendar.date(byAdding: .year, value: 1, to: interval.end) ?? interval.end
            var cursor = lunar.dateInterval(of: .month, for: lower)?.start ?? lower
            struct YearCandidates { var regular: Date?; var leap: Date?; var hasLeap = false }
            var years: [String: YearCandidates] = [:]
            var iterations = 0
            while cursor < upper && iterations < 550 {
                iterations += 1
                let components = lunar.dateComponents(in: lunar.timeZone, from: cursor)
                if components.month == rule.month, let count = lunar.range(of: .day, in: .month, for: cursor)?.count {
                    let key = "\(components.era ?? 0)-\(components.year ?? 0)"
                    var entry = years[key] ?? YearCandidates()
                    let leap = components.isLeapMonth == true
                    if leap { entry.hasLeap = true }
                    let day = rule.day <= count ? rule.day : (rule.missingDatePolicy == .lastValidDay ? count : 0)
                    if day > 0, let target = lunar.date(byAdding: .day, value: day - 1, to: cursor),
                       let date = OccurrenceEngine(calendar: calendar).date(CivilDate(target, calendar: calendar), time: time) {
                        if leap { entry.leap = date } else { entry.regular = date }
                    }
                    years[key] = entry
                }
                guard let next = lunar.date(byAdding: .month, value: 1, to: cursor), next > cursor else { break }
                cursor = lunar.dateInterval(of: .month, for: next)?.start ?? next
            }
            for entry in years.values {
                let chosen: Date?
                if rule.isLeapMonth {
                    chosen = entry.hasLeap ? entry.leap : (rule.leapMonthPolicy == .regularWhenMissing ? entry.regular : nil)
                } else { chosen = entry.regular }
                if let chosen, interval.containsHalfOpen(chosen) { result.append(chosen) }
            }
        }
        result.sort()
        return rule.repeatsYearly ? result : Array(result.prefix(1))
    }

    public func nextDates(for rule: BirthdayRule, after now: Date, limit: Int = 3) -> [Date] {
        let end = calendar.date(byAdding: .year, value: 40, to: now) ?? now
        return Array(dates(for: rule, in: DateInterval(start: now, end: end)).prefix(limit))
    }
}
