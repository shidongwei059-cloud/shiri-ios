import AppIntents
import WidgetKit
import ShiriCore
import Foundation
import Combine

enum ComposerInputMode: Equatable {
    case text, voice
    static let voiceURL = URL(string: "nianyi://compose?input=voice")!

    static func from(_ url: URL) -> Self? {
        guard url.scheme == "nianyi", url.host == "compose" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "input" && $0.value == "voice" }) == true ? .voice : .text
    }
}

/// Foreground intents run in the app process. Retain a cold-launch request until the root subscribes.
@MainActor
final class ComposerIntentRouter: ObservableObject {
    struct Request: Identifiable { let id = UUID(); let mode: ComposerInputMode }
    static let shared = ComposerIntentRouter()
    @Published private(set) var request: Request?
    func open(_ mode: ComposerInputMode) { request = Request(mode: mode) }
    func consume(_ id: UUID) { if request?.id == id { request = nil } }
}

@available(iOS 17.0, *)
struct CompleteCardIntent: AppIntent {
    static var title: LocalizedStringResource = "完成这一次事项"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var isDiscoverable = false
    @Parameter(title: "卡片编号") var cardID: String
    @Parameter(title: "本次安排") var occurrenceID: String
    init() {}
    init(cardID: UUID, occurrenceID: String) { self.cardID = cardID.uuidString; self.occurrenceID = occurrenceID }
    func perform() async throws -> some IntentResult {
        let repo = try await ExtensionStore.open(author: "WidgetComplete")
        guard let id = UUID(uuidString: cardID) else { throw ShiriError.notFound }
        let now = Date(); let calendar = Calendar.current
        try await CardCommands(repository: repo).complete(cardID: id, occurrenceID: occurrenceID, now: now, calendar: calendar)
        try await SystemActionHandler.reconcile(repository: repo, now: now)
        return .result()
    }
}

struct OpenComposerIntent: AppIntent {
    static var title: LocalizedStringResource = "记一件事"
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    func perform() async throws -> some IntentResult {
        await ComposerIntentRouter.shared.open(.text)
        return .result()
    }
}

struct OpenVoiceComposerIntent: AppIntent {
    static var title: LocalizedStringResource = "语音新建待办"
    static var description = IntentDescription("打开拾日的语音输入，核对文字和时间后创建待办。")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    func perform() async throws -> some IntentResult {
        await ComposerIntentRouter.shared.open(.voice)
        return .result()
    }
}
struct ShiriShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenComposerIntent(), phrases: ["用\(.applicationName)记一件事"], shortTitle: "记一件事", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenVoiceComposerIntent(), phrases: ["用\(.applicationName)语音记待办"], shortTitle: "语音新建待办", systemImageName: "mic")
    }
}
