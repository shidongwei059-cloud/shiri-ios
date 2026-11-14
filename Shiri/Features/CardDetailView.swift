import SwiftUI
import ShiriCore

struct ReminderResponseView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: ReminderResponseRequest
    @State private var choosesTime: Bool
    @State private var date = Date().addingTimeInterval(600)
    @State private var busy = false
    @State private var error: String?
    init(request: ReminderResponseRequest) {
        self.request = request
        _choosesTime = State(initialValue: request.selectsNewTime)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.library.cards.first { $0.id == request.payload.cardID }?.title ?? "这一次待办")
                        .font(Paper.title(26)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("reminderResponseTitle")
                    Text("这件事完成了吗？").font(Paper.text(18)).accessibilityIdentifier("reminderResponseQuestion")
                    if let error { PaperErrorBanner(message: error) }
                    if choosesTime {
                        DatePicker("新的安排时间", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical).accessibilityIdentifier("reminderResponseDate")
                        Text("只修改这一次安排；重复规则和完成截止保持原样。").font(.footnote).foregroundColor(Paper.secondary)
                        Button("保存新时间") { respond(.reschedule(date)) }.buttonStyle(PaperPrimaryButton()).accessibilityIdentifier("reminderResponseSaveTime")
                    } else {
                        Button("已完成") { respond(.complete) }.buttonStyle(PaperPrimaryButton()).accessibilityIdentifier("reminderResponseComplete")
                        Button("10 分钟后提醒") { respond(.snooze) }.frame(maxWidth: .infinity, minHeight: 48).accessibilityIdentifier("reminderResponseSnooze")
                        Button("更改时间") { choosesTime = true }.frame(maxWidth: .infinity, minHeight: 48).accessibilityIdentifier("reminderResponseChangeTime")
                    }
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                }.padding(24).disabled(busy)
            }.background(Paper.background).navigationTitle("处理提醒").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("暂不处理") { dismiss() }.disabled(busy) } }
        }
    }
    private func respond(_ action: ReminderResponseAction) {
        busy = true; error = nil
        Task {
            do { try await model.respondToReminder(request, action: action); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct CardDetailView: View {
    @EnvironmentObject private var model: AppModel
    var cardID: UUID
    var occurrence: Occurrence? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var reminderStatus = false
    @State private var preparations = false
    @State private var memoryBook = false
    @State private var memoryComposer = false
    @State private var memoryToWrite: MemoryCandidate?
    @State private var sharing = false
    @State private var history = false
    @State private var photos: [Attachment] = []
    @State private var photo: Attachment?
    @State private var reschedule = false
    @State private var newDate = Date()
    @State private var editScope = false
    @State private var closesSeries = false
    @State private var showsCustomSnooze = false
    @State private var showsSnoozeOptions = false
    @State private var restoringCard: Card?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var projection: CardProjection? { model.detailProjection(cardID: cardID, occurrence: occurrence) }
    var body: some View {
        VStack(spacing: 0) {
            detailNavigation
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let p = projection {
                    detailHero(p)
                    if let candidate = model.pendingMemory, candidate.card.id == p.card.id { MemoryCompletionPrompt(candidate: candidate) }
                    if !p.card.note.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.card.kind == .note ? "记录" : "备注").font(Paper.text(13).weight(.medium)).foregroundColor(Paper.secondary)
                            Text(p.card.note).font(Paper.text(15)).foregroundColor(Paper.ink).lineSpacing(4).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("detailNote")
                        }.padding(.horizontal, 2)
                    }
                    if p.hasConflict {
                        NavigationLink { ConflictResolutionView(cardID: cardID) } label: { PaperErrorBanner(message: "不同设备修改了这张卡片，点此确认要保留的安排") }
                    }
                    if isHistoricOccurrence(p) {
                        Text("这是旧重复规则留下的记录，可以查看历史或撤销完成。调整或分享当前安排，请返回卡片库打开现行规则。")
                            .font(.footnote).foregroundColor(Paper.secondary)
                    }
                    VStack(spacing: 0) {
                        if let deadline = CardPresentation.deadline(p) {
                            detailRow("flag", "完成截止", CardPresentation.dateLabel(deadline, format: "yyyy年M月d日 HH:mm", calendar: p.card.schedule?.calendar(fallback: model.calendar) ?? model.calendar), card: p.card)
                                .accessibilityIdentifier("detailDeadline")
                        }
                        if p.card.kind == .task || p.card.birthday != nil || p.card.reminders.isEnabled || p.card.schedule != nil {
                            Button { reminderStatus = true } label: {
                                ComposerRow(symbol: "bell", title: "提醒与锁屏", value: model.reminderStatus(for: p).text)
                            }.accessibilityIdentifier("detailReminderStatus")
                            detailRow("arrow.triangle.2.circlepath", "重复", p.card.recurrenceClosedAt != nil ? "重复已关闭" : (p.card.birthday != nil ? (p.card.birthday?.repeatsYearly == true ? "每年" : "仅一次") : (p.card.schedule?.frequency.title ?? "不重复")), card: p.card).accessibilityIdentifier("detailRecurrence")
                        } else {
                            Text("记录于 " + CardPresentation.dateLabel(p.card.createdAt, format: "yyyy年M月d日 HH:mm")).font(.caption).foregroundColor(Paper.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                        if let place = p.card.place { detailRow("mappin.and.ellipse", "地点", place.name, card: p.card) }
                    }
                    if p.card.birthday != nil {
                        OccasionDateSummary(card: p.card)
                        Button { preparations = true } label: { Label("为这个日子做准备", systemImage: "list.bullet.clipboard").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityIdentifier("occasionPreparations")
                        HStack {
                            Button("留下这次的回忆") { memoryComposer = true }.frame(minHeight: 44).accessibilityIdentifier("occasionNewMemory")
                            Spacer()
                            Button("往年记录") { memoryBook = true }.frame(minHeight: 44).accessibilityIdentifier("occasionMemories")
                        }.font(.subheadline)
                    }
                    if let link = p.card.occasionLink {
                        if let parent = model.library.cards.first(where: { $0.id == link.cardID && $0.lifecycle != .deleted }) {
                            NavigationLink { CardDetailView(cardID: parent.id) } label: { Label("关于“" + parent.title + "”", systemImage: "heart.text.clipboard").font(.subheadline).frame(minHeight: 44) }
                            if link.templateID != nil { Text("为 " + link.date.key + " 做的准备；日期独立保留，可通过编辑安排调整。").font(.caption).foregroundColor(Paper.secondary) }
                        } else { Text("关联的重要日子已不在卡片库，这份记录和安排仍然保留。").font(.caption).foregroundColor(Paper.secondary) }
                    }
                    if !photos.isEmpty {
                        ScrollView(.horizontal) { HStack(spacing: 12) { ForEach(photos) { a in if let image = UIImage(data: a.data) { Button { photo = a } label: { Image(uiImage: image).resizable().scaledToFill().frame(width: 112, height: 104).clipped().clipShape(RoundedRectangle(cornerRadius: 14)) }.accessibilityLabel("查看第 \(a.sortIndex + 1) 张图片") } } } }
                    }
                    if p.card.lifecycle == .active {
                        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 18))) {
                            Button { requestEdit(p.card) } label: { Label("编辑卡片", systemImage: "square.and.pencil").frame(maxWidth: .infinity).padding(.vertical, 16) }.disabled(isHistoricOccurrence(p)).accessibilityIdentifier("detailEdit")
                            if !typeSize.isAccessibilitySize { Divider().frame(height: 24) }
                            Button { sharing = true } label: { Label(p.card.kind == .note && p.card.birthday == nil ? "分享卡片" : "分享日程", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 16) }.disabled(isHistoricOccurrence(p))
                        }.font(Paper.text(16)).foregroundColor(Paper.ink).padding(.top, 2)
                        if p.card.birthday == nil && model.pendingMemory?.card.id != p.card.id {
                            let candidate = MemoryCollection.candidate(for: p.card, occurrence: p.occurrence, in: model.library, now: model.now)
                            let saved = MemoryCollection.savedMemory(for: candidate, in: model.library.cards)
                            Button(saved == nil ? "留成回忆" : "已留下回忆 · 查看") {
                                if saved != nil { memoryBook = true }
                                else { memoryToWrite = candidate }
                            }.font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("keepCardMemory")
                        }
                        if p.card.canComplete && p.card.recurrenceClosedAt == nil {
                            Button { model.complete(p) } label: { Label(p.state == .completed ? "撤销完成" : "标记完成", systemImage: p.state == .completed ? "arrow.uturn.backward" : "checkmark") }.buttonStyle(PaperPrimaryButton()).accessibilityIdentifier("detailComplete")
                        }
                        if p.occurrence != nil, p.state == .pending, p.card.reminders.isEnabled, p.card.recurrenceClosedAt == nil, !isHistoricOccurrence(p) {
                            Button("稍后提醒") { showsSnoozeOptions = true }
                                .font(Paper.text(14)).foregroundColor(Paper.accent).frame(maxWidth: .infinity, minHeight: 44).padding(.bottom, 5).accessibilityIdentifier("snoozeMenu")
                            if let until = p.reminderState?.snoozedUntil, p.reminderState?.isStopped != true {
                                Text("此设备已稍后至 " + CardPresentation.dateLabel(until, format: "yyyy年M月d日 HH:mm") + "\n只调整这一次提醒，安排与截止时间保持原样。")
                                    .font(.footnote).foregroundColor(Paper.secondary).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("snoozeStatus")
                            }
                            if p.reminderState?.isStopped == true { Text("此设备已停止本次提醒，事项仍未完成。").font(.footnote).foregroundColor(Paper.secondary) }
                        }
                    } else {
                        Text(p.card.lifecycle == .deleted ? "卡片已在最近删除中，30 天内可以恢复。" : "卡片已归档，内容和历史仍然保留。").font(.subheadline).foregroundColor(Paper.secondary)
                        Button("恢复卡片") { restoringCard = p.card }.buttonStyle(PaperPrimaryButton())
                    }
                } else { PaperEmptyState(title: "卡片已不存在", message: "它可能已在其他设备删除。\n返回卡片库可以查看当前内容。", scene: .search, actionTitle: "返回卡片库", action: { model.selectedCard = nil; model.selectedTab = .cards; dismiss() }) }
            }.padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 14)
            }
        }.background { PaperSurface().ignoresSafeArea() }.foregroundColor(Paper.ink).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $sharing) { if let p = projection { SharingComposerView(card: p.card, occurrence: p.occurrence).environmentObject(model) } }
            .alert("操作提示", isPresented: Binding(get: { model.message != nil && !preparations && !memoryBook && !memoryComposer && !reminderStatus && !sharing },set: { if !$0 { model.message = nil } })) { Button("知道了") { model.message = nil } } message: { Text(model.message ?? "") }
            .sheet(isPresented: $reminderStatus) { ReminderStatusView(cardID: cardID) }
            .sheet(isPresented: $preparations) { OccasionPreparationView(cardID: cardID) }
            .sheet(isPresented: $memoryBook) { MemoryBookView(occasionID: projection?.card.birthday != nil ? cardID : nil, sourceCardID: projection?.card.birthday != nil ? nil : cardID) }
            .sheet(item: $memoryToWrite) { MemoryComposerView(initialDate: $0.date, source: $0) }
            .sheet(isPresented: $memoryComposer) { MemoryComposerView(occasionID: cardID, initialDate: model.now) }
            .sheet(isPresented: $history) { HistoryView(cardID: cardID).environmentObject(model) }
            .sheet(item: $restoringCard) { CardRestoreConfirmationView(card: $0).environmentObject(model) }
            .confirmationDialog("这一次稍后到什么时候？", isPresented: $showsSnoozeOptions, titleVisibility: .visible) {
                if let p = projection, let occurrence = p.occurrence {
                    ForEach([10,30,60], id: \.self) { minutes in
                        Button("\(minutes) 分钟后") { model.perform { try await model.commands?.snooze(occurrence, until: model.now.addingTimeInterval(Double(minutes * 60)), now: model.now) } }
                    }
                    Button("选择日期与时间…") { showsCustomSnooze = true }
                    if p.reminderState?.snoozedUntil != nil {
                        Button("恢复原提醒时间") { model.perform { try await model.commands?.resumeReminder(occurrence, now: model.now) } }
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showsCustomSnooze) { if let p = projection { SnoozeReminderView(projection: p).environmentObject(model) } }
            .confirmationDialog("修改重复安排的范围", isPresented: $editScope, titleVisibility: .visible) {
                Button("仅本次日期与时间") { newDate = projection?.occurrence?.plannedAt ?? model.now; reschedule = true }
                Button("本次及以后") { if let p = projection { model.edit(p.card, from: p.occurrence) } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("关闭整个重复规则？过去记录会保留，也不会标记完成。", isPresented: $closesSeries, titleVisibility: .visible) {
                Button("关闭重复规则", role: .destructive) { if let card = projection?.card { model.perform { try await model.commands?.closeSeries(card: card, now: model.now) } } }
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $photo) { PhotoPreview(photo: $0) }
            .sheet(isPresented: $reschedule) {
                NavigationStack { Form { DatePicker("这一次的时间", selection: $newDate) }.navigationTitle("只修改这一次").toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { if let occurrence = projection?.occurrence { model.perform { try await model.commands?.rescheduleOccurrence(occurrence, to: newDate, now: model.now) }; reschedule = false } } } } }
            }
            .task(id: projection?.card.revisionID) { do { photos = try await model.repository?.attachments(cardID: cardID).filter { projection?.card.attachmentIDs.contains($0.id) == true } ?? [] } catch { model.message = error.localizedDescription } }
    }
    @ViewBuilder private var detailNavigation: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button { dismiss() } label: { Label("卡片", systemImage: "chevron.left").font(.body).frame(minHeight: 44) }
                        .accessibilityLabel("返回卡片").accessibilityIdentifier("detailBack")
                    Spacer(minLength: 12)
                    moreMenu.font(.system(size: 22))
                }
                Text(navigationTitle).font(Paper.title(18)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("detailNavigationTitle")
            }.padding(.horizontal, 16).padding(.bottom, 6)
        } else {
            PaperNavigationBar(title: navigationTitle, back: "〈 返回", action: { dismiss() }) { moreMenu }
        }
    }
    private var navigationTitle: String {
        guard let card = projection?.card else { return "卡片详情" }
        if let birthday = card.birthday { return birthday.occasion == .anniversary ? "纪念日" : "生日" }
        return card.kind == .note ? "随手记" : "待办详情"
    }
    @ViewBuilder private var moreMenu: some View {
                if let p = projection {
                    Menu {
                        Button("查看历史记录", systemImage: "clock") { history = true }
                        Button("此设备的提醒", systemImage: "bell.badge") { reminderStatus = true }
                        Button(p.card.isPinned ? "取消固定" : "固定在今天", systemImage: "pin") { var card = p.card; card.isPinned.toggle(); model.perform { _ = try await model.commands?.save(CardDraft(card: card, isEditing: true), now: model.now) } }
                        if p.card.isRepeating && p.card.lifecycle == .active && !isHistoricOccurrence(p) {
                            if p.card.recurrenceClosedAt == nil {
                                Button("本次及以后", systemImage: "calendar.badge.clock") { model.edit(p.card, from: p.occurrence) }
                                Button("关闭整个重复规则", systemImage: "repeat.circle", role: .destructive) { closesSeries = true }
                            } else {
                                Button("重新开启重复", systemImage: "repeat") { var card = p.card; card.recurrenceClosedAt = nil; model.perform { _ = try await model.commands?.save(CardDraft(card: card, isEditing: true), now: model.now) } }
                            }
                        }
                        if let occurrence = p.occurrence, p.state == .skipped && p.card.canComplete { Button("撤销跳过", systemImage: "arrow.uturn.backward") { model.perform { try await model.commands?.unskip(occurrence, now: model.now) } } }
                        if let occurrence = p.occurrence, p.state == .pending, p.card.recurrenceClosedAt == nil, !isHistoricOccurrence(p) {
                            Button("只修改这次日期", systemImage: "calendar") { newDate = occurrence.plannedAt ?? model.now; reschedule = true }
                            if p.card.canComplete { Button("跳过这一次", systemImage: "forward.end") { model.perform { try await model.commands?.skip(occurrence, now: model.now) } } }
                            if p.reminderState?.isStopped == true { Button("重新开启此设备本次提醒", systemImage: "bell") { model.perform { try await model.commands?.resumeReminder(occurrence, now: model.now) } } }
                            else { Button("停止此设备本次提醒", systemImage: "bell.slash") { model.perform { try await model.commands?.stopReminder(occurrence, now: model.now) } } }
                        }
                        if p.card.lifecycle == .active { Button("归档", systemImage: "archivebox") { model.perform { try await model.commands?.setLifecycle(card: p.card, lifecycle: .archived, now: model.now) } } }
                        if p.card.lifecycle != .deleted { Button("移到最近删除", systemImage: "trash", role: .destructive) { model.perform { try await model.commands?.setLifecycle(card: p.card, lifecycle: .deleted, now: model.now) } } }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("卡片更多操作")
                }

    }
    private func detailHero(_ p: CardProjection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let time = detailTime(p) { Text(time).font(Paper.text(32).weight(.semibold)).monospacedDigit().foregroundColor(p.card.appearance.readableInk) }
                    Text(detailDate(p)).font(Paper.text(14)).foregroundColor(p.card.appearance.readableSecondary).accessibilityIdentifier("detailPlannedDate")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(detailDate(p)).font(Paper.text(14)).foregroundColor(p.card.appearance.readableSecondary).accessibilityIdentifier("detailPlannedDate")
                    if let time = detailTime(p) { Text(time).font(Paper.text(32).weight(.semibold)).monospacedDigit().foregroundColor(p.card.appearance.readableInk) }
                }
            }
            HStack(alignment: .center, spacing: 12) {
                Text(p.card.title).font(Paper.title(27)).foregroundColor(p.card.appearance.readableInk).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                if let artwork = CardArtwork.asset(for: p.card), p.card.title.count <= 18 && p.card.appearance.backgroundAttachmentID == nil && !p.card.appearance.needsLightInk && !typeSize.isAccessibilitySize {
                    Image(artwork == "Ginkgo" ? "GinkgoBranch" : artwork).resizable().scaledToFit().frame(width: 74, height: 62)
                        .saturation(0.78).blendMode(.multiply).opacity(0.82).accessibilityHidden(true)
                }
            }
            Rectangle().fill(p.card.appearance.readableInk.opacity(0.09)).frame(height: 0.5).accessibilityHidden(true)
            CardContextLine(card: p.card, color: p.card.appearance.readableSecondary, includesRepeat: false)
            if let state = CardPresentation.pendingTimeStatus(p, now: model.now) { Text(state).font(.caption).foregroundColor(p.card.appearance.readableSecondary) }
            if p.state == .completed { Label("已完成这一次", systemImage: "checkmark.circle").font(.caption).foregroundColor(p.card.appearance.readableSecondary) }
            if p.state == .skipped { Label("已跳过这一次", systemImage: "forward.end").font(.caption).foregroundColor(p.card.appearance.readableSecondary) }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let background = photos.first(where: { $0.id == p.card.appearance.backgroundAttachmentID }), let image = UIImage(data: background.data) {
                    GeometryReader { geometry in Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                        .overlay(p.card.appearance.needsLightInk ? Color.black.opacity(0.85) : Color.white.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: Paper.radius)).accessibilityHidden(true)
                }
            }
            .paperCard(p.card.appearance.customHex.map(Color.init(hex:)) ?? Paper.card(p.card.appearance.theme))
            .overlay { RoundedRectangle(cornerRadius: Paper.radius).strokeBorder(p.card.appearance.readableInk.opacity(0.06), lineWidth: 0.5).allowsHitTesting(false) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("detailHero")
    }
    private func detailDate(_ p: CardProjection) -> String {
        guard let date = p.occurrence?.plannedAt else { return CardPresentation.timing(p) }
        let calendar = p.card.schedule?.calendar(fallback: model.calendar) ?? model.calendar
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: model.now)!
        let format = calendar.component(.year, from: date) == calendar.component(.year, from: model.now) ? "M月d日 EEE" : "yyyy年M月d日 EEE"
        return (calendar.isDate(date, inSameDayAs: tomorrow) ? "明天 · " : "") + CardPresentation.dateLabel(date, format: format, calendar: calendar)
    }
    private func detailTime(_ p: CardProjection) -> String? {
        guard p.card.schedule?.time != nil || p.card.birthday?.dayTime != nil, let date = p.occurrence?.plannedAt else { return nil }
        let calendar = p.card.schedule?.calendar(fallback: model.calendar) ?? model.calendar
        return DayTime(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date)).display
    }
    private func detailRow(_ icon: String, _ title: String, _ value: String, card: Card) -> some View {
        VStack(spacing: 0) { Divider().overlay(Paper.separator); Button { requestEdit(card) } label: { ComposerRow(symbol: icon, title: title, value: value) } }
    }
    private func requestEdit(_ card: Card) {
        if let projection, isHistoricOccurrence(projection) { return }
        if card.isRepeating && card.recurrenceClosedAt == nil && projection?.occurrence != nil { editScope = true }
        else { model.edit(card) }
    }
    private func isHistoricOccurrence(_ projection: CardProjection) -> Bool {
        projection.occurrence.map { $0.scheduleID != projection.card.schedulingID } ?? false
    }
}

