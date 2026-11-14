import ActivityKit
import AppIntents
import AVFoundation
import Foundation
import ShiriCore
import WidgetKit

@available(iOS 18.0, *)
struct VoiceCaptureAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case recording, processing, review, needsReview, saved, failed }
        var phase: Phase
        var title: String
        var detail: String
        var hidesContent: Bool
    }
    var draftID: UUID
    var startedAt: Date
}

enum VoiceCapturePersistence {
    /// Retrying a system action must never create a second card.
    static func confirm(id: UUID, repository: ShiriRepository, now: Date) async throws -> Card {
        if let saved = try await repository.library(cardID: id).cards.first { return saved }
        guard let draft = try await repository.drafts().first(where: { $0.id == id }), VoiceCaptureDraft.canConfirm(draft) else {
            throw ShiriError.validation("这段语音需要核对，文字已保留在草稿箱")
        }
        if draft.card.reminders.isEnabled, let rule = draft.card.schedule, rule.frequency == .never,
           let planned = OccurrenceEngine(calendar: rule.calendar(fallback: .current)).date(rule.start, time: rule.time ?? DayTime(hour: 0)), planned <= now {
            throw ShiriError.validation("提醒时间已过去，请在草稿中调整后保存")
        }
        return try await CardCommands(repository: repository).save(draft, now: now)
    }
}

/// AudioRecordingIntent guarantees execution in the app process, retaining the engine between widget taps.
@available(iOS 18.0, *)
@MainActor
final class WidgetVoiceCapture {
    static let shared = WidgetVoiceCapture()
    private let speech = LocalSpeechService()
    private var activity: Activity<VoiceCaptureAttributes>?
    private var repository: ShiriRepository?
    private var monitor: Task<Void, Never>?
    private var activityMonitor: Task<Void, Never>?
    private var isStarting = false
    private var isFinishing = false
    private var savingDrafts: Set<UUID> = []
    private var preferences = AppPreferences()

