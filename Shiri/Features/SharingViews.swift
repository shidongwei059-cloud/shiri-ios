import SwiftUI
import UniformTypeIdentifiers
import ShiriCore

extension UTType {
    static let shiriSchedule = UTType(exportedAs: "com.jianmutianyi.nianyi.schedule", conformingTo: .data)
    static let shiriBackup = UTType(exportedAs: "com.jianmutianyi.nianyi.backup", conformingTo: .data)
}
struct SharingCenterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var received = false
    @State private var importer = false
    @State private var selectedSession: ShareSession?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaperTabs(labels: ["我发出的", "我收到的"], selection: received ? "我收到的" : "我发出的", fillsWidth: false) { received = $0 == "我收到的" }
            Text(received ? "收到的心意，自己安排" : "发给别人，各自安排").font(Paper.text(15)).foregroundColor(Paper.secondary).padding(.top, 7)
            if received {
                ForEach(model.receivedCloudSessions.filter { session in !model.library.importLinks.contains { $0.sessionID == session.id } }) { session in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已接受的私有邀请").font(.footnote).foregroundColor(Paper.secondary)
                        CardTile(projection: CardProjection(card: session.snapshot.card, occurrence: nil), compact: true, onOpen: { model.importPackage = SharePackage(session: session) }, onComplete: nil)
                        Button("预览并决定是否添加") { model.importPackage = SharePackage(session: session) }.buttonStyle(PaperPrimaryButton())
                    }
                }
                if model.library.importLinks.isEmpty && model.receivedCloudSessions.isEmpty { PaperEmptyState(title: "还没收到新的日程", message: "打开朋友发来的拾日日程，\n确认后就能加入自己的卡片。", scene: .sharing) }
                ForEach(model.library.importLinks) { link in
                    if let card = model.library.cards.first(where: { $0.id == link.cardID }) {
                        VStack(alignment: .leading, spacing: 10) {
                            CardTile(projection: model.projections.first { $0.id == card.id } ?? CardProjection(card: card, occurrence: nil), compact: true, onOpen: { model.selectedCard = card }, onComplete: nil)
                            Label(link.feedbackConsent ? "已同意反馈 · 同步状态请查看详情" : "只加入自己的日程", systemImage: link.feedbackConsent ? "icloud" : "lock").font(.footnote).foregroundColor(Paper.secondary)
                            if link.feedbackConsent { Button("停止反馈") { model.perform { try await model.repository?.stopFeedback(link: link, now: model.now) } }.font(.footnote) }
                        }
                    } else {
                        PaperEmptyState(title: "这张日程卡片已移除", message: "曾收到的分享仍有记录，\n可以重新打开原来的日程文件。", scene: .sharing, compact: true)
                    }
                }
            } else {
                if model.shareSessions.isEmpty { PaperEmptyState(title: "把一件小事，分享给对方", message: "从下方选一张日程卡。\n对方确认添加后，可以按自己的节奏安排。", scene: .sharing) }
                ForEach(model.shareSessions) { session in
                    SharedScheduleTile(session: session) { selectedSession = session }
                }
            }
            Divider().padding(.top, 1)
            Label("仅在对方同意后，显示完成状态", systemImage: "person.badge.shield.checkmark").font(Paper.text(14)).foregroundColor(Paper.secondary).padding(.top, 2)
            if received { Button { importer = true } label: { Label("打开日程文件", systemImage: "square.and.arrow.down").font(Paper.text(14)).frame(maxWidth: .infinity).padding(12) }.paperCard(radius: 13) }
        }.fileImporter(isPresented: $importer, allowedContentTypes: [.shiriSchedule, .json]) { result in
            switch result { case .success(let url): Task { await model.openFile(url) }; case .failure(let error): model.message = error.localizedDescription }
        }.sheet(item: $selectedSession) { ShareSessionDetailView(session: $0).environmentObject(model) }
    }
    private func status(_ status: ShareSessionStatus) -> String { switch status { case .prepared: return "等待创建邀请"; case .invited: return "已创建私有邀请"; case .accepted: return "已加入反馈"; case .stopped: return "反馈已停止"; case .revoked: return "邀请已撤销" } }
}

