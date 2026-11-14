#if canImport(UserNotifications)
import Foundation
import UserNotifications

public actor NotificationAdapter {
    public static let shared = NotificationAdapter()
    private let center = UNUserNotificationCenter.current()
    public static let category = "NIANYI_OCCURRENCE"
    public static func registerActions() {
        let actions = [UNNotificationAction(identifier: "COMPLETE", title: "已完成", options: [.authenticationRequired]), UNNotificationAction(identifier: "SNOOZE", title: "10 分钟后提醒", options: []), UNNotificationAction(identifier: "RESCHEDULE", title: "更改时间", options: [.foreground, .authenticationRequired]), UNNotificationAction(identifier: "STOP", title: "停止本次提醒", options: [])]
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [])])
    }
    public func allowed() async -> Bool {
        let settings = await center.notificationSettings()
        return [.authorized, .provisional].contains(settings.authorizationStatus)
    }
    public func reconcileReviewReminder(enabled: Bool) async throws {
        let id = "ny.review.weekly"
        guard enabled, await allowed() else {
            center.removePendingNotificationRequests(withIdentifiers: [id]); center.removeDeliveredNotifications(withIdentifiers: [id]); return
        }
        if await center.pendingNotificationRequests().contains(where: { $0.identifier == id }) { return }
        let content = UNMutableNotificationContent(); content.title = "留一点时间，回看这一周"; content.body = "打开拾日，看看自己记下的小进展。"; content.userInfo = ["nianyiRoute":"review"]
        var date = DateComponents(); date.weekday = 1; date.hour = 20; date.minute = 0
        try await center.add(UNNotificationRequest(identifier: id,content: content,trigger: UNCalendarNotificationTrigger(dateMatching: date,repeats: true)))
    }
    public func reconcile(_ desired: DesiredSchedule, library: LibrarySnapshot, repository: ShiriRepository, now: Date) async throws -> [ReminderLedgerEntry] {
        let requests = desired.requests.filter { $0.channel == .notification }
        let pending = await center.pendingNotificationRequests()
        let oldLedger = try await repository.deviceValue([ReminderLedgerEntry].self, key: "notification-ledger") ?? []
        let old = Dictionary(oldLedger.map { ($0.id, $0) }, uniquingKeysWith: { _,b in b })
        let desiredIDs = Set(requests.map(\.id)); let currentIDs = Set(pending.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("ny.reminder.") && !desiredIDs.contains($0.identifier) }.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        let endedIDs = delivered.filter { notification in
            guard let payload = Self.payload(notification.request.content.userInfo) else { return false }
            guard let occurrence = try? payload.resolve(in: library, deliveredAt: notification.date, calendar: .current) else { return true }
            let state = library.personalStates[occurrence.id]
            return EventReducer.state(events: library.events(for: occurrence.id)) != .pending || state?.isStopped == true
                || (state?.snoozedUntil ?? .distantPast) > now
        }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: endedIDs)
        var ledger: [ReminderLedgerEntry] = []
        for request in requests {
            if currentIDs.contains(request.id), old[request.id]?.request == request, old[request.id]?.status == .registered { ledger.append(ReminderLedgerEntry(request: request, status: .registered, now: now)); continue }
            do {
                let content = UNMutableNotificationContent(); content.title = request.title; content.body = request.body; content.sound = .default; content.categoryIdentifier = Self.category
                content.threadIdentifier = request.cardID.uuidString
                content.userInfo = ["nianyiPayload": try ValueCodec.encode(request.payload)]
                if request.isCompletionConfirmation == true { content.subtitle = "这件事完成了吗？"; content.userInfo["nianyiCompletionConfirmation"] = true }
                let trigger: UNNotificationTrigger
                if let match = request.calendarMatch { trigger = UNCalendarNotificationTrigger(dateMatching: match.components, repeats: true) }
                else {
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                    var components = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: request.firesAt); components.timeZone = calendar.timeZone
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                }
                try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
                ledger.append(ReminderLedgerEntry(request: request, status: .registered, now: now))
            } catch { ledger.append(ReminderLedgerEntry(request: request, status: .failed, message: error.localizedDescription, now: now)) }
        }
        // A widget or another process may have completed or changed an occurrence while add() was awaiting the system.
        let fresh = try await repository.library()
        let obsolete = ledger.filter { entry in
            guard let occurrence = try? entry.request.payload.resolve(in: fresh, deliveredAt: entry.request.firesAt, calendar: .current) else { return true }
            return EventReducer.state(events: fresh.events(for: occurrence.id)) != .pending || fresh.personalStates[occurrence.id]?.isStopped == true
        }.map(\.id)
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        ledger.removeAll { obsolete.contains($0.id) }
        let actual = Set(await center.pendingNotificationRequests().map(\.identifier))
        for index in ledger.indices where !actual.contains(ledger[index].id) { ledger[index].status = .pendingVerification; ledger[index].message = "提醒仍在设置中，重新打开拾日后会再次尝试" }
        try await repository.setDeviceValue(ledger, key: "notification-ledger")
        return ledger
    }
    public static func payload(_ info: [AnyHashable: Any]) -> NotificationPayload? {
        guard let data = info["nianyiPayload"] as? Data else { return nil }; return try? ValueCodec.decode(NotificationPayload.self, data)
    }
    public func clearCloud(cardIDs: Set<UUID>) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { Self.payload($0.content.userInfo).map { cardIDs.contains($0.cardID) } ?? false }.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { Self.payload($0.request.content.userInfo).map { cardIDs.contains($0.cardID) } ?? false }.map { $0.request.identifier })
    }
}
#endif
