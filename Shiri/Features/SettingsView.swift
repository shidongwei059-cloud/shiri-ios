import SwiftUI
import UserNotifications
import CoreLocation
import Speech
import ShiriCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section("记录与整理") {
                    NavigationLink { DraftsView() } label: { Label("草稿箱", systemImage: "square.and.pencil") }
                    NavigationLink { StoredCardsView(lifecycle: .archived) } label: { Label("已归档", systemImage: "archivebox") }
                    NavigationLink { StoredCardsView(lifecycle: .deleted) } label: { Label("最近删除", systemImage: "trash") }
                    NavigationLink { BackupView() } label: { Label("备份与恢复", systemImage: "externaldrive") }
                }
                Section("提醒与同步") {
                    Picker("到点后询问", selection: Binding(get: { model.preferences.completionConfirmationMinutes }, set: { model.preferences.completionConfirmationDelay = $0 })) {
                        Text("5 分钟后询问一次").tag(5)
                        Text("10 分钟后询问一次").tag(10)
                        Text("不再询问").tag(0)
                    }.accessibilityIdentifier("completionConfirmationDelay")
                    Text("未完成的待办会提醒你确认完成情况。允许通知后，点开提醒即可标记完成、稍后提醒或更改时间。").font(.footnote).foregroundColor(Paper.secondary)
                    NavigationLink { PermissionCenterView() } label: { Label("权限与提醒状态", systemImage: "bell.badge") }
                    NavigationLink { DiagnosticExportView() } label: { Label("导出诊断摘要", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { CloudSettingsView() } label: { Label("iCloud 与保存位置", systemImage: "icloud") }
                    Toggle("为新卡片提供默认时刻", isOn: Binding(get: { model.preferences.defaultReminderTime != nil }, set: { model.preferences.defaultReminderTime = $0 ? DayTime(hour: 9) : nil }))
                    if let defaultTime = model.preferences.defaultReminderTime {
                        DatePicker("默认时刻", selection: Binding(get: { OccurrenceEngine(calendar: model.calendar).date(CivilDate(model.now, calendar: model.calendar), time: defaultTime) ?? model.now }, set: { model.preferences.defaultReminderTime = DayTime(hour: model.calendar.component(.hour, from: $0), minute: model.calendar.component(.minute, from: $0)) }), displayedComponents: .hourAndMinute)
                    }
                    Toggle("显示回顾数量对比", isOn: Binding(get: { model.preferences.showsReviewComparison == true }, set: { model.preferences.showsReviewComparison = $0 }))
                    Toggle("提醒我查看回顾", isOn: $model.preferences.showReviewReminder)
                    if model.preferences.showReviewReminder { Text("每周日 20:00 提醒一次；需要普通通知权限。不会根据完成数量增加提醒。").font(.footnote).foregroundColor(Paper.secondary) }
                }
                Section("外观与隐私") {
                    Picker("外观", selection: $model.preferences.colorScheme) { ForEach(AppColorScheme.allCases, id: \.self) { Text($0.title) } }
                    Picker("通知与闹钟内容", selection: $model.preferences.notificationPrivacy) { ForEach(ContentPrivacy.allCases, id: \.self) { Text($0.title) } }
                    if model.preferences.notificationPrivacy == .hidden { Text("当前会隐藏通知与系统闹钟中的待办标题。希望看到具体事项时，可改为仅显示标题。").font(.footnote).foregroundColor(Paper.secondary) }
                    Picker("组件内容", selection: $model.preferences.widgetPrivacy) { ForEach(ContentPrivacy.allCases, id: \.self) { Text($0.title) } }
                    Toggle("切换到后台时遮蔽内容", isOn: $model.preferences.hidesAppWhenInactive)
                    Text("组件默认不显示图片。隐藏内容时仅显示数量与通用说明。").font(.footnote).foregroundColor(Paper.secondary)
                }
                Section {
                    NavigationLink { PrivacyExplanationView() } label: { Label("数据与隐私说明", systemImage: "hand.raised") }
                    NavigationLink { DataManagementView() } label: { Label("数据管理", systemImage: "externaldrive.badge.minus") }
                }
                Section {
                    Text("拾日\n无需注册账户，记录默认保存在本机。").font(.footnote).foregroundColor(Paper.secondary)
                    Text("一次购买，无应用内购买。").font(.footnote).foregroundColor(Paper.secondary).accessibilityIdentifier("paidDownloadInfo")
                }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .onChange(of: model.preferences) { _ in model.perform { try await model.savePreferences() } }
                .onChange(of: model.preferences.showReviewReminder) { value in
                    if value { model.perform { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound,.badge]) } }
                }
        }.alert("操作提示", isPresented: Binding(get: { model.selectedTab == .settings && model.message != nil },set: { if !$0 { model.message = nil } })) { Button("知道了") { model.message = nil } } message: { Text(model.message ?? "") }
    }
}

