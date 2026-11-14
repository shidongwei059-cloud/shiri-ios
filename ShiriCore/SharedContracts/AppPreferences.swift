import Foundation

public enum ContentPrivacy: String, Codable, CaseIterable, Sendable {
    case full, titleOnly, hidden
    public var title: String { switch self { case .full: return "显示标题与内容"; case .titleOnly: return "仅显示标题"; case .hidden: return "隐藏具体内容" } }
}
public enum AppColorScheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    public var title: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
}
public struct AppPreferences: Codable, Equatable, Sendable {
    public var notificationPrivacy: ContentPrivacy = .titleOnly
    public var widgetPrivacy: ContentPrivacy = .titleOnly
    public var hidesAppWhenInactive = true
    public var colorScheme: AppColorScheme = .system
    public var defaultReminderTime: DayTime?
    public var remindsForPrivateCloudCards = false
    public var cloudEnabled = false
    public var defaultScope: DataScope = .local
    public var enabledCloudCardIDs: Set<UUID> = []
    public var showReviewReminder = false
    public var excludesSystemBackup: Bool?
    public var showsReviewComparison: Bool?
    public var showsMemoryReunion: Bool?
    /// Missing in older preferences; one completion check five minutes after the due reminder.
    public var completionConfirmationDelay: Int?
    public var completionConfirmationMinutes: Int {
        guard let value = completionConfirmationDelay, [0, 5, 10].contains(value) else { return 5 }
        return value
    }
    public init() {}
}
