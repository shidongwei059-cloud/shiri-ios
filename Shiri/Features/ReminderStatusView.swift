import SwiftUI
import UserNotifications
import ShiriCore

struct CardReminderStatus: Equatable {
    var text: String
    var needsAttention = false
}

extension AppModel {
    func reminderStatus(for projection: CardProjection) -> CardReminderStatus {
        let card = projection.card
        guard card.lifecycle == .active, card.recurrenceClosedAt == nil else { return .init(text: "提醒已停止") }
        guard projection.state == .pending else { return .init(text: "这一次已处理") }
        guard card.reminders.isEnabled else { return .init(text: "未开启提醒") }
        if projection.reminderState?.isStopped == true { return .init(text: "此设备已暂停") }
        let readiness = card.place != nil ? systemCapabilities.location : card.reminders.channel == .alarm ? systemCapabilities.alarms : systemCapabilities.notifications
        guard readiness == .ready else { return .init(text: readiness == .unavailable ? "此设备不支持此提醒" : "提醒未开启 · " + readiness.title, needsAttention: true) }
        if card.place != nil && systemCapabilities.notifications != .ready { return .init(text: "地点已设置 · 还需允许通知", needsAttention: true) }
        if let issue = reminderIssues.first(where: { $0.cardID == card.id }) { return .init(text: issue.message, needsAttention: true) }
        if card.place != nil { return .init(text: geofences.registrationStatus(cardID: card.id)) }
        let entries = reminderLedger.filter { $0.request.cardID == card.id && ($0.request.firesAt > now || $0.request.calendarMatch != nil) }
        if let failed = entries.first(where: { $0.status != .registered }) { return .init(text: failed.message ?? "等待重新核对提醒", needsAttention: true) }
        if let next = entries.filter({ $0.status == .registered }).min(by: { $0.request.firesAt < $1.request.firesAt }) {
            return .init(text: "已安排 · " + CardPresentation.dateLabel(next.request.firesAt, format: "M月d日 HH:mm"))
        }
        return .init(text: "暂无待提醒安排 · 查看原因", needsAttention: true)
    }

    func requestReminderPermission(for card: Card) async {
        if card.place != nil {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            geofences.requestBackgroundPermission()
        }
        else if card.reminders.channel == .notification {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } else if #available(iOS 26.0, *) { try? await AlarmAdapter.requestPermission() }
        await reconcileReminders()
    }

    func showLiveActivityNow(cardID: UUID) async throws {
        guard let repository, let commands else { throw ShiriError.unavailable("正在读取卡片，请稍后再试") }
        let current = try await repository.library()
        guard var card = current.cards.first(where: { $0.id == cardID }) else { throw ShiriError.notFound }
        let engine = OccurrenceEngine(calendar: calendar)
        let occurrence = card.isRepeating && LiveActivityService.hasClockTime(card)
            ? engine.next(for: card, after: now, overrides: current.overrides)
            : engine.relevantOccurrence(for: card, at: now, overrides: current.overrides)
        let projection = CardProjection(card: card, occurrence: occurrence, events: occurrence.map { current.events(for: $0.id) } ?? [], reminderState: occurrence.flatMap { current.personalStates[$0.id] })
        if let reason = liveActivities.eligibilityIssue(projection, now: now) { throw ShiriError.validation(reason) }
        // An explicit "show now" also repairs older cards whose display option was never enabled.
        // Keep the notification channel, schedule, content and personal stop state intact.
        if !card.reminders.enablesLiveActivity || card.reminders.scheduledLiveActivity {
            card.reminders.enablesLiveActivity = true; card.reminders.scheduledLiveActivity = false
            card = try await commands.save(CardDraft(card: card, isEditing: true), now: now)
        }
        await refresh()
        try await liveActivities.activateSavedCard(card, library: try await repository.library(), privacy: preferences.notificationPrivacy, now: now)
    }
}

struct ReminderStatusView: View {
    let cardID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var activityStatus = ""
    @State private var error: String?
    private var projection: CardProjection? { model.detailProjection(cardID: cardID, occurrence: nil) }
    var body: some View {
        NavigationStack {
            List {
                if let p = projection {
                    Section("这张卡片在此设备上的提醒") {
                        Text(model.reminderStatus(for: p).text).accessibilityIdentifier("actualReminderStatus")
                        if p.card.reminders.isEnabled {
                            Button("检查并允许提醒") { Task { busy = true; await model.requestReminderPermission(for: p.card); busy = false } }.disabled(busy)
                            Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                        }
                        Text("保存卡片后，请确认提醒已开启。静音和专注模式可能影响通知。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                    Section("锁屏与灵动岛") {
                        Text(activityStatus.isEmpty ? "正在检查…" : activityStatus).accessibilityIdentifier("actualLiveActivityStatus")
                        if model.liveActivities.eligibilityIssue(p, now: model.now) == nil {
                            Button(p.card.reminders.enablesLiveActivity ? "立即显示" : "开启并立即显示") {
                                Task {
                                    busy = true; error = nil
                                    defer { busy = false; if let current = projection { readActivity(current) } }
                                    do { try await model.showLiveActivityNow(cardID: cardID) }
                                    catch { self.error = error.localizedDescription }
                                }
                            }.disabled(busy).accessibilityIdentifier("showLiveActivityNow")
                        }
                        Button("打开拾日系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.accessibilityIdentifier("liveActivitySystemSettings")
                        Button("重新检查状态") { Task { busy = true; await model.reconcileReminders(); if let current = projection { readActivity(current) }; busy = false } }.disabled(busy)
                    }
                    Section("锁屏没有看到卡片？") {
                        Text("点亮屏幕后，在锁屏上查看。首次出现“允许拾日的实时活动”提示时，请选择允许。").font(.footnote)
                        Text("请在系统设置中允许拾日使用“实时活动”。若锁屏仍不显示，请检查“面容 ID 与密码”或“触控 ID 与密码”中的“锁定时允许访问”。").font(.footnote)
                        Text("支持灵动岛的设备也可在解锁后查看。卡片停止显示时，可以回到这里重新开启；较远的安排可选择提前 30 分钟显示。").font(.footnote)
                    }
                    if let error { Section { Text(error).foregroundColor(Paper.accent) } }
                }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("此设备的提醒")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await model.reconcileReminders(); if let p = projection { readActivity(p) } }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await model.reconcileReminders(); if let p = projection { readActivity(p) } } }
                }
        }
    }
    private func readActivity(_ p: CardProjection) { activityStatus = model.liveActivities.status(for: p, now: model.now) }
}
