import Foundation

public enum ReminderScope: String, Codable, Sendable { case occurrence, series }
public struct NotificationPayload: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var scheduleID: UUID?
    public var version: Int
    public var scope: ReminderScope
    public var occurrenceID: String?
    public var semanticKey: String?
    public var plannedAt: Date?
    public var offsetMinutes: Int
    public init(card: Card, occurrence: Occurrence, scope: ReminderScope, offset: Int) {
        cardID = card.id; scheduleID = card.schedulingID; version = card.schedule?.version ?? 1
        self.scope = scope; offsetMinutes = offset
        if scope == .occurrence { occurrenceID = occurrence.id; semanticKey = occurrence.semanticKey; plannedAt = occurrence.plannedAt }
    }
    /// `deliveredAt` is UNNotification.date, never the later button-tap date.
    public func resolve(in library: LibrarySnapshot, deliveredAt: Date, calendar: Calendar) throws -> Occurrence {
        guard let card = library.cards.first(where: { $0.id == cardID }), card.lifecycle == .active,
              card.schedulingID == scheduleID, (card.schedule?.version ?? 1) == version else { throw ShiriError.validation("这条提醒的日程已经改变，请打开卡片查看") }
        if scope == .occurrence, let occurrenceID, let semanticKey {
            var result = Occurrence(card: card, semanticKey: semanticKey, plannedAt: plannedAt)
            guard result.id == occurrenceID else { throw ShiriError.validation("无法找到这次安排，请打开卡片查看") }
            if let override = library.overrides.first(where: { $0.occurrenceID == occurrenceID }) {
                guard override.kind == .rescheduled, override.newDate == plannedAt else { throw ShiriError.validation("这一次日程已经变更") }
            }
            result.id = occurrenceID; return result
        }
        let target = deliveredAt.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
        let from = calendar.date(byAdding: .day, value: -2, to: target)!
        let until = calendar.date(byAdding: .day, value: 2, to: target)!
        let candidates = OccurrenceEngine(calendar: calendar).occurrences(for: card, in: DateInterval(start: from, end: until), overrides: library.overrides)
        // Delivery may be delayed slightly by the system; match the last eligible planned trigger.
        guard let result = candidates.filter({ ($0.plannedAt ?? .distantFuture) <= target.addingTimeInterval(2) }).last else { throw ShiriError.validation("无法找到这条提醒对应的安排，请打开卡片查看") }
        return result
    }
}
public struct CalendarMatch: Codable, Equatable, Sendable {
    public var hour: Int
    public var minute: Int
    public var weekday: Int?
    public var day: Int?
    public var month: Int?
    public var timeZoneIdentifier: String?
    public var components: DateComponents {
        var value = DateComponents(); value.hour = hour; value.minute = minute; value.second = 0
        value.weekday = weekday; value.day = day; value.month = month
        if let timeZoneIdentifier { value.timeZone = TimeZone(identifier: timeZoneIdentifier) }
        return value
    }
}
public struct PlannedReminder: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var cardID: UUID
    public var title: String
    public var body: String
    public var channel: ReminderChannel
    public var firesAt: Date
    public var calendarMatch: CalendarMatch?
    public var payload: NotificationPayload
    public var isPrimary: Bool
    public var importance: Importance
    public var isCompletionConfirmation: Bool? = nil
}
public struct SchedulingIssue: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(cardID)|\(message)" }
    public var cardID: UUID
    public var message: String
    public init(cardID: UUID, message: String) { self.cardID = cardID; self.message = message }
}
public struct DesiredSchedule: Sendable {
    public var requests: [PlannedReminder]
    public var deferred: [PlannedReminder]
    public var issues: [SchedulingIssue]
    public var coverageEnd: Date
}
public struct ReminderCapabilities: Sendable {
    public var notificationsAllowed: Bool
    public var alarmAllowed: Bool
    public init(notificationsAllowed: Bool, alarmAllowed: Bool = false) { self.notificationsAllowed = notificationsAllowed; self.alarmAllowed = alarmAllowed }
}
public struct ReminderPlanner: Sendable {
    public static let notificationBudget = 48
    public var calendar: Calendar
    public init(calendar: Calendar) { self.calendar = calendar }
    public func plan(library: LibrarySnapshot, preferences: AppPreferences, now: Date, capabilities: ReminderCapabilities, budget: Int = notificationBudget) -> DesiredSchedule {
        let coverage = calendar.date(byAdding: .day, value: 90, to: now)!
        let from = calendar.date(byAdding: .day, value: -1, to: now)!
        let engine = OccurrenceEngine(calendar: calendar)
        var requests: [PlannedReminder] = []; var issues: [SchedulingIssue] = []
        let events = Dictionary(grouping: library.events, by: \.occurrenceID)
        for card in library.cards where card.lifecycle == .active && card.reminders.isEnabled && card.recurrenceClosedAt == nil {
            if card.scope == .privateCloud && !preferences.remindsForPrivateCloudCards && !preferences.enabledCloudCardIDs.contains(card.id) {
                issues.append(SchedulingIssue(cardID: card.id, message: "此设备尚未确认开启云端卡片提醒")); continue
            }
            guard card.reminders.channel == .alarm ? capabilities.alarmAllowed : capabilities.notificationsAllowed else {
                issues.append(SchedulingIssue(cardID: card.id, message: card.reminders.channel == .alarm ? "系统闹钟尚未授权或此设备不支持；可自行改选普通通知" : "通知未授权；卡片已保存")); continue
            }
            let confirmationMinutes = card.kind == .task ? preferences.completionConfirmationMinutes : 0
            if confirmationMinutes > 0, card.reminders.channel == .alarm, !capabilities.notificationsAllowed {
                issues.append(SchedulingIssue(cardID: card.id, message: "到点后的完成确认需要普通通知权限；系统闹钟仍会照常响铃"))
            }
            let birthdayHasTime = card.birthday.map { $0.dayTime != nil || (!$0.advanceDays.isEmpty && $0.advanceTime != nil) } ?? false
            if card.schedule?.time == nil && !birthdayHasTime && card.place == nil {
                issues.append(SchedulingIssue(cardID: card.id, message: "待选择提醒时间")); continue
            }
            var occurrences = engine.occurrences(for: card, in: DateInterval(start: from, end: calendar.date(byAdding: .year, value: 2, to: now)!), overrides: library.overrides, limit: 100)
            if occurrences.isEmpty, let next = engine.next(for: card, after: now, overrides: library.overrides) { occurrences.append(next) }
            let snoozed = library.personalStates.values.filter { ($0.snoozedUntil ?? .distantPast).addingTimeInterval(Double(confirmationMinutes * 60)) > now }.compactMap(\.snoozedOccurrence).filter { $0.cardID == card.id && $0.scheduleID == card.schedulingID }
            for occurrence in snoozed where !occurrences.contains(where: { $0.id == occurrence.id }) { occurrences.append(occurrence) }
            let specific = library.overrides.contains { $0.cardID == card.id } || occurrences.contains { occurrence in
                let state = library.personalStates[occurrence.id]
                return (occurrence.plannedAt ?? .distantPast).addingTimeInterval(Double(confirmationMinutes * 60)) > now && (state?.isStopped == true || state?.snoozedUntil != nil || EventReducer.state(events: events[occurrence.id] ?? []) != .pending)
            }
            var seriesUsed: Set<String> = []
            var primaryAssigned = false
            for occurrence in occurrences {
                guard let date = occurrence.plannedAt ?? library.personalStates[occurrence.id]?.snoozedUntil else { continue }
                let state = library.personalStates[occurrence.id]
                guard EventReducer.state(events: events[occurrence.id] ?? []) == .pending, state?.isStopped != true else { continue }
                var slots: [(String, Date, Int)] = []
                if let snoozed = state?.snoozedUntil { slots = [("snooze", snoozed, 0)] }
                else {
                    slots = Set(card.birthday != nil && card.birthday?.dayTime == nil ? [] : card.reminders.advanceMinutes).sorted().map { ("advance\($0)", date.addingTimeInterval(TimeInterval(-$0 * 60)), -$0) }
                    slots += Set(card.birthday != nil && card.birthday?.dayTime == nil ? [] : card.reminders.followUpMinutes).sorted().map { ("followup\($0)", date.addingTimeInterval(TimeInterval($0 * 60)), $0) }
                    if let birthday = card.birthday, let time = birthday.advanceTime {
                        for days in birthday.advanceDays {
                            if let day = calendar.date(byAdding: .day, value: -days, to: date), let trigger = engine.date(CivilDate(day, calendar: calendar), time: time) { slots.append(("birthday\(days)", trigger, -days * 1440)) }
                        }
                    }
                }
                let confirmationAt = confirmationMinutes > 0 ? (state?.snoozedUntil ?? date).addingTimeInterval(Double(confirmationMinutes * 60)) : nil
                if card.kind == .task, capabilities.notificationsAllowed, let confirmationAt {
                    if card.reminders.channel == .notification { slots.removeAll { $0.1 == confirmationAt } }
                    slots.append(("confirmation", confirmationAt, Int(confirmationAt.timeIntervalSince(date) / 60)))
                }
                for (slot, trigger, offset) in slots where trigger > now {
                    let isConfirmation = slot == "confirmation"
                    let channel: ReminderChannel = isConfirmation ? .notification : card.reminders.channel
                    var match: CalendarMatch?
                    if (slot == "advance0" || (isConfirmation && state?.snoozedUntil == nil)), !specific, channel == .notification, let rule = card.schedule,
                       rule.interval == 1, rule.end == nil, rule.timeZoneMode != .elapsed, rule.time != nil {
                        let cal = rule.calendar(fallback: calendar)
                        let baseTime = rule.time!
                        let nominalMinutes = baseTime.hour * 60 + baseTime.minute + (isConfirmation ? confirmationMinutes : 0)
                        let time = DayTime(hour: (nominalMinutes / 60) % 24, minute: nominalMinutes % 60)
                        let zone = rule.timeZoneMode == .fixed ? rule.timeZoneIdentifier : nil
                        switch rule.frequency {
                        case .daily: match = CalendarMatch(hour: time.hour, minute: time.minute, timeZoneIdentifier: zone)
                        case .weekly: match = CalendarMatch(hour: time.hour, minute: time.minute, weekday: cal.component(.weekday, from: trigger), timeZoneIdentifier: zone)
                        case .monthly where rule.monthDay <= 28 && cal.component(.day, from: trigger) <= 28 && cal.component(.month, from: trigger) == cal.component(.month, from: date): match = CalendarMatch(hour: time.hour, minute: time.minute, day: cal.component(.day, from: trigger), timeZoneIdentifier: zone)
                        case .yearly where !(rule.month == 2 && rule.monthDay >= 29) && cal.isDate(trigger, inSameDayAs: date): match = CalendarMatch(hour: time.hour, minute: time.minute, day: rule.monthDay, month: rule.month, timeZoneIdentifier: zone)
                        default: break
                        }
                    }
                    let seriesKey = "\(card.id)|\(card.schedule?.id.uuidString ?? "")|\(match?.weekday ?? 0)" + (isConfirmation ? "|confirmation" : "")
                    if let candidate = match {
                        // Once registered, this calendar trigger also covers later matching
                        // dates. Do not turn those dates into duplicate one-off requests.
                        if seriesUsed.contains(seriesKey) { continue }
                        let cal = card.schedule!.calendar(fallback: calendar)
                        let next = cal.nextDate(after: now, matching: candidate.components, matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first)
                        if next.map({ abs($0.timeIntervalSince(trigger)) < 1 }) != true { match = nil }
                    }
                    if match != nil && !seriesUsed.insert(seriesKey).inserted { continue }
                    if match == nil && trigger > coverage && primaryAssigned { continue }
                    let payload = NotificationPayload(card: card, occurrence: occurrence, scope: match == nil ? .occurrence : .series, offset: offset)
                    let id = "ny.reminder." + StableID.hash("\(match == nil ? occurrence.id : seriesKey)|\(slot)|\(channel.rawValue)")
                    let title = preferences.notificationPrivacy == .hidden ? "有一件事等你处理" : card.title
                    let body = isConfirmation ? "点开选择已完成、10 分钟后提醒或更改时间。" : (preferences.notificationPrivacy == .full ? card.note : "点开查看或处理这一次安排")
                    let primary = !isConfirmation && !primaryAssigned && (slot == "advance0" || !card.reminders.advanceMinutes.contains(0) || slot == "snooze" || (card.birthday != nil && card.birthday?.dayTime == nil))
                    if primary { primaryAssigned = true }
                    requests.append(PlannedReminder(id: id, cardID: card.id, title: title, body: body, channel: channel, firesAt: trigger, calendarMatch: match, payload: payload, isPrimary: primary, importance: card.importance, isCompletionConfirmation: isConfirmation ? true : nil))
                }
            }
        }
        requests.sort {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            if $0.firesAt != $1.firesAt { return $0.firesAt < $1.firesAt }
            return $0.id < $1.id
        }
        let notifications = requests.filter { $0.channel == .notification }
        let acceptedIDs = Set(notifications.prefix(max(0, budget - (preferences.showReviewReminder ? 1 : 0))).map(\.id))
        let accepted = requests.filter { $0.channel == .alarm || acceptedIDs.contains($0.id) }
        let deferred = notifications.filter { !acceptedIDs.contains($0.id) }
        for id in Set(deferred.filter(\.isPrimary).map(\.cardID)) { issues.append(SchedulingIssue(cardID: id, message: "提醒数量较多，这张卡片的到点提醒尚未安排")) }
        return DesiredSchedule(requests: accepted, deferred: deferred, issues: issues, coverageEnd: coverage)
    }
}
public struct ReminderLedgerEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case registered, failed, pendingVerification }
    public var id: String { request.id }
    public var request: PlannedReminder
    public var status: Status
    public var message: String?
    public var checkedAt: Date
    public init(request: PlannedReminder, status: Status, message: String? = nil, now: Date) { self.request = request; self.status = status; self.message = message; checkedAt = now }
}