struct DataManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deletingScope: DataScope?
    @State private var busy = false
    var body: some View {
        List {
            Section("系统备份") {
                Toggle("将应用数据排除在系统备份外", isOn: Binding(get: { model.preferences.excludesSystemBackup == true }, set: { model.preferences.excludesSystemBackup = $0 }))
                Text("本机保存表示拾日不主动同步。设备的 iCloud 或电脑备份仍可能包含这些数据。开启排除后，设备遗失或卸载可能导致本机记录无法恢复，请自行导出需要保留的内容。主动导出的文件由你选择的保存位置管理。").font(.footnote).foregroundColor(Paper.secondary)
            }
            Section("删除本人卡片") {
                Button("删除所有本机卡片与草稿", role: .destructive) { deletingScope = .local }.disabled(busy)
                Text("删除本机卡片和对应处理历史，并取消其提醒。恢复前备份、已导出的文件、自己的云端副本和已发送的分享仍会保留。").font(.footnote).foregroundColor(Paper.secondary)
                if model.cloudFeedbackAvailable {
                    Button("请求删除我的云端卡片", role: .destructive) { deletingScope = .privateCloud }.disabled(busy)
                    Text("删除当前 iCloud 账户中的本人卡片。其他设备收到同步后移除这些云端卡片，接收者已添加的独立日程不变。分享邀请请在分享中心撤销。").font(.footnote).foregroundColor(Paper.secondary)
                }
                if busy { ProgressView("正在处理…") }
            }
        }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("数据管理")
            .confirmationDialog(deletingScope == .local ? "永久删除所有本机卡片、处理历史和草稿？请先导出需要保留的数据。" : "请求永久删除当前账户的本人云端卡片及历史？其他设备同步后也会移除。", isPresented: Binding(get: { deletingScope != nil }, set: { if !$0 { deletingScope = nil } }), titleVisibility: .visible) {
                Button("确认删除", role: .destructive) {
                    guard let scope = deletingScope else { return }; deletingScope = nil; busy = true
                    model.perform {
                        defer { busy = false }
                        let count = try await model.repository?.deleteAllCards(in: scope, now: model.now) ?? 0
                        model.message = scope == .local ? "已删除 \(count) 张本机卡片与草稿。" : "已在此设备移除 \(count) 张云端卡片，云端删除由系统继续同步。"
                    }
                }
                Button("取消", role: .cancel) {}
            }
    }
}

