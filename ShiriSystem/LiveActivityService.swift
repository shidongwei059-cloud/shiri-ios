import ActivityKit
import ShiriCore
import Foundation

@MainActor
final class LiveActivityService {
    static func hasClockTime(_ card: Card) -> Bool {
        card.schedule?.time != nil || card.schedule?.absoluteInstant != nil || card.birthday?.dayTime != nil
    }

    func status(for projection: CardProjection, now: Date = Date()) -> String {
        guard #available(iOS 16.1, *) else { return "此设备暂不支持锁屏待办卡片" }
        guard projection.card.lifecycle == .active, projection.card.recurrenceClosedAt == nil, projection.state == .pending else { return "这次活动已结束" }
        if projection.card.reminders.isEnabled && projection.card.reminders.channel == .alarm { return "已选择闹钟提醒，到点时显示" }
        guard projection.card.reminders.enablesLiveActivity else { return "未开启" }
        if projection.reminderState?.isStopped == true { return "此设备已暂停这一次提醒" }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return "系统尚未允许实时活动" }
        let activities = Activity<ShiriActivityAttributes>.activities.filter {
            $0.attributes.cardID == projection.card.id.uuidString && $0.attributes.occurrenceID == projection.occurrence?.id
        }
        if activities.contains(where: { $0.activityState == .active }) { return "已开启 · 请锁屏查看" }
        if #available(iOS 16.2, *), activities.contains(where: { $0.activityState == .stale }) { return "安排时间已过 · 请检查时间" }
        if #available(iOS 26.0, *), let pending = activities.first(where: { $0.activityState == .pending }), let target = pending.contentState.targetDate {
            return "已预约 · " + DateFormatter.localizedString(from: target.addingTimeInterval(-1800), dateStyle: .short, timeStyle: .short) + " 开始"
        }
        if let reason = eligibilityIssue(projection, now: now) { return reason }
        return "尚未显示 · 可以立即开启"
    }

    /// Registration is not proof that iOS is currently displaying the card. In particular,
    /// the app cannot read the separate passcode setting for access while locked.
    func eligibilityIssue(_ projection: CardProjection, now: Date) -> String? {
        let card = projection.card
        guard card.lifecycle == .active, card.recurrenceClosedAt == nil, projection.state == .pending else { return "这一次已结束" }
        guard !card.reminders.isEnabled || card.reminders.channel != .alarm else { return "已选择闹钟提醒，到点时显示" }
        guard projection.reminderState?.isStopped != true else { return "这次提醒已停止，请先恢复提醒" }
        guard let occurrence = projection.occurrence else { return "没有可显示的待办安排" }
        if Self.hasClockTime(card) {
            guard let target = occurrence.plannedAt, target > now else { return "安排时间已过，请先调整到未来时间" }
        } else if let target = occurrence.plannedAt {
            let calendar = card.schedule?.calendar(fallback: .current) ?? .current
            guard target >= calendar.startOfDay(for: now) else { return "安排日期已过，请先调整日期" }
        } else if card.kind != .task { return "随手记不显示为锁屏待办" }
        return nil
    }

    @available(iOS 16.1, *)
    private func contentState(_ projection: CardProjection, privacy: ContentPrivacy) -> ShiriActivityAttributes.ContentState {
        .init(title: privacy == .hidden ? "有一件事等你处理" : projection.card.title,
              targetDate: projection.occurrence?.plannedAt, isHidden: privacy == .hidden,
              isDateOnly: !Self.hasClockTime(projection.card))
    }

    @available(iOS 16.2, *)
    private func content(_ state: ShiriActivityAttributes.ContentState, now: Date) -> ActivityContent<ShiriActivityAttributes.ContentState> {
        let staleDate = state.targetDate.map { state.isDateOnly == true ? $0.addingTimeInterval(86400) : $0.addingTimeInterval(3600) }
        let distance = max(0, state.targetDate?.timeIntervalSince(now) ?? 86400)
        return ActivityContent(state: state, staleDate: staleDate, relevanceScore: 1 / (1 + distance / 3600))
    }

    @available(iOS 16.1, *)
    private func update(_ activity: Activity<ShiriActivityAttributes>, state: ShiriActivityAttributes.ContentState, now: Date) async {
        if #available(iOS 16.2, *) { await activity.update(content(state, now: now)) }
        else { await activity.update(using: state) }
    }
    func start(_ projection: CardProjection, privacy: ContentPrivacy, scheduled: Bool, now: Date) async throws {
        guard #available(iOS 16.1, *) else { throw ShiriError.unavailable("此设备暂不支持锁屏待办卡片。") }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw ShiriError.unavailable("请在系统设置中允许拾日使用实时活动") }
        if let reason = eligibilityIssue(projection, now: now) { throw ShiriError.validation(reason) }
        guard projection.card.reminders.enablesLiveActivity, let occurrence = projection.occurrence else { throw ShiriError.validation("请先开启显示待办卡片") }
        let attributes = ShiriActivityAttributes(cardID: projection.card.id.uuidString, occurrenceID: occurrence.id)
        let state = contentState(projection, privacy: privacy)
        // Saving the same occurrence updates its card without restarting it or replacing another card.
        let existing = Activity<ShiriActivityAttributes>.activities.filter {
            $0.attributes.occurrenceID == occurrence.id && $0.attributes.cardID == projection.card.id.uuidString
        }
        let startDate = Self.hasClockTime(projection.card) ? occurrence.plannedAt?.addingTimeInterval(-1800) : nil
        let schedulesLater = scheduled && (startDate.map { $0 > now.addingTimeInterval(60) } ?? false)
        for activity in existing {
            if activity.activityState == .dismissed || activity.activityState == .ended { continue }
            if #available(iOS 26.0, *), activity.activityState == .pending {
                if schedulesLater && activity.contentState.targetDate == state.targetDate {
                    await update(activity, state: state, now: now)
                    return
                }
                await activity.end(using: nil, dismissalPolicy: .immediate)
                continue
            }
            if schedulesLater {
                await activity.end(using: nil, dismissalPolicy: .immediate)
            } else {
                await update(activity, state: state, now: now)
                return
            }
        }
        if schedulesLater, let startDate {
            guard #available(iOS 26.0, *) else { throw ShiriError.unavailable("此设备暂不支持提前显示，请选择立即显示。") }
            _ = try Activity.request(attributes: attributes, content: content(state, now: now), style: .standard, alertConfiguration: AlertConfiguration(title: "拾日", body: "你的安排即将开始", sound: .default), start: startDate)
        } else if #available(iOS 16.2, *) {
            _ = try Activity.request(attributes: attributes, content: content(state, now: now), pushType: nil)
        } else {
            _ = try Activity.request(attributes: attributes, contentState: state)
        }
    }
    @discardableResult
    func reconcile(library: LibrarySnapshot, privacy: ContentPrivacy, now: Date) async -> [String] {
        guard #available(iOS 16.1, *) else { return [] }
        var failures: [String] = []
        for activity in Activity<ShiriActivityAttributes>.activities {
            let id = activity.attributes.occurrenceID
            guard let card = library.cards.first(where: { $0.id.uuidString == activity.attributes.cardID }), card.lifecycle == .active,
                  card.recurrenceClosedAt == nil, card.reminders.enablesLiveActivity,
                  EventReducer.state(events: library.events(for: id)) == .pending, library.personalStates[id]?.isStopped != true,
                  (!card.reminders.isEnabled || card.reminders.channel != .alarm) else {
                await activity.end(using: nil, dismissalPolicy: .immediate); continue
            }
            let originalTarget = activity.contentState.targetDate ?? now
            let candidates = OccurrenceEngine(calendar: .current).occurrences(for: card, in: DateInterval(start: originalTarget.addingTimeInterval(-86400), end: originalTarget.addingTimeInterval(86400)), overrides: library.overrides)
            let moved = library.overrides.first { $0.occurrenceID == id && $0.original?.scheduleID == card.schedulingID && $0.kind == .rescheduled }?.newDate
            var occurrence = candidates.first { $0.id == id }
            if let moved, var original = library.overrides.first(where: { $0.occurrenceID == id })?.original {
                original.plannedAt = moved; occurrence = original
            }
            guard let occurrence else { await activity.end(using: nil, dismissalPolicy: .immediate); continue }
            let projection = CardProjection(card: card, occurrence: occurrence, events: library.events(for: id), reminderState: library.personalStates[id])
            let state = contentState(projection, privacy: privacy)
            if let target = state.targetDate {
                let calendar = card.schedule?.calendar(fallback: .current) ?? .current
                let expired = Self.hasClockTime(card) ? target <= now.addingTimeInterval(-3600) : target < calendar.startOfDay(for: now)
                if expired { await activity.end(using: nil, dismissalPolicy: .immediate); continue }
            }
            if #available(iOS 26.0, *), activity.activityState == .pending, activity.contentState.targetDate != state.targetDate {
                do { try await start(projection, privacy: privacy, scheduled: card.reminders.scheduledLiveActivity, now: now) }
                catch { failures.append(error.localizedDescription) }
            } else if activity.contentState != state { await update(activity, state: state, now: now) }
        }
        return failures
    }

    func activateSavedCard(_ card: Card, library: LibrarySnapshot, privacy: ContentPrivacy, now: Date) async throws {
        guard card.reminders.enablesLiveActivity, card.lifecycle == .active, card.recurrenceClosedAt == nil,
              !card.reminders.isEnabled || card.reminders.channel != .alarm else { return }
        let engine = OccurrenceEngine(calendar: .current)
        let occurrence = card.isRepeating && Self.hasClockTime(card) ? engine.next(for: card, after: now, overrides: library.overrides) : engine.relevantOccurrence(for: card, at: now, overrides: library.overrides)
        guard let occurrence else { return }
        let projection = CardProjection(card: card, occurrence: occurrence, events: library.events(for: occurrence.id), reminderState: library.personalStates[occurrence.id])
        guard eligibilityIssue(projection, now: now) == nil else { return }
        try await start(projection, privacy: privacy, scheduled: card.reminders.scheduledLiveActivity, now: now)
    }
}
