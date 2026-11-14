import SwiftUI
import ShiriCore

struct MemoryComposerView: View {
    var occasionID: UUID?
    var initialDate: Date
    var source: MemoryCandidate?
    var editing: Card?
    var previous: Card?
    var restoring: CardDraft?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var editor = MemoryEditorState()
    @State private var discarding = false
    @State private var dictation = false
    @State private var selectingDate = false
    @State private var saved: Card?
    @State private var photoBusy = false
    @FocusState private var focus: String?
    private var date: Binding<Date> {
        Binding(get: { editor.draft.card.memoryDate ?? initialDate }, set: { editor.draft.card.memoryDate = $0 })
    }
    private var pendingSpeech: Bool { !(editor.draft.memorySpeechText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var themes: [String] {
        let defaults = ["生活", "家人", "朋友", "旅行", "成长", "工作", "重要日子"]
        return defaults.contains(editor.draft.card.category) ? defaults : defaults + [editor.draft.card.category]
    }
    var body: some View {
        NavigationStack {
            if let saved {
                MemoryDetailView(cardID: saved.id, savedNotice: true)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("memorySavedDone") } }
            } else {
                form
            }
        }
        .onDisappear {
            if let saved, model.pendingMemory?.card.id == saved.memory?.sourceCardID,
               model.pendingMemory?.occurrence?.id == saved.memory?.sourceOccurrenceID { model.pendingMemory = nil }
        }
    }
    private var form: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if editor.recovered {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("已恢复上次草稿", systemImage: "arrow.clockwise").accessibilityIdentifier("memoryDraftRecovered")
                            if !editor.draft.isEditing && source == nil && previous == nil && restoring == nil {
                                Button("保留草稿，另写一段") {
                                    Task {
                                        guard await editor.keep(model: model) else { return }
                                        editor.initialized = false; editor.recovered = false
                                        await editor.load(model: model, initialDate: model.now, occasionID: occasionID, source: nil, editing: nil, previous: nil, restoring: nil, allowRecovery: false)
                                    }
                                }.frame(minHeight: 44)
                            }
                        }.font(.subheadline).padding(14).paperCard(radius: 14)
                    }
                    if !editor.initialized && editor.busy { ProgressView("正在读取回忆…") }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("正文").font(.subheadline).foregroundColor(Paper.secondary)
                        TextField("记下发生的事，或当时的感受…", text: $editor.draft.card.note, axis: .vertical)
                            .font(Paper.text(17)).lineSpacing(6).lineLimit(4...14).focused($focus, equals: "note")
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("回忆正文").accessibilityIdentifier("memoryNote")
                        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())) {
                            dictateButton
                            if !typeSize.isAccessibilitySize { Spacer() }
                            characterCount
                        }
                        if editor.draft.card.note.count > AppLimits.noteLength {
                            Text("正文超出 \(editor.draft.card.note.count - AppLimits.noteLength) 字，请精简后保存。草稿会继续保留。").font(.footnote).foregroundColor(Paper.accent)
                        }
                        if pendingSpeech {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("有一段语音文字尚未加入正文").font(.subheadline)
                                Button("查看并使用语音文字") { focus = nil; dictation = true }.frame(minHeight: 44)
                            }.accessibilityIdentifier("memoryPendingSpeech")
                        }
                    }.padding(18).paperCard(radius: 18)
                    MemoryPhotoEditor(draft: $editor.draft, busy: $photoBusy) { focus = nil }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("标题（可选）").font(.subheadline).foregroundColor(Paper.secondary)
                        TextField("可留空", text: $editor.draft.card.title, axis: .vertical).font(.body).lineLimit(1...4).focused($focus, equals: "title").accessibilityLabel("回忆标题，可选").accessibilityIdentifier("memoryTitle")
                        if editor.draft.card.title.count > AppLimits.titleLength {
                            Text("标题最多 \(AppLimits.titleLength) 字，可以把详细内容移到正文。").font(.footnote).foregroundColor(Paper.accent)
                        }
                        let proposed = MemoryFactory.suggestedTitle(note: editor.draft.card.note, hasPhotos: !editor.draft.attachments.isEmpty)
                        if editor.draft.card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !proposed.isEmpty {
                            Text("建议标题：" + proposed).font(.footnote).foregroundColor(Paper.secondary).accessibilityIdentifier("memorySuggestedTitle")
                        }
                        Divider()
                        if typeSize.isAccessibilitySize {
                            Text("经历日期").font(.subheadline).foregroundColor(Paper.secondary)
                            experienceDate
                            Text("主题").font(.subheadline).foregroundColor(Paper.secondary)
                            themePicker
                        } else {
                            LabeledContent("经历日期") { experienceDate }
                            LabeledContent("主题") { themePicker }
                        }
                    }.padding(18).paperCard(radius: 18)
                    if let previousID = editor.draft.card.memory?.previousMemoryID {
                        let previousTitle = model.library.cards.first { $0.id == previousID }?.title ?? "之前的回忆"
                        Text("将新建一篇后续，关联「\(previousTitle)」。").font(.subheadline).foregroundColor(Paper.secondary)
                    }
                    if !editor.draftStatus.isEmpty { Label(editor.draftStatus, systemImage: "doc").font(.footnote).foregroundColor(Paper.secondary).accessibilityIdentifier("memoryDraftStatus") }
                    Text("保存位置：\(editor.draft.card.scope.title)。草稿仅保存在本机。").font(.footnote).foregroundColor(Paper.secondary)
                    if let error = editor.error { PaperErrorBanner(message: error) }
                    if !editor.initialized && !editor.busy { Button("重新读取") { Task { await prepare() } }.frame(minHeight: 44) }
                    if editor.draftStatus == "草稿尚未保存" { Button("重试保存草稿") { editor.autosave(model: model, immediately: true) }.frame(minHeight: 44) }
                }.frame(width: max(0, geometry.size.width - 40), alignment: .leading).padding(20).disabled(editor.busy)
            }
        }.background { PaperSurface().ignoresSafeArea() }.foregroundColor(Paper.ink)
            .scrollDismissesKeyboard(.interactively).accessibilityIdentifier("memoryComposerScroll")
            .navigationTitle(editor.draft.isEditing || editing != nil ? "编辑回忆" : previous != nil ? "写后续" : "写回忆").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { focus = nil; if editor.dirty { discarding = true } else { dismiss() } }.disabled(editor.busy || photoBusy).accessibilityIdentifier("cancelMemory") }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { focus = nil; Task { saved = await editor.save(model: model) } }.disabled(!editor.canSave || photoBusy || pendingSpeech).accessibilityLabel("保存回忆").accessibilityIdentifier("saveMemory") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focus = nil }.accessibilityIdentifier("memoryKeyboardDone") }
            }
            .task { await prepare() }
            .onChange(of: editor.draft) { _ in editor.autosave(model: model) }
            .onChange(of: scenePhase) { phase in if phase != .active { editor.autosave(model: model, immediately: true) } }
            .onDisappear { if saved == nil { editor.autosave(model: model, immediately: true) } }
            .interactiveDismissDisabled(editor.dirty || editor.busy || photoBusy)
            .confirmationDialog("这段回忆还没有保存", isPresented: $discarding, titleVisibility: .visible) {
                Button("保存草稿，稍后继续") { Task { if await editor.keep(model: model) { dismiss() } } }.accessibilityIdentifier("keepMemoryDraft")
                Button("放弃编辑", role: .destructive) { Task { if await editor.discard(model: model) { dismiss() } } }
                Button("继续编辑", role: .cancel) { }
            }
            .sheet(isPresented: $dictation) { MemoryDictationView(text: Binding(get: { editor.draft.memorySpeechText ?? "" }, set: { editor.draft.memorySpeechText = $0 })) { text in
                if !editor.draft.card.note.isEmpty { editor.draft.card.note += "\n" }
                editor.draft.card.note += text; editor.draft.memorySpeechText = nil
            } }
            .sheet(isPresented: $selectingDate) {
                NavigationStack {
                    ScrollView {
                        DatePicker("经历日期", selection: date, in: ...model.now, displayedComponents: .date)
                            .datePickerStyle(.graphical).padding(16).accessibilityIdentifier("memoryDateCalendar")
                    }.navigationTitle("经历日期").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selectingDate = false }.accessibilityIdentifier("memoryDateDone") } }
                }
            }
    }
    private var dictateButton: some View {
        Button { focus = nil; dictation = true } label: { Label(pendingSpeech ? "继续语音文字" : "说一段话", systemImage: "mic").frame(minHeight: 44) }.font(.subheadline).accessibilityIdentifier("memoryDictate")
    }
    @ViewBuilder private var experienceDate: some View {
        if typeSize.isAccessibilitySize {
            let value = CardPresentation.dateLabel(date.wrappedValue, format: "yyyy年M月d日")
            Button { focus = nil; selectingDate = true } label: {
                Text(value).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityLabel("经历日期").accessibilityValue(value).accessibilityIdentifier("memoryDate")
        } else {
            DatePicker("经历日期", selection: date, in: ...model.now, displayedComponents: .date).labelsHidden().accessibilityLabel("经历日期").accessibilityIdentifier("memoryDate")
        }
    }
    private var themePicker: some View {
        Picker(typeSize.isAccessibilitySize ? "主题" : "", selection: $editor.draft.card.category) { ForEach(themes, id: \.self) { Text($0).tag($0) } }.labelsHidden().accessibilityIdentifier("memoryCategory")
    }
    private var characterCount: some View {
        Text("\(editor.draft.card.note.count)/\(AppLimits.noteLength)").font(.caption).foregroundColor(Paper.secondary)
            .accessibilityLabel("正文 \(editor.draft.card.note.count) 字，最多 \(AppLimits.noteLength) 字")
    }
    private func prepare() async { await editor.load(model: model, initialDate: initialDate, occasionID: occasionID, source: source, editing: editing, previous: previous, restoring: restoring) }
}