private struct SnoozeReminderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projection: CardProjection
    @State private var selectedDate = Date()
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(projection.card.title).font(.headline)
                    DatePicker("稍后提醒时间", selection: $selectedDate, in: model.now..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical).accessibilityIdentifier("snoozeDatePicker")
                    Text("这一次将于 " + CardPresentation.dateLabel(selectedDate, format: "yyyy年M月d日 HH:mm") + " 提醒")
                        .font(.subheadline).accessibilityIdentifier("snoozeSelectionSummary")
                    if let dueAt = CardPresentation.deadline(projection), selectedDate > dueAt {
                        Text("选定时间已超过完成截止。稍后提醒不会修改截止时间。").font(.footnote).foregroundColor(Paper.accent)
                    }
                } footer: {
                    Text("仅调整这台设备上的本次提醒，不改变原安排、完成截止和下一次重复。仍需系统允许相应提醒方式。")
                }
                if let error { Section { PaperErrorBanner(message: error) } }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("稍后提醒")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: { if busy { ProgressView() } else { Text("确定") } }
                            .disabled(busy || selectedDate <= model.now).accessibilityIdentifier("confirmCustomSnooze")
                    }
                }
                .interactiveDismissDisabled(busy)
                .onAppear {
                    selectedDate = projection.reminderState?.snoozedUntil.flatMap { $0 > model.now ? $0 : nil } ?? model.now.addingTimeInterval(3600)
                }
        }.environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }
    private func save() {
        guard !busy, let occurrence = projection.occurrence, let commands = model.commands else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await commands.snooze(occurrence, until: selectedDate, now: model.now)
                await model.refresh(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var cardID: UUID
    var body: some View {
        NavigationStack {
            List {
                let events = model.library.events.filter { $0.cardID == cardID }.sorted { $0.happenedAt > $1.happenedAt }
                if events.isEmpty { Text("还没有处理记录。备注卡片和生日不会产生完成计数。").foregroundColor(Paper.secondary) }
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(event.snapshot.title).font(.headline)
                        Text("\(event.kind == .completed ? "完成" : event.kind == .reopened ? "撤销完成" : event.kind == .skipped ? "跳过" : "撤销跳过") · \(event.happenedAt.formatted())").font(.subheadline)
                        Text("当时分类：\(event.snapshot.category) · \(event.snapshot.importance.title)").font(.caption).foregroundColor(Paper.secondary)
                    }.padding(.vertical, 6)
                }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("历史记录").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