private struct SharedScheduleTile: View {
    @EnvironmentObject private var model: AppModel
    var session: ShareSession
    var action: () -> Void
    @State private var receipts: [ReceiptEvent] = []
    @Environment(\.dynamicTypeSize) private var typeSize
    private var feedbackEnded: Bool { session.status == .stopped || session.status == .revoked || receipts.last?.kind == .feedbackStopped }
    private var completed: Bool { receipts.last?.kind == .completed }
    private var accepted: Bool { receipts.contains { $0.kind == .added } || completed }
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                if !typeSize.isAccessibilitySize, session.snapshot.card.title.count <= 26, let artwork = CardArtwork.asset(for: session.snapshot.card), session.snapshot.card.appearance.backgroundAttachmentID == nil {
                    Image(artwork == "ExhibitionTickets" ? "SharingExhibitionTickets" : artwork).resizable().scaledToFit().frame(width: 142, height: 128).saturation(0.75).opacity(0.8).blendMode(.multiply).padding(13).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("发给 " + (session.recipientLabel.isEmpty ? "一位朋友" : session.recipientLabel)).font(Paper.text(15)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 15)) }.foregroundColor(Paper.secondary)
                    Text(session.snapshot.card.title).font(Paper.title(24)).foregroundColor(Paper.cardInk)
                    Text(scheduleDate).font(Paper.text(15)).foregroundColor(Paper.cardSecondary)
                    Spacer(minLength: 18)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: feedbackEnded ? "pause.circle" : accepted ? "checkmark.circle.fill" : "paperplane").font(.system(size: 17))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feedbackEnded ? (session.status == .revoked ? "邀请已撤销" : "反馈已停止") : completed ? "对方已完成" : accepted ? "已加入自己的日程" : session.feedbackOffered ? "等待对方确认" : "已生成日程文件").font(Paper.text(15))
                            Text(feedbackEnded ? "对方的独立日程不受影响" : completed ? CardPresentation.dateLabel(receipts.last!.happenedAt, format: "M月d日 HH:mm") : accepted ? "最后已知状态 · 尚未完成" : session.feedbackOffered ? "同意后才显示完成状态" : "尚未收到对方的反馈").font(Paper.text(12)).foregroundColor(Paper.cardSecondary)
                        }
                    }.foregroundColor(feedbackEnded ? Paper.cardSecondary : completed ? Color(hex: "788365") : Paper.accent)
                }.padding(18).frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
            }.paperCard(Paper.card(session.snapshot.card.appearance.theme), radius: 16)
        }.buttonStyle(.plain).task(id: session.updatedAt) {
            #if DEBUG
            if let fixture = DevelopmentFixtures.receipts[session.id] { receipts = fixture; return }
            #endif
            if let coordinator = model.cloudCoordinator { receipts = (try? await coordinator.receipts(sessionID: session.id)) ?? [] }
        }
    }
    private var scheduleDate: String {
        guard let schedule = session.snapshot.card.schedule, let date = OccurrenceEngine(calendar: model.calendar).date(schedule.start, time: schedule.time ?? DayTime(hour: 0)) else { return "未设日期" }
        return CardPresentation.dateLabel(date, format: "M月d日 EEE") + (schedule.time.map { " " + $0.display } ?? "")
    }
}