private struct MemoryDictationView: View {
    @Binding var text: String
    var onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = LocalSpeechService()
    @State private var recordingPrefix = ""
    @State private var appendingSpeech = false
    @FocusState private var typing: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("说说发生的事和当时的感受，确认后加入正文。").font(.subheadline).foregroundColor(Paper.secondary)
                    TextField("语音文字，也可以直接编辑", text: $text, axis: .vertical).lineLimit(5...16).focused($typing).disabled(speech.isRecording || speech.isPreparing).padding(18).paperCard(radius: 18).accessibilityLabel("回忆语音文字").accessibilityIdentifier("memorySpeechTranscript")
                    if let error = speech.error { PaperErrorBanner(message: error) }
                    if let status = speech.resourceStatus { Text(status).font(.footnote).foregroundColor(Paper.secondary) }
                    if speech.canPrepareEnhancedResources { Button("下载中文语音支持") { Task { await speech.prepareEnhancedResources() } }.disabled(speech.isPreparing || speech.isRecording) }
                    if speech.isPreparing { ProgressView("正在处理语音…") }
                    Button { typing = false; Task {
                        if speech.isRecording { await speech.finish(); appendTranscript(); appendingSpeech = false }
                        else { recordingPrefix = text; speech.transcript = ""; appendingSpeech = true; await speech.start() }
                    } } label: { Label(speech.isRecording ? "停止录音" : text.isEmpty ? "开始录音" : "继续录一段", systemImage: speech.isRecording ? "stop.fill" : "mic.fill") }
                        .buttonStyle(PaperPrimaryButton()).disabled(speech.isPreparing).accessibilityIdentifier("memorySpeechRecord")
                    Button { onConfirm(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() } label: { Text("加入回忆正文").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle()) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isRecording || speech.isPreparing).accessibilityIdentifier("memorySpeechConfirm")
                    Text("返回后文字会随草稿保留，可稍后继续。").font(.footnote).foregroundColor(Paper.secondary)
                }.padding(20)
            }.background(Paper.background).navigationTitle("语音记回忆").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() }.accessibilityIdentifier("memorySpeechBack") }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { typing = false }.accessibilityIdentifier("memorySpeechKeyboardDone") }
                }
                .task { await speech.checkEnhancedResources() }
                .onChange(of: speech.transcript) { _ in if appendingSpeech { appendTranscript() } }
                .onDisappear { speech.stop() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in speech.stop() }
        }
    }
    private func appendTranscript() {
        text = [recordingPrefix, speech.transcript].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