struct PermissionCenterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notification = "正在读取…"
    @State private var pending = 0
    private let location = CLLocationManager()
    var body: some View {
        List {
            Section("通知") {
                LabeledContent("通知权限", value: notification)
                LabeledContent("待提醒", value: "\(pending) 条")
                Button("允许普通通知") { Task { do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); await model.refresh(); await read() } catch { model.message = error.localizedDescription } } }
            }
            Section("提醒状态") {
                LabeledContent("已安排", value: "\(model.reminderLedger.filter { $0.status == .registered }.count) 条")
                LabeledContent("等待安排", value: "\(model.deferredReminders) 条")
                ForEach(model.reminderIssues) { issue in VStack(alignment: .leading, spacing: 4) { Text(model.library.cards.first { $0.id == issue.cardID }?.title ?? "地点提醒"); Text(issue.message).font(.caption).foregroundColor(Paper.accent) } }
                ForEach(model.reminderLedger) { entry in VStack(alignment: .leading, spacing: 4) { Text(entry.request.title); Text(entry.message ?? "已安排 · \(entry.request.firesAt.formatted(date: .abbreviated, time: .shortened))" + (entry.request.payload.scope == .series ? " · 重复提醒" : "")).font(.caption).foregroundColor(entry.status == .registered ? Paper.secondary : Paper.accent) } }
                Button("刷新提醒状态") { Task { await model.refresh(); await read() } }
            }
            if #available(iOS 26.0, *) {
                Section("系统闹钟") {
                    Text(model.systemCapabilities.alarms.title).accessibilityIdentifier("alarmAuthorization")
                    Button("允许系统闹钟") {
                        if !AlarmAdapter.needsPermission && !AlarmAdapter.allowed {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } else { Task { do { try await AlarmAdapter.requestPermission(); await model.refresh() } catch { model.message = error.localizedDescription } } }
                    }
                    Text("停止响铃不会将待办标记为完成。").font(.footnote).foregroundColor(Paper.secondary)
                }
            }
            Section("定位与语音") {
                Button("开启后台地点提醒权限") { model.geofences.requestBackgroundPermission() }
                LabeledContent("定位", value: location.authorizationStatus == .authorizedAlways ? "始终允许" : location.authorizationStatus == .authorizedWhenInUse ? "使用期间允许" : location.authorizationStatus == .notDetermined ? "尚未开启" : "未允许")
                LabeledContent("语音识别", value: model.systemCapabilities.localSpeech.title)
                if model.systemCapabilities.enhancedSpeech.isSupported { LabeledContent("增强语音识别", value: model.systemCapabilities.enhancedSpeech.title) }
                Text("在你使用相应功能时才请求权限。拒绝权限仍然可以使用文字记事和本地卡片。").font(.footnote).foregroundColor(Paper.secondary)
            }
            Section {
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
        }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("权限与提醒").task { await read() }
            .onReceive(model.geofences.$authorization) { _ in Task { await model.refresh(); await read() } }
    }
    private func read() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus { case .authorized: notification = "已允许"; case .provisional: notification = "暂时允许"; case .denied: notification = "已关闭"; case .notDetermined: notification = "尚未请求"; default: notification = "受系统限制" }
        pending = await UNUserNotificationCenter.current().pendingNotificationRequests().count
        model.systemCapabilities.enhancedSpeech = await CapabilityProvider.enhancedSpeech()
    }
}

struct DraftsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var drafts: [CardDraft] = []
    @State private var loading = true
    @State private var loadError: String?
    var body: some View {
        List {
            if loading { ProgressView("正在打开草稿…") }
            else if let loadError { PaperErrorBanner(message: loadError) }
            else if drafts.isEmpty { PaperEmptyState(title: "念头可以慢慢写", message: "还没写完的话，选择“保存草稿”后，\n下次可以从这里继续。", compact: true).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            ForEach(drafts) { draft in
                Button { model.composer = draft } label: {
                    VStack(alignment: .leading, spacing: 7) { Text(draft.card.isMemory ? "回忆 · " + MemoryDrafts.title(draft) : draftLabel(draft)).foregroundColor(Paper.ink); Text(draft.updatedAt.formatted()).font(.caption).foregroundColor(Paper.secondary) }
                }
            }.onDelete { indices in
                let ids = indices.map { drafts[$0].id }
                model.perform { for id in ids { try await model.repository?.deleteDeviceRecord(entity: "DraftRecord", id: id) }; drafts = try await model.repository?.drafts() ?? [] }
            }
        }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("草稿箱")
            .task(id: model.composer?.id) { defer { loading = false }; do { drafts = try await model.repository?.drafts() ?? []; loadError = nil } catch { loadError = error.localizedDescription } }
    }
    private func draftLabel(_ draft: CardDraft) -> String {
        for value in [draft.card.title, draft.originalText, draft.card.note] {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(120)) }
        }
        return draft.attachments.isEmpty ? "未完成的草稿" : "图片草稿"
    }
}