struct SharingComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let card: Card
    var occurrence: Occurrence? = nil
    @State private var includeNote = true
    @State private var includePhotos = false
    @State private var recipient = ""
    @State private var extent = ShareExtent.entireRule
    @State private var feedback = false
    @State private var participantAddress = ""
    @State private var busy = false
    @State private var error: String?
    @State private var shareFile: SharedFile?
    @State private var addsPreviewImage = false
    @State private var previewFile: SharedFile?
    private var sharingOccurrence: Occurrence? { occurrence ?? model.projections.first { $0.id == card.id }?.occurrence }
    private var previewSnapshot: Result<SharedCardSnapshot, Error> {
        Result { try Self.makeSnapshot(card: card, occurrence: sharingOccurrence, attachments: [], extent: extent, includeNote: includeNote, includePhotos: false) }
    }
    private var hasValidPreview: Bool {
        if case .success = previewSnapshot { return true }
        return false
    }
    /// Preview and export use the same selected instance. Never combine an old rule's
    /// occurrence with the current card or silently turn “only this time” into a series.
    static func makeSnapshot(card: Card, occurrence: Occurrence?, attachments: [Attachment], extent: ShareExtent, includeNote: Bool, includePhotos: Bool) throws -> SharedCardSnapshot {
        if let occurrence {
            guard occurrence.cardID == card.id, occurrence.scheduleID == card.schedulingID else {
                throw ShiriError.conflict("这一次来自旧安排，请返回卡片库打开现行规则后再分享。")
            }
        }
        if extent == .currentOccurrence && card.isRepeating {
            guard occurrence?.plannedAt != nil else { throw ShiriError.validation("当前没有可分享的本次安排，请选择分享整个重复日程。") }
        }
        return SharedCardSnapshot(card: card, attachments: attachments, occurrence: occurrence, extent: extent, includeNote: includeNote, includePhotos: includePhotos)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PaperPageHeader(title: "分享这件事", subtitle: "对方安装拾日后，可以确认并加入自己的日程。", symbol: "paperplane")
                    switch previewSnapshot {
                    case .success(let snapshot):
                        CardTile(projection: CardProjection(card: snapshot.card, occurrence: sharingOccurrence), compact: true, onOpen: {}, onComplete: nil)
                    case .failure(let error):
                        PaperErrorBanner(message: error.localizedDescription)
                    }
                    PaperFieldSection("分享的内容") {
                        TextField("给谁（仅用于自己的分享记录）", text: $recipient)
                        Toggle("包含备注", isOn: $includeNote)
                        Toggle("包含图片", isOn: $includePhotos).disabled(card.attachmentIDs.isEmpty)
                        Toggle("附带一张预览图", isOn: $addsPreviewImage)
                        Text(addsPreviewImage ? "无需安装拾日就能查看预览图。图片显示标题、日期和选中的备注，完整规则及所选照片保存在日程文件中。" : "对方还没有拾日？可以附带预览图，让对方直接查看。导入日程需要先在 App Store 购买并安装拾日。").font(.footnote).foregroundColor(Paper.secondary)
                        if card.isRepeating { Picker("重复日程", selection: $extent) { ForEach(ShareExtent.allCases, id: \.self) { Text($0.title) } } }
                    }
                    PaperFieldSection("完成反馈（可选）") {
                        Toggle("邀请对方反馈处理状态", isOn: $feedback).disabled(!model.cloudFeedbackAvailable)
                        if feedback { TextField("这位接收者的 iCloud 邮箱", text: $participantAddress).textInputAutocapitalization(.never).keyboardType(.emailAddress) }
                        Text(model.cloudFeedbackAvailable ? "双方需要可用的 iCloud，且对方同意。每位接收者使用单独的私有邀请。" : "普通日程文件可以直接分享。完成反馈需要可用的 iCloud 服务，请先在设置中检查连接。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                    if let error { PaperErrorBanner(message: error) }
                    Text("仅导出以上选中的卡片内容。对方添加后的副本不会随你之后的编辑、完成或删除而改变。").font(.footnote).foregroundColor(Paper.secondary)
                    Button { prepare() } label: { if busy { ProgressView().tint(.white) } else { Label(feedback ? "创建私有反馈邀请" : "生成并分享日程", systemImage: "square.and.arrow.up") } }.buttonStyle(PaperPrimaryButton()).disabled(busy || !hasValidPreview)
                }.padding(18)
            }.background(Paper.background).navigationTitle("分享日程").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .sheet(item: $shareFile) { file in SystemShareSheet(items: previewFile.map { [file.url, $0.url] } ?? [file.url]) }
        }
    }
    private func prepare() {
        busy = true
        let selectedOccurrence = sharingOccurrence
        let selectedExtent = extent, sharesNote = includeNote, sharesPhotos = includePhotos
        Task {
            do {
                let attachments = sharesPhotos ? try await model.repository?.attachments(cardID: card.id).filter { card.attachmentIDs.contains($0.id) } ?? [] : []
                let snapshot = try Self.makeSnapshot(card: card, occurrence: selectedOccurrence, attachments: attachments, extent: selectedExtent, includeNote: sharesNote, includePhotos: sharesPhotos)
                var session = ShareSession(snapshot: snapshot, recipientLabel: recipient, feedback: feedback, now: model.now)
                if feedback { session = try await model.prepareCloudShare(session, participantAddress: participantAddress) }
                let package = SharePackage(session: session)
                let data = try FileTransport.encode(package)
                guard data.count <= AppLimits.shareBytes else { throw ShiriError.invalidFile("分享文件较大，请减少图片后重试") }
                let file = try SharedFile.write(data, extension: "nianyi")
                previewFile = nil
                if addsPreviewImage {
                    let content = SchedulePreviewImage(snapshot: snapshot).frame(width: 360).padding(22).background(Color(hex: "F7F5EF")).environment(\.colorScheme, .light)
                    let renderer = ImageRenderer(content: content); renderer.scale = 3
                    guard let image = renderer.uiImage?.pngData() else { throw ShiriError.unavailable("预览图暂时无法生成，可以关闭预览图后再分享日程") }
                    previewFile = try SharedFile.write(image, extension: "png")
                }
                try await model.repository?.saveLocalShareSession(session); await model.refresh(); shareFile = file
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

private struct SchedulePreviewImage: View {
    var snapshot: SharedCardSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("拾日").font(Paper.title(25)); Spacer(); Image(systemName: "paperplane") }
            Text(CardPresentation.timing(CardProjection(card: snapshot.card, occurrence: nil))).font(.subheadline).foregroundColor(Paper.cardSecondary)
            Text(snapshot.card.title).font(Paper.title(30)).fixedSize(horizontal: false, vertical: true)
            if !snapshot.card.note.isEmpty { Text(snapshot.card.note).font(.body).lineSpacing(5).lineLimit(8) }
            if let rule = snapshot.card.schedule, rule.frequency != .never { Text(rule.frequency.title).font(.subheadline) }
            Text("打开随附的日程文件，确认完整安排后加入自己的拾日。").font(.footnote).foregroundColor(Paper.cardSecondary)
        }.foregroundColor(Paper.cardInk).padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Paper.card(snapshot.card.appearance.theme), in: RoundedRectangle(cornerRadius: 22))
    }
}

