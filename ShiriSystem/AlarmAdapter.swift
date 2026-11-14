import AlarmKit
import AppIntents
import SwiftUI
import ShiriCore

@available(iOS 26.0, *)
struct ShiriAlarmMetadata: AlarmMetadata { var requestID: String; var cardID: String }

@available(iOS 26.0, *)
struct StopShiriAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止本次闹钟"
    static var isDiscoverable = false
    @Parameter(title: "提醒编号") var requestID: String
    init() {}
    init(requestID: String) { self.requestID = requestID }
    func perform() async throws -> some IntentResult {
        let repo = try await ExtensionStore.open(author: "AlarmStop")
        let ledger = try await repo.deviceValue([ReminderLedgerEntry].self, key: "alarm-ledger") ?? []
        if let request = ledger.first(where: { $0.id == requestID })?.request {
            let library = try await repo.library()
            if let occurrence = try? request.payload.resolve(in: library, deliveredAt: request.firesAt, calendar: .current) { try await CardCommands(repository: repo).stopReminder(occurrence, now: Date(), alarmOnly: true) }
        }
        try? AlarmManager.shared.stop(id: StableID.uuid(requestID))
        try await SystemActionHandler.reconcile(repository: repo, now: Date())
        return .result()
    }
}
@available(iOS 26.0, *)
struct SnoozeShiriAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "闹钟稍后十分钟"
    static var isDiscoverable = false
    @Parameter(title: "提醒编号") var requestID: String
    init() {}
    init(requestID: String) { self.requestID = requestID }
    func perform() async throws -> some IntentResult {
        let repo = try await ExtensionStore.open(author: "AlarmSnooze")
        let ledger = try await repo.deviceValue([ReminderLedgerEntry].self, key: "alarm-ledger") ?? []
        guard let request = ledger.first(where: { $0.id == requestID })?.request else { throw ShiriError.notFound }
        let library = try await repo.library()
        let occurrence = try request.payload.resolve(in: library, deliveredAt: request.firesAt, calendar: .current)
        try await CardCommands(repository: repo).snooze(occurrence, until: Date().addingTimeInterval(600), now: Date())
        try? AlarmManager.shared.stop(id: StableID.uuid(requestID))
        var next = request; next.id = "ny.reminder." + StableID.hash("\(occurrence.id)|snooze|alarm"); next.firesAt = Date().addingTimeInterval(600)
        _ = try await AlarmAdapter.schedule(next)
        var updated = ledger.filter { $0.id != next.id }; updated.append(ReminderLedgerEntry(request: next, status: .registered, now: Date()))
        try await repo.setDeviceValue(updated, key: "alarm-ledger")
        try await SystemActionHandler.reconcile(repository: repo, now: Date())
        return .result()
    }
}
@available(iOS 26.0, *)
enum AlarmAdapter {
    static var allowed: Bool { AlarmManager.shared.authorizationState == .authorized }
    static var needsPermission: Bool { AlarmManager.shared.authorizationState == .notDetermined }
    static func requestPermission() async throws { _ = try await AlarmManager.shared.requestAuthorization() }
    static func clearCloud(cardIDs: Set<UUID>, repository: ShiriRepository) async {
        let entries = (try? await repository.deviceValue([ReminderLedgerEntry].self, key: "alarm-ledger")) ?? []
        for entry in entries where cardIDs.contains(entry.request.cardID) { try? AlarmManager.shared.cancel(id: StableID.uuid(entry.id)) }
        try? await repository.setDeviceValue(entries.filter { !cardIDs.contains($0.request.cardID) }, key: "alarm-ledger")
    }
    static func alert(for request: PlannedReminder) -> AlarmPresentation.Alert {
        let stop = AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
        // User-authored titles are values, not localization lookup keys.
        let title: LocalizedStringResource = "\(request.title)"
        if #available(iOS 26.1, *) { return AlarmPresentation.Alert(title: title) }
        return AlarmPresentation.Alert(title: title, stopButton: stop)
    }
    static func schedule(_ request: PlannedReminder) async throws -> Alarm {
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert(for: request)), metadata: ShiriAlarmMetadata(requestID: request.id, cardID: request.cardID.uuidString), tintColor: Color(red: 0.74, green: 0.38, blue: 0.29))
        // Completion, snooze and rescheduling use the actionable completion notification.
        let configuration = AlarmManager.AlarmConfiguration.alarm(schedule: .fixed(request.firesAt), attributes: attributes)
        return try await AlarmManager.shared.schedule(id: StableID.uuid(request.id), configuration: configuration)
    }
    static func reconcile(_ desired: DesiredSchedule, repository: ShiriRepository, now: Date) async throws -> [ReminderLedgerEntry] {
        let requests = desired.requests.filter { $0.channel == .alarm }
        let previous = try await repository.deviceValue([ReminderLedgerEntry].self, key: "alarm-ledger") ?? []
        guard allowed else {
            let blocked = previous.map { ReminderLedgerEntry(request: $0.request, status: .failed, message: "系统闹钟未开启，请在设置中允许后重试", now: now) }
            try await repository.setDeviceValue(blocked, key: "alarm-ledger"); return blocked
        }
        let alarms = try AlarmManager.shared.alarms
        let actual = Set(alarms.map(\.id))
        let presentationChanged = try await repository.deviceValue(Int.self, key: "alarm-presentation-version") != 2
        let ids = Set(requests.map(\.id))
        var result: [ReminderLedgerEntry] = []
        let library = try await repository.library()
        let ringingIDs = Set(alarms.filter { $0.state == .alerting }.map(\.id))
        for entry in previous where ringingIDs.contains(StableID.uuid(entry.id)) && !ids.contains(entry.id) {
            guard let card = library.cards.first(where: { $0.id == entry.request.cardID }), card.reminders.isEnabled, card.reminders.channel == .alarm, card.recurrenceClosedAt == nil,
                  let occurrence = try? entry.request.payload.resolve(in: library, deliveredAt: entry.request.firesAt, calendar: .current),
                  EventReducer.state(events: library.events(for: occurrence.id)) == .pending,
                  library.personalStates[occurrence.id]?.isStopped != true,
                  (library.personalStates[occurrence.id]?.snoozedUntil ?? .distantPast) <= now else { continue }
            result.append(ReminderLedgerEntry(request: entry.request, status: .registered, now: now))
        }
        let retained = Set(result.map(\.id))
        for stale in previous where !ids.contains(stale.id) && !retained.contains(stale.id) && actual.contains(StableID.uuid(stale.id)) {
            do { try AlarmManager.shared.cancel(id: StableID.uuid(stale.id)) }
            catch { result.append(ReminderLedgerEntry(request: stale.request, status: .failed, message: "取消未完成：\(error.localizedDescription)", now: now)) }
        }
        for request in requests {
            do {
                let old = previous.first { $0.id == request.id }
                if presentationChanged || old?.request != request || !actual.contains(StableID.uuid(request.id)) { _ = try await schedule(request) }
                let fresh = try await repository.library()
                guard let card = fresh.cards.first(where: { $0.id == request.cardID }), card.lifecycle == .active,
                      card.recurrenceClosedAt == nil, card.reminders.isEnabled, card.reminders.channel == .alarm,
                      let occurrence = try? request.payload.resolve(in: fresh, deliveredAt: request.firesAt, calendar: .current),
                      EventReducer.state(events: fresh.events(for: occurrence.id)) == .pending,
                      fresh.personalStates[occurrence.id]?.isStopped != true else {
                    try AlarmManager.shared.cancel(id: StableID.uuid(request.id)); continue
                }
                result.append(ReminderLedgerEntry(request: request, status: .registered, now: now))
            } catch { result.append(ReminderLedgerEntry(request: request, status: .failed, message: error.localizedDescription, now: now)) }
        }
        try await repository.setDeviceValue(result, key: "alarm-ledger")
        try await repository.setDeviceValue(2, key: "alarm-presentation-version")
        return result
    }
}