struct StoredCardsView: View {
    @EnvironmentObject private var model: AppModel
    var lifecycle: CardLifecycle
    @State private var deleting: Card?
    @State private var restoring: Card?
    var body: some View {
        List {
            if lifecycle == .deleted { Text("删除的卡片保留 30 天。恢复后保留历史，提醒会重新检查权限与时间。").font(.footnote).foregroundColor(Paper.secondary) }
            let cards = model.library.cards.filter { $0.lifecycle == lifecycle }
            if cards.isEmpty { PaperEmptyState(title: lifecycle == .deleted ? "最近没有删除卡片" : "还没有归档卡片", message: lifecycle == .deleted ? "暂时删去的记录会在这里保留 30 天。\n需要时，可以在到期前恢复。" : "暂时放下的事，归档后会留在这里。\n需要时，随时可以恢复。", scene: .archive, compact: true).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 11) {
                    Text(card.title).font(.headline)
                    Text(card.updatedAt.formatted()).font(.caption).foregroundColor(Paper.secondary)
                    Button("恢复卡片") { restoring = card }.accessibilityIdentifier("restoreStoredCard_\(card.id)")
                    if lifecycle == .deleted { Button("永久删除", role: .destructive) { deleting = card } }
                }.buttonStyle(.borderless).padding(.vertical, 6)
            }
        }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle(lifecycle == .deleted ? "最近删除" : "已归档")
            .sheet(item: $restoring) { CardRestoreConfirmationView(card: $0).environmentObject(model) }
            .confirmationDialog("永久删除这张卡片与自己的处理历史？此操作不能恢复；对方已添加的独立日程仍会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("永久删除", role: .destructive) { if let card = deleting { model.perform { try await model.repository?.permanentlyDelete(cardID: card.id, now: model.now) }; deleting = nil } }
            }
    }
}