    func start() async throws {
        guard !isStarting, !isFinishing, activity == nil else { return }
        isStarting = true; defer { isStarting = false }
        // Never prompt for permissions invisibly from a widget.
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw ShiriError.unavailable("请先在拾日使用一次语音输入并允许麦克风，然后即可从组件录音")
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ShiriError.unavailable("请在系统设置中允许拾日的实时活动，录音时需要显示停止按钮")
        }
        // A previous process may have ended while its draft and confirmation surface survived.
        for existing in Activity<VoiceCaptureAttributes>.activities {
            if existing.content.state.phase == .review || existing.content.state.phase == .needsReview { return }
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        let repo = try await ExtensionStore.open(author: "WidgetVoiceCapture")
        preferences = try await repo.deviceValue(AppPreferences.self, key: "preferences") ?? AppPreferences()
        let attributes = VoiceCaptureAttributes(draftID: UUID(), startedAt: Date())
        let state = VoiceCaptureAttributes.ContentState(phase: .recording, title: "正在准备录音…", detail: "轻点停止后，核对并保存", hidesContent: preferences.widgetPrivacy == .hidden || preferences.notificationPrivacy == .hidden)
        let active = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(65)), pushType: nil)
        activity = active; repository = repo
        activityMonitor = Task { [weak self] in
            for await state in active.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    guard let self, self.activity?.id == active.id else { return }
                    await self.finish(); return
                }
            }
        }
        await speech.start(requestPermissions: false)
        guard activity?.id == active.id else { speech.stop(); return }
        guard speech.isRecording else {
            await update(active, phase: .failed, title: "未能开始录音", detail: speech.error ?? "请先在拾日准备中文语音输入")
            releaseSession(); return
        }
        await update(active, phase: .recording, title: "正在听…", detail: "最多录音 60 秒，轻点停止后核对")
        monitor = Task { [weak self] in
            var lastText = ""
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.activity?.id == active.id, !self.isFinishing else { return }
                let text = self.speech.transcript
                if text != lastText && !text.isEmpty {
                    do {
                        var raw = CardDraft(card: Card(title: "语音记录", now: attributes.startedAt), originalText: text)
                        raw.id = attributes.draftID; raw.card.id = attributes.draftID
                        try await repo.saveDraft(raw)
                        lastText = text
                        await self.update(active, phase: .recording, title: text, detail: "轻点停止后，核对并保存")
                    } catch {
                        self.speech.error = "文字暂未保存，请停止后重试：" + error.localizedDescription
                        await self.finish(); return
                    }
                }
                if !self.speech.isRecording || Date().timeIntervalSince(attributes.startedAt) >= 60 {
                    await self.finish(); return
                }
            }
        }
    }

    func finish() async {
        guard !isFinishing else { return }
        guard let active = activity, let repo = repository else {
            for existing in Activity<VoiceCaptureAttributes>.activities where [.recording, .processing].contains(existing.content.state.phase) {
                await update(existing, phase: .needsReview, title: "录音已中断", detail: "已识别的文字保留在草稿箱，请打开核对")
            }
            return
        }
        isFinishing = true; monitor?.cancel(); monitor = nil
        defer { isFinishing = false; releaseSession() }
        await update(active, phase: .processing, title: "正在整理文字…", detail: "录音已停止")
        await speech.finish()
        do {
            var draft = try VoiceCaptureDraft.prepare(speech.transcript, id: active.attributes.draftID, startedAt: active.attributes.startedAt, calendar: .current, defaultTime: preferences.defaultReminderTime)
            if speech.error != nil && !draft.questions.contains(.interpretation) { draft.questions.append(.interpretation) }
            try await repo.saveDraft(draft)
            let ready = VoiceCaptureDraft.canConfirm(draft)
            await update(active, phase: ready ? .review : .needsReview, title: draft.card.title,
                         detail: ready ? Self.summary(draft.card) : "文字已存草稿，请打开拾日核对时间或多件事项")
        } catch {
            if !speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var raw = CardDraft(card: Card(title: "语音记录", now: active.attributes.startedAt), originalText: speech.transcript)
                raw.id = active.attributes.draftID; raw.card.id = raw.id
                do {
                    try await repo.saveDraft(raw)
                    await update(active, phase: .needsReview, title: "文字已保留", detail: "请在草稿中核对这段语音")
                } catch { await update(active, phase: .failed, title: "文字暂未保存", detail: error.localizedDescription) }
            } else { await update(active, phase: .failed, title: "没有听清内容", detail: "请重新录音") }
        }
    }

    func save(id: UUID) async throws {
        guard savingDrafts.insert(id).inserted else { return }
        defer { savingDrafts.remove(id) }
        guard let active = Activity<VoiceCaptureAttributes>.activities.first(where: { $0.attributes.draftID == id }) else { return }
        guard active.content.state.phase == .review else { return }
        let repo = try await ExtensionStore.open(author: "WidgetVoiceSave")
        do {
            let card = try await VoiceCapturePersistence.confirm(id: id, repository: repo, now: Date())
            var message = "已保存到卡片"
            do { try await SystemActionHandler.reconcile(repository: repo, now: Date()) }
            catch { message = "卡片已保存，提醒状态请在拾日查看" }
            if card.reminders.isEnabled, !(await NotificationAdapter.shared.allowed()) { message = "卡片已保存；请允许通知后接收提醒" }
            let state = VoiceCaptureAttributes.ContentState(phase: .saved, title: active.content.state.hidesContent ? "已保存" : card.title, detail: message, hidesContent: active.content.state.hidesContent)
            await active.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(20)))
        } catch {
            await update(active, phase: .needsReview, title: "草稿已保留", detail: error.localizedDescription)
        }
    }

    func dismiss(id: UUID) async {
        if activity?.attributes.draftID == id { await finish() }
        for active in Activity<VoiceCaptureAttributes>.activities where active.attributes.draftID == id {
            await active.end(nil, dismissalPolicy: .immediate)
        }
        // Dismissing the surface keeps the user's transcript recoverable in drafts.
    }

    private func update(_ active: Activity<VoiceCaptureAttributes>, phase: VoiceCaptureAttributes.ContentState.Phase, title: String, detail: String) async {
        let hidden = active.content.state.hidesContent
        let displayedTitle = hidden && [.recording, .review, .needsReview].contains(phase) ? (phase == .recording ? "正在录音…" : "语音已转写") : String(title.prefix(120))
        let displayedDetail = hidden && phase == .review ? "内容已隐藏，可保存或稍后在草稿中核对" : String(detail.prefix(160))
        await active.update(ActivityContent(state: .init(phase: phase, title: displayedTitle, detail: displayedDetail, hidesContent: hidden), staleDate: phase == .recording ? active.attributes.startedAt.addingTimeInterval(65) : nil))
    }
    private func releaseSession() {
        speech.stop(); monitor?.cancel(); monitor = nil
        activityMonitor?.cancel(); activityMonitor = nil
        activity = nil; repository = nil
    }
    private static func summary(_ card: Card) -> String {
        guard let rule = card.schedule else { return "不设日期 · 确认后保存" }
        return rule.start.key + " " + (rule.time?.display ?? "全天") + " · " + rule.frequency.title + (card.reminders.isEnabled ? " · 提醒已选择" : " · 不提醒")
    }
}

@available(iOS 18.0, *)
struct StartWidgetVoiceIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "在组件录音"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { try await WidgetVoiceCapture.shared.start(); return .result() }
}
@available(iOS 18.0, *)
struct StopWidgetVoiceIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "停止并核对语音"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { await WidgetVoiceCapture.shared.finish(); return .result() }
}
@available(iOS 18.0, *)
struct SaveWidgetVoiceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "保存语音卡片"
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var isDiscoverable = false
    @Parameter(title: "草稿编号") var draftID: String
    init() {}
    init(id: UUID) { draftID = id.uuidString }
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: draftID) else { return .result() }
        try await WidgetVoiceCapture.shared.save(id: id); return .result()
    }
}
@available(iOS 18.0, *)
struct DismissWidgetVoiceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "收起并保留草稿"
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "草稿编号") var draftID: String
    init() {}
    init(id: UUID) { draftID = id.uuidString }
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) { await WidgetVoiceCapture.shared.dismiss(id: id) }
        return .result()
    }
}
