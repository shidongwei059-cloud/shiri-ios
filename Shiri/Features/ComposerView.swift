import SwiftUI
import ShiriCore

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State var draft: CardDraft
    @State private var rawText = ""
    @State private var initialDraft: CardDraft?
    @State private var autoSave: Task<Void, Never>?
    @State private var ambiguityConfirmed = false
    @State private var error: String?
    @State private var isSaving = false
    @State private var moreDrafts: [CardDraft] = []
    @State private var showsCancelChoice = false
    @State private var showsBirthday = false
    @State private var showsAppearance = false
    @State private var showsReminders = false
    @State private var showsSchedule = false
    @State private var showsPlace = false
    @State private var showsMedia = false
    @State private var showsSpeech = false
    @State private var showsMore = false
    @State private var showsScreenshot = false
    @State private var keyboardVisible = false
    @State private var lastParsedText = ""
    @State private var savesAfterBirthday = false
    @State private var savesAfterSpeech = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PaperNavigationBar(title: draft.isEditing ? "编辑卡片" : "记一件事", action: cancel) { EmptyView() }
                if model.pendingComposerInput != nil || model.pendingVoiceDraftID != nil {
                    HStack {
                        Text(model.pendingVoiceDraftID != nil ? "先保存或关闭当前卡片，随后核对语音草稿。" : model.pendingComposerInput == .voice ? "先保存或关闭当前卡片，随后打开语音待办。" : "先保存或关闭当前卡片，随后开始新的记录。")
                        Button("取消新增") { model.cancelPendingComposer() }
                    }.font(.footnote).padding(12).background(Paper.accent.opacity(0.08)).accessibilityIdentifier("pendingComposerNotice")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !draft.isEditing {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("想记住什么？").font(Paper.text(15)).foregroundColor(Paper.secondary)
                                TextField("明天下午三点，\n提醒我去取快递", text: $rawText, axis: .vertical)
                                    .font(Paper.title(28)).lineLimit(2...3).focused($inputFocused).accessibilityIdentifier("quickInput")
                                    .foregroundColor(highlightedInput != nil && !inputFocused ? .clear : Paper.ink)
                                    .overlay(alignment: .topLeading) {
                                        if !inputFocused, let highlightedInput { highlightedInput.font(Paper.title(28)).fixedSize(horizontal: false, vertical: true).allowsHitTesting(false).accessibilityHidden(true) }
                                    }.padding(.vertical, -3)
                                HStack {
                                    Button { inputFocused = false; showsMedia = true } label: { Label("添加图片", systemImage: "photo") }
                                    Spacer()
                                    Button { inputFocused = false; showsSpeech = true } label: { Label("语音输入", systemImage: "mic") }
                                }.font(Paper.text(14)).foregroundColor(Paper.secondary).frame(minHeight: 34)
                                if !rawText.isEmpty && rawText != lastParsedText {
                                    Button("识别安排") { interpret(); inputFocused = false }.font(.subheadline).frame(maxWidth: .infinity, alignment: .trailing).accessibilityIdentifier("parseInput")
                                }
                            }.padding(.horizontal, 5).padding(.top, 0)
                            Divider().padding(.vertical, 1)
                        }
                        if let error { PaperErrorBanner(message: error) }
                        if !draft.questions.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(draft.questions) { question in Label(question.message, systemImage: "info.circle").font(.footnote).foregroundColor(Paper.accent) }
                                Toggle("我已逐项检查以上提示与下面的安排", isOn: $ambiguityConfirmed).font(.footnote)
                            }
                        }
                        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                            Button("待办") { draft.card.kind = .task }.buttonStyle(.bordered).tint(draft.card.kind == .task ? Paper.accent : Paper.secondary).disabled(draft.card.birthday != nil).accessibilityAddTraits(draft.card.kind == .task && draft.card.birthday == nil ? .isSelected : []).accessibilityIdentifier("composerKind_task")
                            Button("随手记") { draft.card.kind = .note }.buttonStyle(.bordered).tint(draft.card.kind == .note && draft.card.birthday == nil ? Paper.accent : Paper.secondary).disabled(draft.card.birthday != nil).accessibilityAddTraits(draft.card.kind == .note && draft.card.birthday == nil ? .isSelected : []).accessibilityIdentifier("composerKind_note")
                            Button("重要日子") { inputFocused = false; showsBirthday = true }.buttonStyle(.bordered).tint(draft.card.birthday != nil ? Paper.accent : Paper.secondary).accessibilityAddTraits(draft.card.birthday != nil ? .isSelected : []).accessibilityIdentifier("composerKind_occasion")
                        }.font(.subheadline)
                        Text(draft.card.kind == .note ? "确认内容" : "确认安排").font(Paper.title(18)).padding(.horizontal, 5)
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                PaperSymbol("note.text").frame(width: 26)
                                Text("标题"); Spacer(minLength: 8)
                                TextField("写下这件事", text: $draft.card.title, axis: .vertical).multilineTextAlignment(.trailing).accessibilityIdentifier("cardTitle")
                            }.font(Paper.text(16)).padding(.horizontal, 17).frame(minHeight: 47)
                            Divider().padding(.leading, 12)
                            if draft.card.birthday != nil {
                                Button { inputFocused = false; showsBirthday = true } label: { ComposerRow(symbol: "birthday.cake", title: "重要日子", value: birthdaySummary) }
                            } else {
                                QuickScheduleFields(card: $draft.card,
                                    openSchedule: { inputFocused = false; showsSchedule = true },
                                    openReminders: { inputFocused = false; showsReminders = true })
                                    .padding(.horizontal, 17).padding(.vertical, 10)
                            }
                        }.paperCard(radius: 13)
                        TextField("给未来的自己留句话…", text: $draft.card.note, axis: .vertical).lineLimit(3...6).font(.body).padding(14).paperCard(radius: 13).accessibilityIdentifier("composerNote")
                        DisclosureGroup("更多设置", isExpanded: $showsMore) { moreSettings }
                            .font(.subheadline).padding(14).paperCard(radius: 13)
                        if !draft.isEditing {
                            Button { inputFocused = false; showsScreenshot = true } label: { Label("截图变卡片", systemImage: "text.viewfinder").frame(minHeight: 44) }.font(.subheadline).accessibilityIdentifier("screenshotImport")
                        }
                        if !moreDrafts.isEmpty { Text("这段话还识别到 \(moreDrafts.count) 件事，保存后可以分别确认。").font(.footnote).foregroundColor(Paper.secondary) }
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("composerScroll")
                VStack(alignment: .leading, spacing: 8) {
                    if !keyboardVisible { Text(draft.card.reminders.isEnabled ? "保存后可查看提醒是否已开启" : "先把事情留下，时间可以以后再安排").font(Paper.text(12)).foregroundColor(Paper.secondary) }
                    Button { save() } label: { if isSaving { ProgressView().tint(.white) } else { Text(draft.isEditing ? "保存修改" : (draft.card.reminders.isEnabled ? "保存提醒" : "保存卡片")) } }.buttonStyle(PaperPrimaryButton()).disabled(isSaving).accessibilityIdentifier("saveCard")
                }.padding(.horizontal, 16).padding(.bottom, 8).padding(.top, 4)
            }.background { PaperSurface().ignoresSafeArea() }.foregroundColor(Paper.ink).toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    let isFirstAppearance = initialDraft == nil
                    if isFirstAppearance { initialDraft = draft; rawText = draft.originalText; lastParsedText = draft.interpretedText ?? ""; moreDrafts = draft.additionalDrafts ?? [] }
                    if model.startsOccasionEditor { model.startsOccasionEditor = false; inputFocused = false; showsBirthday = true }
                    else if model.startsWithSpeech { model.startsWithSpeech = false; showsSpeech = true }
                    else if isFirstAppearance && !draft.isEditing && draft.card.title.isEmpty && rawText.isEmpty && draft.card.note.isEmpty && draft.attachments.isEmpty { inputFocused = true }
                    #if DEBUG
                    if model.startsBirthdayEditor { model.startsBirthdayEditor = false; showsBirthday = true }
                    if let editor = model.startsEditor {
                        model.startsEditor = nil
                        switch editor {
                        case "place": showsPlace = true
                        case "appearance": showsAppearance = true
                        case "media": showsMedia = true
                        case "reminders": showsReminders = true
                        case "speech": showsSpeech = true
                        case "screenshot": showsScreenshot = true
                        default: break
                        }
                    }
                    #endif
                }
                .onChange(of: rawText) { _ in scheduleDraftSave() }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
                .onChange(of: draft) { _ in scheduleDraftSave() }
                .onChange(of: scenePhase) { phase in if phase != .active { scheduleDraftSave(immediately: true) } }
                .interactiveDismissDisabled(initialDraft.map { $0 != draft || $0.originalText != rawText } ?? false)
                .confirmationDialog("保留这次输入？", isPresented: $showsCancelChoice, titleVisibility: .visible) {
                    Button("保存为草稿") { finishDraft(keeping: true) }
                    Button("放弃编辑", role: .destructive) { finishDraft(keeping: false) }
                    Button("继续编辑", role: .cancel) {}
                }
                .sheet(isPresented: $showsScreenshot) { ScreenshotImportView(existingImages: draft.attachments, onUse: useScreenshot) }
                .sheet(isPresented: $showsSchedule) { ScheduleEditor(card: $draft.card).environmentObject(model) }
                .sheet(isPresented: $showsReminders) { ReminderEditor(card: $draft.card) }
                .sheet(isPresented: $showsAppearance) { AppearanceEditor(draft: $draft) }
                .fullScreenCover(isPresented: $showsBirthday, onDismiss: { if savesAfterBirthday { savesAfterBirthday = false; save() } }) { BirthdayEditor(card: $draft.card, onSave: { savesAfterBirthday = true }).environmentObject(model) }
                .sheet(isPresented: $showsPlace) { PlaceEditor(card: $draft.card) }
                .sheet(isPresented: $showsMedia) { MediaEditor(draft: $draft) }
                .sheet(isPresented: $showsSpeech, onDismiss: {
                    if savesAfterSpeech { savesAfterSpeech = false; save() }
                }) {
                    SpeechInputView(allowsDirectCreation: canCreateFromSpeech) { text, confirmed in
                        rawText = text
                        if interpret() { savesAfterSpeech = confirmed && draft.questions.isEmpty && moreDrafts.isEmpty }
                    }
                }
        }
    }
    private var canCreateFromSpeech: Bool {
        !draft.isEditing && rawText.isEmpty && draft.card.title.isEmpty && draft.card.note.isEmpty
            && draft.attachments.isEmpty && initialDraft == draft
    }
    private func useScreenshot(_ proposed: CardDraft, _ image: Attachment?) throws {
        var copy = draft
        if var image, !copy.attachments.contains(where: { $0.digest == image.digest }) {
            guard copy.attachments.count < AppLimits.attachmentCount else { throw ShiriError.validation("图片已达 6 张，请关闭保留原图或先移除一张") }
            image.cardID = copy.card.id; image.sortIndex = copy.attachments.count
            copy.attachments.append(image); copy.card.attachmentIDs = copy.attachments.map(\.id)
        }
        copy.card.title = proposed.card.title
        if copy.card.birthday == nil {
            copy.card.schedule = proposed.card.schedule
            let liveActivity = copy.card.reminders.enablesLiveActivity
            let scheduledActivity = copy.card.reminders.scheduledLiveActivity
            copy.card.reminders = proposed.card.reminders
            copy.card.reminders.enablesLiveActivity = liveActivity
            copy.card.reminders.scheduledLiveActivity = scheduledActivity
        }
        copy.card.note = copy.card.note.isEmpty ? proposed.card.note : copy.card.note + "\n\n截图文字：\n" + proposed.card.note
        guard copy.card.note.count <= AppLimits.noteLength else { throw ShiriError.validation("原备注与截图文字合计超过 2,000 字，请先精简识别文字") }
        copy.questions = proposed.questions; copy.originalText = proposed.originalText; copy.interpretedText = proposed.interpretedText
        draft = copy; rawText = copy.originalText; lastParsedText = rawText; ambiguityConfirmed = false
    }
    private func cancel() {
        if initialDraft.map({ $0 == draft && $0.originalText == rawText }) == true { autoSave?.cancel(); dismiss() }
        else { showsCancelChoice = true }
    }
    private var highlightedInput: Text? {
        guard rawText == lastParsedText, draft.card.schedule?.time != nil, draft.questions.isEmpty,
              let range = rawText.range(of: "(?:上午|下午|晚上|早上|中午)?[零〇一二三四五六七八九十两0-9]+(?:点(?:半|[零〇一二三四五六七八九十两0-9]+分?)?|[:：][0-9]{2})", options: .regularExpression) else { return nil }
        return Text(String(rawText[..<range.lowerBound])) + Text(String(rawText[range])).underline(true, color: Paper.accent.opacity(0.55)) + Text(String(rawText[range.upperBound...]))
    }
    private var scheduleDate: String {
        guard let schedule = draft.card.schedule, let date = OccurrenceEngine(calendar: model.calendar).date(schedule.start, time: schedule.time ?? DayTime(hour: 0)) else { return "不设日期" }
        return CardPresentation.dateLabel(date, format: "M月d日 EEE")
    }
    private var reminderLabel: String {
        draft.card.reminders.isEnabled ? draft.card.reminders.channel.title + " · " + draft.card.reminders.nodesSummary : "不提醒"
    }
    private var moreSettings: some View {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("重要程度"); Spacer()
                        Picker("重要程度", selection: $draft.card.importance) { ForEach(Importance.allCases, id: \.self) { Text($0.title) } }.labelsHidden()
                    }
                    TextField("分类", text: $draft.card.category)
                    Toggle("固定在今天", isOn: $draft.card.isPinned)
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack { Text("纸张颜色"); Spacer(); themeChoices }
                        VStack(alignment: .leading) { Text("纸张颜色"); themeChoices }
                    }
                    Button { inputFocused = false; showsAppearance = true } label: { Label("插画与自定义外观", systemImage: "paintpalette").frame(minHeight: 44) }.accessibilityIdentifier("composerAppearance")
                    Button { inputFocused = false; showsPlace = true } label: { Label(draft.card.place.map { "\($0.trigger.title) · \($0.name)" } ?? "设置地点提醒", systemImage: "mappin.and.ellipse").frame(minHeight: 44) }
                    Button { inputFocused = false; showsMedia = true } label: { Label("管理图片（\(draft.attachments.count)/6）", systemImage: "photo.on.rectangle").frame(minHeight: 44) }
                }.padding(.top, 12)
    }
    private var themeChoices: some View {
        HStack(spacing: 4) {
            ForEach(CardTheme.allCases, id: \.self) { theme in
                Button {
                    draft.card.appearance.theme = theme; draft.card.appearance.customHex = nil
                    draft.card.appearance.overriddenFields.insert("theme")
                } label: {
                    Circle().fill(Paper.card(theme)).frame(width: 24, height: 24)
                        .overlay { if draft.card.appearance.theme == theme && draft.card.appearance.customHex == nil { Circle().stroke(Paper.accent, lineWidth: 2).padding(-3) } }
                        .frame(width: 40, height: 44)
                }.accessibilityLabel(theme.title).accessibilityIdentifier("quickTheme_" + theme.rawValue)
            }
        }
    }
    private var birthdaySummary: String { guard let b = draft.card.birthday else { return "请选择" }; return "\(b.calendar?.title ?? "选择历法") \(b.month)月\(b.day)日" }
    private var preview: CardProjection {
        var card = draft.card; if card.title.isEmpty { card.title = "一件值得记住的小事" }
        let occurrence = OccurrenceEngine(calendar: model.calendar).next(for: card, after: model.calendar.startOfDay(for: model.now))
        return CardProjection(card: card, occurrence: occurrence)
    }
    @discardableResult private func interpret() -> Bool {
        do {
            var parsed = try ChineseCardParser(calendar: model.calendar).interpret(rawText, now: model.now, defaultTime: model.preferences.defaultReminderTime, places: model.library.cards.compactMap(\.place))
            for index in parsed.indices {
                parsed[index].card.reminders.enablesLiveActivity = draft.card.reminders.enablesLiveActivity
                parsed[index].card.reminders.scheduledLiveActivity = draft.card.reminders.scheduledLiveActivity
            }
            guard var first = parsed.first else { return false }
            first.card.id = draft.card.id; first.id = draft.id; first.attachments = draft.attachments
            first.card.attachmentIDs = draft.card.attachmentIDs
            first.card.appearance = draft.card.appearance
            first.card.appearance.applyRecommendation(.recommended(for: first.card.title, kind: first.card.kind, birthday: first.card.birthday != nil))
            first.card.scope = draft.card.scope
            first.card.createdAt = draft.card.createdAt
            first.card.occasionLink = draft.card.occasionLink; first.card.memoryDate = draft.card.memoryDate
            first.card.importance = draft.card.importance; first.card.category = draft.card.category; first.card.isPinned = draft.card.isPinned
            if draft.card.kind == .note { first.card.kind = .note }
            if let birthday = draft.card.birthday { first.card.birthday = birthday; first.card.schedule = nil; first.card.kind = .note }
            first.card.reminders.enablesLiveActivity = draft.card.reminders.enablesLiveActivity
            first.card.reminders.scheduledLiveActivity = draft.card.reminders.scheduledLiveActivity
            if !draft.card.note.isEmpty { first.card.note = draft.card.note }
            first.interpretedText = rawText
            first.additionalDrafts = Array(parsed.dropFirst())
            draft = first; lastParsedText = rawText; ambiguityConfirmed = false; moreDrafts = Array(parsed.dropFirst()); error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func scheduleDraftSave(immediately: Bool = false) {
        guard !isSaving else { return }
        autoSave?.cancel()
        guard initialDraft.map({ $0 != draft || $0.originalText != rawText }) == true else { return }
        guard !rawText.isEmpty || !draft.card.title.isEmpty || !draft.card.note.isEmpty || !draft.attachments.isEmpty else { return }
        var copy = draft; copy.originalText = rawText; copy.updatedAt = model.now; copy.additionalDrafts = moreDrafts
        autoSave = Task {
            do { if !immediately { try await Task.sleep(nanoseconds: 600_000_000) }; try Task.checkCancellation(); try await model.repository?.saveDraft(copy) }
            catch is CancellationError { }
            catch { self.error = "草稿暂存未完成：\(error.localizedDescription)" }
        }
    }
    private func finishDraft(keeping: Bool) {
        autoSave?.cancel(); let pendingSave = autoSave; isSaving = true
        Task {
            await pendingSave?.value
            do {
                if keeping { draft.originalText = rawText; draft.updatedAt = model.now; try await model.repository?.saveDraft(draft) }
                else { try await model.repository?.deleteDeviceRecord(entity: "DraftRecord", id: draft.id) }
                dismiss()
            } catch { self.error = error.localizedDescription; isSaving = false }
        }
    }
    private func save() {
        guard !isSaving else { return }
        if !draft.isEditing && !rawText.isEmpty && rawText != lastParsedText {
            if interpret() { error = "已更新识别结果，请校对安排后再次保存"; inputFocused = false }
            return
        }
        if draft.card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !draft.card.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty {
            draft.card.title = draft.card.note.split(separator: "\n").first.map { String($0.prefix(AppLimits.titleLength)) } ?? "图片记事"
            inputFocused = false; error = "已建议标题，请确认或修改后再次保存"; return
        }
        guard draft.questions.isEmpty || ambiguityConfirmed else { error = "请先检查解析提示，并确认下面的安排"; return }
        autoSave?.cancel(); let pendingSave = autoSave; isSaving = true
        Task {
            await pendingSave?.value
            do {
                draft.originalText = rawText
                for other in moreDrafts { try await model.repository?.saveDraft(other) }
                try await model.save(draft)
                if !moreDrafts.isEmpty { model.message = "已保存第一件事，其余 \(moreDrafts.count) 件已放入草稿箱，请分别确认。" }
                dismiss()
            } catch { self.error = error.localizedDescription }
            isSaving = false
        }
    }
}

struct ComposerRow: View {
    var symbol: String
    var title: String
    var value: String
    var body: some View {
        HStack(spacing: 12) {
            PaperSymbol(symbol).frame(width: 26)
            Text(title); Spacer(minLength: 10)
            Text(value).foregroundColor(Paper.secondary).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Paper.secondary)
        }.font(Paper.text(16)).foregroundColor(Paper.ink).padding(.horizontal, 17).padding(.vertical, 10).frame(minHeight: 47)
    }
}