struct CardRestoreConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let card: Card
    @State private var busy = false
    @State private var loading = true
    @State private var error: String?
    @State private var plan = "正在核对…"
    @State private var reminder: String?
    @State private var capabilities = DeviceCapabilitySnapshot()
    private var hasReminders: Bool { card.reminders.isEnabled || card.reminders.enablesLiveActivity }
    var body: some View {
        NavigationStack {
            List {
                Section { Text(card.title).font(.headline) }
                Section("恢复后的安排") {
                    Text(plan).accessibilityIdentifier("restoreNextPlan")
                    if let reminder { Text(reminder).font(.subheadline).foregroundColor(Paper.secondary).accessibilityIdentifier("restoreNextReminder") }
                    Text("已过去的提醒不会补发，完成与跳过的历史保持不变。原先停止的单次提醒不会重新开启。").font(.footnote).foregroundColor(Paper.secondary)
                }
                if hasReminders {
                    Section("提醒权限") {
                        if card.reminders.isEnabled {
                            LabeledContent(card.reminders.channel == .alarm ? "系统闹钟" : "普通通知", value: card.reminders.channel == .alarm ? capabilities.alarms.title : capabilities.notifications.title)
                            if card.place != nil { LabeledContent("后台定位", value: capabilities.location.title) }
                        }
                        if card.reminders.enablesLiveActivity { LabeledContent("锁屏与灵动岛", value: capabilities.liveActivities.title) }
                        Text("提醒需要相应权限。恢复后，可在“权限与提醒状态”中检查并开启。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                }
                if let error { Section { PaperErrorBanner(message: error) } }
                Section {
                    if loading { ProgressView("正在检查计划与权限…") }
                    else {
                        Button(hasReminders ? "按原设置恢复" : "恢复卡片") { restore(keepingReminders: true) }.accessibilityIdentifier("confirmRestoreWithReminders")
                        if hasReminders {
                            Button("仅恢复卡片，关闭提醒") { restore(keepingReminders: false) }.accessibilityIdentifier("confirmRestoreWithoutReminders")
                            Text("保留原来的日期、重复规则和地点，关闭通知、闹钟与实时活动；之后可以在卡片中重新开启。").font(.footnote).foregroundColor(Paper.secondary)
                        }
                    }
                    if busy { ProgressView("正在恢复…") }
                }.disabled(busy || loading || error != nil)
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("确认恢复").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
        }.interactiveDismissDisabled(busy).task { await prepare() }
    }
    @MainActor private func prepare() async {
        defer { loading = false }
        capabilities = await CapabilityProvider.read(locationAuthorization: model.geofences.authorization)
        guard let repository = model.repository else { error = "正在读取卡片，请稍后再试"; return }
        do {
            var library = try await repository.library()
            guard var current = library.cards.first(where: { $0.id == card.id }), current.revisionID == card.revisionID, current.lifecycle != .active else { throw ShiriError.conflict("卡片已变化，请关闭后重新打开恢复预览。") }
            current.lifecycle = .active; current.deletedAt = nil
            library.cards = library.cards.map { $0.id == current.id ? current : $0 }
            let engine = OccurrenceEngine(calendar: model.calendar)
            var cursor = model.now
            var next: Occurrence?
            for _ in 0..<1000 {
                guard let candidate = engine.next(for: current, after: cursor, overrides: library.overrides), let date = candidate.plannedAt else { break }
                if EventReducer.state(events: library.events(for: candidate.id)) == .pending { next = candidate; break }
                cursor = date.addingTimeInterval(1)
            }
            if current.recurrenceClosedAt != nil { plan = "重复规则已关闭；恢复卡片不会重新开启规则。" }
            else if let place = current.place {
                let occurrence = engine.relevantOccurrence(for: current, at: model.now, overrides: library.overrides)
                if let occurrence, EventReducer.state(events: library.events(for: occurrence.id)) != .pending {
                    plan = "这次地点事项已处理，恢复卡片不会重新触发这次提醒。"
                } else if let occurrence, library.personalStates[occurrence.id]?.isStopped == true {
                    plan = "这次地点提醒已停止，恢复卡片不会重新开启。可在卡片中自行恢复提醒。"
                } else if let end = place.endAt, end <= model.now { plan = "地点提醒有效期已结束，恢复后需重新设置有效期。" }
                else if !current.reminders.isEnabled { plan = "保留地点“\(place.name)”；原提醒已关闭，恢复后不会触发。" }
                else if current.scope == .privateCloud && !model.preferences.remindsForPrivateCloudCards && !model.preferences.enabledCloudCardIDs.contains(current.id) {
                    plan = "保留地点“\(place.name)”；此设备尚未开启这张云端卡片的提醒。"
                } else { plan = "\(place.trigger == .enter ? "到达" : "离开")\(place.name)时提醒；按原来的地点和范围判断。" }
            } else if let date = next?.plannedAt {
                let hasTime = current.schedule?.time != nil || current.birthday?.dayTime != nil
                plan = "下次计划：" + date.formatted(date: .complete, time: hasTime ? .shortened : .omitted)
            } else if current.schedule != nil || current.birthday != nil { plan = "目前没有下一次有效计划；仅保留记录，不补发过去的提醒。" }
            else { plan = current.kind == .note ? "这是一张记事卡，没有定时提醒。" : "这是一件长期待办，没有指定日期。" }
            let desired = ReminderPlanner(calendar: model.calendar).plan(library: library, preferences: model.preferences, now: model.now, capabilities: ReminderCapabilities(notificationsAllowed: true, alarmAllowed: true))
            if let nextReminder = (desired.requests + desired.deferred).filter({ $0.cardID == current.id }).min(by: { $0.firesAt < $1.firesAt }) {
                reminder = "下次时间提醒：" + nextReminder.firesAt.formatted(date: .complete, time: .shortened)
            } else if current.reminders.isEnabled && current.place == nil { reminder = "目前没有接下来的提醒。" }
        } catch { self.error = error.localizedDescription }
    }
    private func restore(keepingReminders: Bool) {
        guard !busy, !loading, error == nil, let commands = model.commands else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let restored = try await commands.restore(card, keepingReminders: keepingReminders, now: model.now)
                await model.refresh()
                if keepingReminders {
                    do { try await model.liveActivities.activateSavedCard(restored, library: model.library, privacy: model.preferences.notificationPrivacy, now: model.now) }
                    catch { model.message = "卡片已恢复。锁屏与灵动岛暂未开启：" + error.localizedDescription }
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var export: SharedFile?
    @State private var importer = false
    @State private var backup: BackupDocument?
    @State private var preview: BackupRestorePreview?
    @State private var recoveryPoints: [BackupRecoveryPoint] = []
    @State private var selectedRecoveryID: String?
    @State private var confirmation: BackupConflictPolicy?
    @State private var status: String?
    @State private var busy = false
    var body: some View {
        List {
            Section {
                Text("备份包含你的卡片、重复安排、图片和完成历史，导入后保存在本机。分享邀请及他人的完成反馈不包含在备份中。").font(.subheadline).foregroundColor(Paper.secondary)
                Button("导出完整备份") { exportCurrent() }.disabled(busy).accessibilityIdentifier("exportFullBackup")
                Button("选择备份文件") { importer = true }.disabled(busy).accessibilityIdentifier("importBackupFile")
            }
            if let backup, let preview {
                Section(selectedRecoveryID == nil ? "备份预览" : "恢复点预览") {
                    Text("\(backup.payload.cards.count) 张卡片 · \(backup.payload.events.count) 条处理记录 · \(backup.payload.attachments.count) 张图片")
                    Text("导出时间：\(backup.exportedAt.formatted())").font(.footnote)
                    Text("新增 \(preview.newCount) 张 · 与已有卡片重合 \(preview.matchingCount) 张").accessibilityIdentifier("backupConflictPreview")
                    Button("保留已有内容：新增 \(preview.newCount) 张，跳过 \(preview.matchingCount) 张") { confirmation = .keepExisting }.accessibilityIdentifier("keepExistingBackup")
                    Button("使用这份备份：新增 \(preview.newCount) 张，替换 \(preview.matchingCount) 张") { confirmation = .replaceMatching }.disabled(preview.cloudMatchingCount > 0).accessibilityIdentifier("replaceMatchingBackup")
                    if preview.cloudMatchingCount > 0 { Text("其中 \(preview.cloudMatchingCount) 张已在 iCloud 中，需先保存到本机才能替换；仍可选择保留已有内容。").font(.footnote).foregroundColor(Paper.accent) }
                    Text("替换前会保存一份可恢复的备份，你可以在下方查看或导出。卸载拾日会一并移除，请及时导出重要备份。").font(.footnote).foregroundColor(Paper.secondary)
                    if selectedRecoveryID != nil { Button("导出这份恢复点") { exportSelected() }.accessibilityIdentifier("exportRecoveryPoint") }
                    Button("取消选择") { self.backup = nil; self.preview = nil; selectedRecoveryID = nil }
                }.disabled(busy)
            }
            Section("恢复前备份") {
                if recoveryPoints.isEmpty { Text("使用备份替换已有卡片前，拾日会在这里保留当时的记录。").font(.subheadline).foregroundColor(Paper.secondary).accessibilityIdentifier("recoveryPointsEmpty") }
                ForEach(recoveryPoints) { point in
                    Button { inspectRecovery(point) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(point.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(point.byteCount), countStyle: .file) + " · 点击预览").font(.caption).foregroundColor(Paper.secondary)
                        }
                    }.accessibilityIdentifier("recoveryPoint_\(point.id)")
                }
            }.disabled(busy)
            if busy { Section { ProgressView("正在处理，请保持应用打开…") } }
            if let status { Section { Text(status).font(.subheadline).accessibilityIdentifier("backupStatus") } }
        }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("备份与恢复")
            .sheet(item: $export, onDismiss: { export = nil }) { SystemShareSheet(items: [$0.url]) }
            .task { reloadRecoveryPoints() }
            .alert("确认恢复这份备份？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                if let policy = confirmation {
                    Button("确认恢复", role: policy == .replaceMatching && (preview?.matchingCount ?? 0) > 0 ? .destructive : nil) { confirmation = nil; restore(policy) }.accessibilityIdentifier("confirmBackupRestore")
                }
                Button("取消", role: .cancel) { confirmation = nil }
            } message: {
                if let preview { Text("新增 \(preview.newCount) 张 · 替换 \(confirmation == .replaceMatching ? preview.matchingCount : 0) 张 · 跳过 \(confirmation == .keepExisting ? preview.matchingCount : 0) 张。未包含在备份中的现有卡片会保留。\(confirmation == .replaceMatching && preview.matchingCount > 0 ? "替换前将保存恢复点。" : "")") }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.shiriBackup, .json]) { result in
                guard !busy else { return }
                switch result {
                case .success(let url):
                    do {
                        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let document = try FileTransport.decodeBackup(FileTransport.read(url, limit: AppLimits.backupBytes))
                        inspect(document, recoveryID: nil)
                    } catch { status = error.localizedDescription; backup = nil; preview = nil }
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { status = error.localizedDescription }
                }
            }
    }
    private func reloadRecoveryPoints() {
        do { recoveryPoints = try model.repository?.recoveryPoints() ?? [] }
        catch { status = "恢复点暂时无法读取：" + error.localizedDescription }
    }
    private func inspectRecovery(_ point: BackupRecoveryPoint) {
        guard !busy, let repository = model.repository else { return }
        do { inspect(try repository.recoveryBackup(id: point.id), recoveryID: point.id) }
        catch { status = "暂时无法使用这份恢复点，现有内容未改变：" + error.localizedDescription; backup = nil; preview = nil }
    }
    private func inspect(_ document: BackupDocument, recoveryID: String?) {
        guard !busy, let repository = model.repository else { return }
        busy = true; status = nil
        Task { @MainActor in
            defer { busy = false }
            do { preview = try await repository.previewBackup(document); backup = document; selectedRecoveryID = recoveryID }
            catch { status = error.localizedDescription; backup = nil; preview = nil }
        }
    }
    private func exportCurrent() {
        guard !busy, let repository = model.repository else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            do { export = try SharedFile.write(FileTransport.encode(try await repository.exportBackup(now: model.now)), extension: "nianyibackup") }
            catch { status = error.localizedDescription }
        }
    }
    private func exportSelected() {
        guard !busy, let backup else { return }
        do { export = try SharedFile.write(FileTransport.encode(backup), extension: "nianyibackup") }
        catch { status = error.localizedDescription }
    }
    private func restore(_ policy: BackupConflictPolicy) {
        guard !busy, let backup, let preview, let repository = model.repository else { return }; busy = true
        Task { @MainActor in
            defer { busy = false; reloadRecoveryPoints() }
            do {
                let count = try await repository.restoreBackup(backup, policy: policy, now: model.now, expectedPreview: preview)
                await model.refresh()
                status = "已恢复 \(count) 张卡片。已有内容和未包含的卡片按确认的方式保留；未来提醒已重新核对，可在“权限与提醒状态”查看。"
                self.backup = nil; self.preview = nil; selectedRecoveryID = nil
            } catch {
                status = error.localizedDescription
                self.preview = try? await repository.previewBackup(backup)
            }
        }
    }
}