struct ReceiveScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var package: SharePackage
    @State private var draft: CardDraft
    @State private var feedback = false
    @State private var allowsDuplicate = false
    @State private var error: String?
    @State private var busy = false
    init(package: SharePackage) {
        self.package = package
        let (card, attachments) = package.independentCopy(now: Date(), scope: .local)
        var draft = CardDraft(card: card); draft.attachments = attachments
        _draft = State(initialValue: draft)
    }
    @State private var showsReminder = false
    @State private var showsEdit = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PaperNavigationBar(title: "收到的日程", back: "关闭", action: { dismiss() }) { EmptyView() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            Text(String(package.senderLabel.prefix(1))).font(Paper.title(18)).frame(width: 47, height: 47).background(Color(hex: "DADDCC"), in: Circle())
                            (Text(package.senderLabel).fontWeight(.semibold) + Text(" 发给你").foregroundColor(Paper.secondary)).font(Paper.text(17))
                            Spacer()
                        }.padding(.horizontal, 4).padding(.top, 10)
                        ZStack(alignment: .bottomTrailing) {
                            if !typeSize.isAccessibilitySize, draft.card.title.count <= 26, let artwork = CardArtwork.asset(for: draft.card), draft.card.appearance.backgroundAttachmentID == nil {
                                Image(artwork).resizable().scaledToFit().frame(width: 125, height: 108).saturation(0.75).opacity(0.8).blendMode(.multiply).padding(15).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                Text(receivedDate).font(Paper.text(15)).foregroundColor(Paper.accent)
                                Text(draft.card.title).font(Paper.title(29)).foregroundColor(Paper.cardInk)
                                if let time = draft.card.schedule?.time { Label(time.display, systemImage: "clock").font(Paper.text(17)).foregroundColor(Paper.cardSecondary) }
                                if let place = draft.card.place { Label(place.name, systemImage: "mappin.and.ellipse").font(Paper.text(16)).foregroundColor(Paper.cardSecondary) }
                                else if !draft.card.note.isEmpty { Text(draft.card.note).font(Paper.text(15)).foregroundColor(Paper.cardSecondary).lineLimit(2).padding(.trailing, 85) }
                                Spacer(minLength: 7)
                            }.padding(20).frame(maxWidth: .infinity, minHeight: 193, alignment: .topLeading)
                        }.paperCard(Paper.card(draft.card.appearance.theme), radius: 16)
                        VStack(spacing: 0) {
                            Divider()
                            Button { showsReminder = true } label: { ComposerRow(symbol: "bell", title: "我的提醒", value: myReminder) }.frame(minHeight: 58)
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("告知对方完成状态", isOn: $feedback).font(Paper.title(18)).disabled(!model.canAcceptFeedback(package.sessionID))
                            Text(model.canAcceptFeedback(package.sessionID) ? "开启后，对方可以看到你是否完成。\n可随时关闭，不会分享你的修改内容。" : "先打开对方的 iCloud 邀请并接受，再回来开启。\n也可以直接加入日程，不反馈处理状态。")
                                .font(Paper.text(15)).foregroundColor(Paper.secondary).lineSpacing(5)
                        }
                        if let url = package.feedbackURL, !model.canAcceptFeedback(package.sessionID) { Link("第 1 步：打开并接受 iCloud 邀请", destination: url).font(Paper.text(14)).frame(minHeight: 44)
                            Text("第 2 步：回到拾日，再选择是否告知完成状态。").font(.footnote).foregroundColor(Paper.secondary) }
                        if package.feedbackURL == nil && !model.canAcceptFeedback(package.sessionID) { Text("这份日程没有附带反馈邀请。如需反馈，请对方另发 iCloud 邀请；现在就可以加入独立日程。").font(.footnote).foregroundColor(Paper.secondary).accessibilityIdentifier("feedbackUnavailableReason") }
                        if model.library.importLinks.contains(where: { $0.sessionID == package.sessionID }) { Toggle("仍然再添加一份独立副本", isOn: $allowsDuplicate).font(Paper.text(15)) }
                        Button("调整这份日程") { showsEdit = true }.font(Paper.text(13)).foregroundColor(Paper.secondary)
                        if let error { PaperErrorBanner(message: error) }
                    }.padding(.horizontal, 16).padding(.bottom, 14)
                }
                VStack(alignment: .leading, spacing: 28) {
                    Label("加入后是一张独立卡片，你可以自行修改。", systemImage: "note.text").font(Paper.text(14)).foregroundColor(Paper.secondary)
                    Button { add() } label: { if busy { ProgressView().tint(.white) } else { Text("加入我的日程") } }.buttonStyle(PaperPrimaryButton()).disabled(busy).accessibilityIdentifier("acceptSchedule")
                }.padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 10)
            }.background { PaperSurface().ignoresSafeArea() }.foregroundColor(Paper.ink).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showsReminder) { ReminderEditor(card: $draft.card) }
                .sheet(isPresented: $showsEdit) {
                    NavigationStack { Form { TextField("事项标题", text: $draft.card.title, axis: .vertical); TextField("备注", text: $draft.card.note, axis: .vertical) }.navigationTitle("调整这份日程").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsEdit = false } } } }
                }
        }
    }
    private var receivedDate: String {
        guard let rule = draft.card.schedule, let date = OccurrenceEngine(calendar: model.calendar).date(rule.start, time: rule.time ?? DayTime(hour: 0)) else { return "未设日期" }
        return CardPresentation.dateLabel(date, format: "M月d日 EEE")
    }
    private var myReminder: String {
        guard draft.card.reminders.isEnabled else { return "不提醒" }
        let advance = draft.card.reminders.advanceMinutes.filter { $0 > 0 }.sorted().first
        return advance.map { "提前 \($0) 分钟" } ?? "准时通知"
    }
    private func add() {
        busy = true
        Task {
            do {
                let card = try await model.commands?.importPackage(package, draft: draft, allowsDuplicate: allowsDuplicate, feedbackConsent: feedback, now: model.now)
                await model.refresh(); dismiss(); model.selectedCard = card
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct ShareSessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var session: ShareSession
    @State private var file: SharedFile?
    @State private var receipts: [ReceiptEvent] = []
    @State private var pending: [ReceiptOutboxItem] = []
    @State private var statusError: String?
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 22) {
                PaperPageHeader(title: "这份分享", subtitle: session.recipientLabel.isEmpty ? "日程的独立副本" : "给 \(session.recipientLabel)", symbol: "paperplane")
                CardTile(projection: CardProjection(card: session.snapshot.card, occurrence: nil), compact: true, onOpen: {}, onComplete: nil)
                Text(session.feedbackOffered ? "完成反馈显示的是最后已知状态。对方离线时可能尚未同步。" : "通过文件分享时，无法查看对方是否收到、添加或完成日程。").font(.body).foregroundColor(Paper.secondary).lineSpacing(5)
                if session.feedbackOffered {
                    PaperFieldSection("最后已知反馈") {
                        if let statusError { Text(statusError).font(.subheadline).foregroundColor(Paper.accent) }
                        if receipts.isEmpty { Text("尚未收到可确认的反馈。对方可能尚未添加，也可能离线。").font(.subheadline).foregroundColor(Paper.secondary) }
                        ForEach(Array(Set(receipts.compactMap(\.semanticKey))).sorted(), id: \.self) { key in
                            Text("\(key) · \(feedbackState(key))").font(.subheadline)
                        }
                        ForEach(receipts.suffix(20).reversed()) { receipt in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(receiptTitle(receipt.kind))
                                if let key = receipt.semanticKey { Text(key).font(.caption).foregroundColor(Paper.secondary) }
                                Text("操作时间：\(receipt.happenedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundColor(Paper.secondary)
                            }
                        }
                        Text(model.cloudStatus).font(.caption).foregroundColor(Paper.secondary)
                        ForEach(pending) { item in Text(item.lastError ?? "这条反馈等待本机写入分享区").font(.caption).foregroundColor(Paper.accent) }
                        Button("刷新反馈") { Task { await readFeedback() } }
                    }
                    if let url = session.shareURL { Link("打开私有邀请链接", destination: url) }
                }
                Button("再次打开分享") { model.perform { file = try SharedFile.write(FileTransport.encode(SharePackage(session: session)), extension: "nianyi") } }.buttonStyle(PaperPrimaryButton())
                if session.feedbackOffered { Button("撤销完成反馈邀请", role: .destructive) { model.perform { try await model.revokeCloudShare(session); dismiss() } } }
            }.padding(18) }.background(Paper.background).navigationTitle("分享详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }.sheet(item: $file) { SystemShareSheet(items: [$0.url]) }.task { await readFeedback() }
        }
    }
    private func receiptTitle(_ kind: ReceiptEvent.Kind) -> String {
        switch kind { case .added: return "对方已添加到自己的日程"; case .completed: return "对方已标记完成"; case .reopened: return "对方已撤销完成"; case .feedbackStopped: return "对方已停止后续反馈" }
    }
    private func feedbackState(_ key: String?) -> String {
        switch ReceiptReducer.state(receipts, semanticKey: key) {
        case .unknown: return "状态待确认"
        case .added: return "已添加"
        case .pending: return "未完成（已撤销）"
        case .completed: return "已完成"
        case .stopped: return "已停止反馈"
        }
    }
    private func readFeedback() async {
        do {
            guard session.feedbackOffered, let coordinator = model.cloudCoordinator else { return }
            receipts = try await coordinator.receipts(sessionID: session.id)
            pending = try await model.repository?.outbox().filter { $0.receipt.sessionID == session.id } ?? []
            statusError = nil
        } catch { statusError = error.localizedDescription }
    }

}

final class SharedFile: Identifiable {
    let id = UUID()
    let url: URL
    private init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
    static func write(_ data: Data, extension suffix: String) throws -> SharedFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NianYiExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("拾日-\(UUID().uuidString.prefix(8)).\(suffix)")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]); return SharedFile(url: url)
    }
}
struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
