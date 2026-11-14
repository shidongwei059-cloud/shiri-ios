import Foundation
import UserNotifications
import WidgetKit
import Speech
import ActivityKit
import CoreLocation
import ShiriCore

enum SystemActionHandler {
    static func handle(_ response: UNNotificationResponse) async throws {
        guard let payload = NotificationAdapter.payload(response.notification.request.content.userInfo) else { return }
        let repo = try await ExtensionStore.open(author: "NotificationAction")
        try await handle(action: response.actionIdentifier, payload: payload, deliveredAt: response.notification.date, repository: repo, now: Date())
    }
    static func handle(action: String, payload: NotificationPayload, deliveredAt: Date, repository repo: ShiriRepository, now: Date) async throws {
        let library = try await repo.library()
        let occurrence = try payload.resolve(in: library, deliveredAt: deliveredAt, calendar: .current)
        let commands = CardCommands(repository: repo)
        switch action {
        case "COMPLETE": try await commands.complete(occurrence, now: now)
        case "SNOOZE": try await commands.snooze(occurrence, until: now.addingTimeInterval(600), now: now)
        case "STOP": try await commands.stopReminder(occurrence, now: now)
        default: return
        }
        try await reconcile(repository: repo, now: now)
    }
    static func reconcile(repository: ShiriRepository, now: Date) async throws {
        let library = try await repository.library(); let prefs = try await repository.deviceValue(AppPreferences.self, key: "preferences") ?? AppPreferences()
        let desired = ReminderPlanner(calendar: .current).plan(library: library, preferences: prefs, now: now, capabilities: await CapabilityProvider.reminderCapabilities())
        var firstError: Error?
        do { _ = try await NotificationAdapter.shared.reconcile(desired, library: library, repository: repository, now: now) }
        catch { firstError = error }
        if #available(iOS 26.0, *) {
            do { _ = try await AlarmAdapter.reconcile(desired, repository: repository, now: now) }
            catch { if firstError == nil { firstError = error } }
        }
        await LiveActivityService().reconcile(library: library, privacy: prefs.notificationPrivacy, now: now)
        do { try WidgetSnapshot.make(library: library, preferences: prefs, now: now, calendar: .current).write(at: repository.persistence.configuration.directory) }
        catch { if firstError == nil { firstError = error } }

        WidgetCenter.shared.reloadAllTimelines()
        if let firstError { throw firstError }
    }
}


enum CapabilityReadiness: String, Sendable {
    case unavailable, needsPermission, denied, needsResources, ready
    var isSupported: Bool { self != .unavailable }
    var title: String {
        switch self {
        case .unavailable: return "此设备暂不可用"
        case .needsPermission: return "尚未开启"
        case .denied: return "尚未允许"
        case .needsResources: return "需要下载语音支持"
        case .ready: return "可用"
        }
    }
}
struct DeviceCapabilitySnapshot: Equatable, Sendable {
    var notifications: CapabilityReadiness = .needsPermission
    var alarms: CapabilityReadiness = .unavailable
    var liveActivities: CapabilityReadiness = .unavailable
    var location: CapabilityReadiness = .needsPermission
    var localSpeech: CapabilityReadiness = .needsResources
    var enhancedSpeech: CapabilityReadiness = .unavailable
    var reminders: ReminderCapabilities { ReminderCapabilities(notificationsAllowed: notifications == .ready, alarmAllowed: alarms == .ready) }
}
enum CapabilityProvider {
    static var alarms: CapabilityReadiness {
        guard #available(iOS 26.0, *) else { return .unavailable }
        return AlarmAdapter.allowed ? .ready : AlarmAdapter.needsPermission ? .needsPermission : .denied
    }
    static var liveActivities: CapabilityReadiness {
        guard #available(iOS 16.1, *) else { return .unavailable }
        return ActivityAuthorizationInfo().areActivitiesEnabled ? .ready : .denied
    }
    static func enhancedSpeech() async -> CapabilityReadiness {
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else { return .unavailable }
        let status = await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .progressiveTranscription)])
        switch status { case .installed: return .ready; case .supported, .downloading: return .needsResources; default: return .unavailable }
    }
    static func reminderCapabilities() async -> ReminderCapabilities {
        ReminderCapabilities(notificationsAllowed: await NotificationAdapter.shared.allowed(), alarmAllowed: alarms == .ready)
    }
    static func read(locationAuthorization: CLAuthorizationStatus) async -> DeviceCapabilitySnapshot {
        let notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let notification: CapabilityReadiness = [.authorized, .provisional].contains(notificationStatus) ? .ready : notificationStatus == .notDetermined ? .needsPermission : .denied
        let speechAuthorization = SFSpeechRecognizer.authorizationStatus()
        let legacy: CapabilityReadiness
        if speechAuthorization == .denied || speechAuthorization == .restricted { legacy = .denied }
        else if speechAuthorization == .notDetermined { legacy = .needsPermission }
        else if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition { legacy = .ready }
        else { legacy = .needsResources }
        return DeviceCapabilitySnapshot(notifications: notification, alarms: alarms, liveActivities: liveActivities,
                                        location: locationAuthorization == .authorizedAlways ? .ready : [.authorizedWhenInUse, .notDetermined].contains(locationAuthorization) ? .needsPermission : .denied,
                                        localSpeech: legacy, enhancedSpeech: .unavailable)
    }
}