struct CloudSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var removingCloudCopy: Card?
    @State private var pausing = false
    var body: some View {
        List {
            Section("iCloud 连接") {
                Text(model.cloudStatus).font(.subheadline)
                Button(model.isConnectingCloud ? "正在连接…" : "连接我的 iCloud") { model.perform { try await model.connectCloud() } }.disabled(model.isConnectingCloud)
                Text("只有你选中的卡片会保存到 iCloud，在自己的设备间同步。给他人的完成反馈需要单独同意。").font(.footnote).foregroundColor(Paper.secondary)
            }
            if model.cloudFeedbackAvailable {
                Section("此设备") {
                    Button("停止同步并保留在本机") { pausing = true }
                    Toggle("此设备也提醒云端卡片", isOn: $model.preferences.remindsForPrivateCloudCards)
                    Picker("新卡片默认保存", selection: $model.preferences.defaultScope) { ForEach(DataScope.allCases, id: \.self) { Text($0.title) } }
                }
                Section("选择卡片的保存位置") {
                    ForEach(model.library.cards.filter { $0.lifecycle != .deleted }) { card in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(card.title)
                            Text(card.scope.title).font(.caption).foregroundColor(Paper.secondary)
                            Button(card.scope == .local ? "保存到我的 iCloud" : "仅保留本机并删除云端副本") {
                                if card.scope == .privateCloud { removingCloudCopy = card }
                                else { model.perform { try await model.repository?.migrateCard(card.id, to: .privateCloud, now: model.now) } }
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }
            if !model.pendingMigrations.isEmpty {
                Section("尚未完成的保存操作") {
                    Text("上次切换保存位置尚未完成，原内容仍然保留。可以继续处理，或先使用原来的副本。").font(.footnote).foregroundColor(Paper.secondary)
                    ForEach(model.pendingMigrations) { journal in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.library.cards.first { $0.id == journal.cardID }?.title ?? "待恢复卡片")
                            Button("继续完成保存") { model.perform { try await model.repository?.resumeMigrations() } }
                            Button("先使用原副本") { model.perform { try await model.repository?.keepOriginalScope(for: journal.id) } }
                        }
                    }
                }
            }
            Section { Text("本机卡片可以离线使用。iCloud 同步需要网络，其他设备上的更新可能稍有延迟。").font(.footnote).foregroundColor(Paper.secondary) }
        }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("iCloud 与保存位置")
            .confirmationDialog("先将可访问卡片保留本地，再停止此设备的同步。云端副本和已发出的私有邀请会保留，后续反馈暂停接收。", isPresented: $pausing, titleVisibility: .visible) {
                Button("保留本地并停止同步") { model.perform { try await model.pauseCloudSync() } }
            }
            .confirmationDialog("将这张卡片迁回本机并请求删除自己的云端副本？其他设备同步后也会移除该云副本。接收者已添加的日程不受影响。", isPresented: Binding(get: { removingCloudCopy != nil },set: { if !$0 { removingCloudCopy = nil } }), titleVisibility: .visible) {
                Button("仅保留本机并删除云端副本", role: .destructive) { if let card = removingCloudCopy { model.perform { try await model.repository?.migrateCard(card.id, to: .local, now: model.now) }; removingCloudCopy = nil } }
            }
    }
}

