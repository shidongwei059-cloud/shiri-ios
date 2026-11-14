import Foundation
import Speech
import AVFoundation
import SwiftUI
import ShiriCore

struct SpeechInputView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var service = LocalSpeechService()
    @State private var isConfirming = false
    @State private var confirmationTask: Task<Void, Never>?
    @FocusState private var editingText: Bool
    @State private var previewDrafts: [CardDraft] = []
    @State private var previewText = ""
    @State private var previewError: String?
    var allowsDirectCreation = true
    var onConfirm: (String, Bool) -> Void
    private var canCreate: Bool { allowsDirectCreation && previewDrafts.count == 1 && previewDrafts[0].questions.isEmpty && previewError == nil && service.error == nil }
    private var previewIsCurrent: Bool { previewText == trimmedText && !previewDrafts.isEmpty }
    private var trimmedText: String { service.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if trimmedText.isEmpty {
                            PaperPageHeader(title: "说一件小事", subtitle: "说出要做的事、时间和提醒方式，核对后保存。录音不会上传。", symbol: "waveform")
                            if #available(iOS 18.0, *) {
                                Text("首次允许语音权限后，可从桌面或锁屏的圆形、矩形语音组件直接录音，在实时活动中停止并保存。")
                                    .font(.footnote).foregroundColor(Paper.secondary)
                            }
                        } else {
                            HStack {
                                Text("识别内容 · 可以修改").font(.caption).foregroundColor(Paper.secondary)
                                Spacer()
                                if editingText { Button("完成输入") { editingText = false }.font(.subheadline).accessibilityIdentifier("speechKeyboardDone") }
                            }.frame(minHeight: 32)
                        }
                        TextField("例如：今天下午三点提前十分钟提醒我取快递", text: $service.transcript, axis: .vertical)
                            .font(typeSize.isAccessibilitySize ? .body : Paper.title(23)).lineLimit(2...5).focused($editingText)
                            .disabled(service.isRecording || service.isPreparing || isConfirming)
                            .accessibilityIdentifier("speechTranscript")
                        if previewIsCurrent, let draft = previewDrafts.first {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("将创建的卡片").font(.caption).foregroundColor(Paper.secondary)
                                Text(draft.card.title.isEmpty ? "待填写事项" : draft.card.title)
                                    .font(Paper.title(24)).accessibilityIdentifier("speechPreviewTitle")
                                if let schedule = draft.card.schedule,
                                   let date = OccurrenceEngine(calendar: model.calendar).date(schedule.start, time: schedule.time ?? DayTime(hour: 0)) {
                                    Label((schedule.frequency == .never ? "" : "开始于 ") + CardPresentation.dateLabel(date, format: "M月d日") + (schedule.time.map { " · " + $0.display } ?? " · 待选择时间"), systemImage: "calendar")
                                        .accessibilityIdentifier("speechPreviewSchedule")
                                    if schedule.frequency != .never {
                                        Label(repeatSummary(schedule), systemImage: "repeat").accessibilityIdentifier("speechPreviewRepeat")
                                    }
                                }
                                if let place = draft.card.place {
                                    Label(place.trigger.title + " · " + place.name, systemImage: "location").accessibilityIdentifier("speechPreviewPlace")
                                }
                                if draft.card.reminders.isEnabled {
                                    Label(draft.card.reminders.nodesSummary, systemImage: "bell").accessibilityIdentifier("speechPreviewReminders")
                                } else if draft.card.schedule?.time != nil {
                                    Label("不提醒", systemImage: "bell.slash").accessibilityIdentifier("speechPreviewReminders")
                                }
                                ForEach(draft.questions) { question in Text(question.message).font(.footnote).foregroundColor(Paper.accent) }
                                if previewDrafts.count > 1 { Text("识别到多件事，下一步分别核对。").font(.footnote).foregroundColor(Paper.secondary) }
                            }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(16).paperCard(radius: 16)
                        }
                        if let previewError { PaperErrorBanner(message: previewError) }
                        if let error = service.error {
                            PaperErrorBanner(message: error).accessibilityIdentifier("speechError")
                            HStack {
                                Button("改用文字") { editingText = true }.accessibilityIdentifier("speechUseKeyboard")
                                Spacer()
                                Button("系统权限设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                            }.font(.subheadline)
                        }
                        if let status = service.resourceStatus { Text(status).font(.footnote).foregroundColor(Paper.secondary) }
                        if service.canPrepareEnhancedResources {
                            Button("下载中文语音支持") { editingText = false; Task { await service.prepareEnhancedResources() } }.disabled(service.isPreparing || service.isRecording)
                        }
                        if service.isPreparing { ProgressView("正在处理语音…") }
                        else if service.isRecording { Label("正在聆听，完成后轻点停止录音", systemImage: "waveform").font(.subheadline).foregroundColor(Paper.accent).accessibilityIdentifier("speechRecording") }
                        else { Text("识别文字可以修改。安排明确时，确认一次即可创建；时间不明确时继续核对。").font(.footnote).foregroundColor(Paper.secondary) }
                    }.padding(23)
                }.scrollDismissesKeyboard(.interactively)
                VStack(spacing: 12) {
                    Button {
                        editingText = false
                        if service.isRecording { Task { await service.finish() } }
                        else { Task {
                            if #available(iOS 18.0, *) { await WidgetVoiceCapture.shared.finish() }
                            await service.start()
                        } }
                    } label: {
                        Label(service.isRecording ? "停止录音" : "开始录音", systemImage: service.isRecording ? "stop.fill" : "mic.fill")
                    }.buttonStyle(PaperPrimaryButton()).disabled(service.isPreparing || isConfirming).accessibilityIdentifier("speechRecord")
                    Button(canCreate ? "确认并创建卡片" : "继续核对安排") {
                        guard !isConfirming else { return }
                        editingText = false; isConfirming = true
                        confirmationTask = Task {
                            await service.finish()
                            guard !Task.isCancelled else { return }
                            let text = trimmedText
                            guard !text.isEmpty else { isConfirming = false; return }
                            onConfirm(text, canCreate && service.error == nil); dismiss()
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(!previewIsCurrent || service.isRecording || service.isPreparing || isConfirming).accessibilityIdentifier("speechConfirm")
                }.padding(.horizontal, 23).padding(.bottom, 12).padding(.top, 8)
            }.background(Paper.background).navigationTitle("语音输入").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Paper.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("speechCancel") }
                }
                .task { await service.checkEnhancedResources() }
                .task(id: service.transcript) {
                    let text = trimmedText
                    previewError = nil
                    guard !text.isEmpty else { previewDrafts = []; previewText = ""; return }
                    let calendar = model.calendar, now = model.now, defaultTime = model.preferences.defaultReminderTime
                    let places = model.library.cards.compactMap(\.place)
                    do {
                        try await Task.sleep(nanoseconds: 200_000_000)
                        let drafts = try await Task.detached(priority: .userInitiated) {
                            try ChineseCardParser(calendar: calendar).interpret(text, now: now, defaultTime: defaultTime, places: places)
                        }.value
                        try Task.checkCancellation()
                        previewDrafts = drafts; previewText = text
                    } catch is CancellationError { }
                    catch { previewDrafts = []; previewError = error.localizedDescription }
                }
                .onDisappear { confirmationTask?.cancel(); service.stop() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in if service.isRecording { service.stop() } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in service.stop() }
        }
    }

    private func repeatSummary(_ schedule: ScheduleDefinition) -> String {
        switch schedule.frequency {
        case .never: return "不重复"
        case .daily: return schedule.interval == 1 ? "每天" : "每 \(schedule.interval) 天"
        case .weekly:
            let names = [2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六", 1: "日"]
            return "每周" + [2,3,4,5,6,7,1].filter { schedule.weekdays.contains($0) }.compactMap { names[$0] }.joined(separator: "、")
        case .monthly:
            return schedule.monthDay == 31 && schedule.missingDatePolicy == .lastValidDay ? "每月最后一天" : "每月 \(schedule.monthDay) 日"
        case .yearly: return "每年 \(schedule.month) 月 \(schedule.monthDay) 日"
        }
    }
}