struct PrivacyExplanationView: View {
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text("你的日常，\n由你决定如何保存").font(Paper.title(30))
            Text("默认保存在本机\n无需注册拾日账户，你的记录默认保存在设备上。卸载前，请备份需要保留的记录。\n\n由你选择是否同步\n你可以选择将卡片保存到 iCloud，也可以单独选择是否分享完成状态。完成反馈不包含接收者的正文、图片和位置；关闭反馈后，已添加的卡片仍会保留。\n\n语音与图片\n语音和截图文字识别在设备上完成，不会上传录音或截图。无法识别时，可以手动输入。保存图片时会移除拍摄位置等附加信息。\n\n权限与网络\n地图搜索与 iCloud 由 Apple 提供，可能需要网络。你可以在系统设置中管理通知、定位和麦克风权限。\n\n备份与导出\n你可以导出自己的卡片与完成历史。备份文件含有个人内容，请保存在你信任的位置。").font(.body).lineSpacing(7).foregroundColor(Paper.secondary)
        }.padding(24) }.background(Paper.background).navigationTitle("数据与隐私").navigationBarTitleDisplayMode(.inline)
    }
}


struct DiagnosticExportView: View {
    @EnvironmentObject private var model: AppModel
    @State private var file: SharedFile?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("生成用于排查问题的设备和应用信息，不包含卡片标题、正文、图片、位置或账户身份。生成后由你选择是否导出。").font(.subheadline).foregroundColor(Paper.secondary)
                Button("生成诊断摘要") { Task { await generate() } }.buttonStyle(PaperPrimaryButton())
                if let file {
                    Text("诊断摘要已生成，可导出后用于排查问题。").font(.subheadline).foregroundColor(Paper.secondary)
                    ShareLink("导出这份摘要", item: file.url)
                }
                if let error { PaperErrorBanner(message: error) }
            }.padding(20)
        }.background(Paper.background).navigationTitle("诊断摘要")
    }
    @MainActor private func generate() async {
        do {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let values: [String: Any] = [
                "format": "app.nianyi.diagnostics", "version": 1, "reportID": UUID().uuidString,
                "generatedAt": ISO8601DateFormatter().string(from: model.now), "osVersion": UIDevice.current.systemVersion,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "notificationAuthorization": settings.authorizationStatus.rawValue,
                "locationAuthorization": model.geofences.authorization.rawValue,
                "cloudConfigured": model.cloudConfigured, "cloudConnected": model.cloudFeedbackAvailable,
                "cardCount": model.library.cards.count, "eventCount": model.library.events.count,
                "pendingMigrations": model.pendingMigrations.count, "deferredReminders": model.deferredReminders,
                "registeredReminders": model.reminderLedger.filter { $0.status == .registered }.count,
                "lastErrorCode": model.lastFailureCode ?? "none"
            ]
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            file = try SharedFile.write(data, extension: "json")
        } catch { self.error = error.localizedDescription }
    }
}
