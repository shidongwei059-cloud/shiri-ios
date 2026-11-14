import SwiftUI
import Charts
import ShiriCore

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 107
    @State private var memories = false
    @State private var period = ReviewPeriod.week
    @State private var selectedDate: Date?
    @State private var dateSelection = Date()
    @State private var showsDatePicker = false
    @State private var showsExplanation = false
    @State private var exporting = false
    @State private var showsDetails = false
    @State private var showsNotes = false
    @State private var showsProgress = true
    @State private var actionAfterDetails: String?
    @State private var result: CalculationResult?
    @State private var computation: Task<CalculationResult?, Never>?
    @State private var activeCalculation: UUID?
    @State private var completedCalculationID: String?
    @State private var isCalculating = false
    @State private var cancelled = false
    @State private var retry = 0
    private var date: Date { selectedDate ?? model.now }
    private var interval: DateInterval {
        model.calendar.dateInterval(of: period.component, for: date) ?? DateInterval(start: date, duration: 1)
    }
    private var isCurrentPeriod: Bool { interval.containsHalfOpen(model.now) }
    private var calculationID: String { "\(period.rawValue)-\(interval.start.timeIntervalSince1970)-\(interval.end.timeIntervalSince1970)-\(model.snapshotRevision)-\(retry)" }

    private struct CalculationResult: Sendable {
        let summary: ReviewSummary
        let period: ReviewPeriod
        let previousCount: Int
        let snoozes: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { memories = false } label: { Text("完成回顾").frame(minHeight: 44) }.accessibilityIdentifier("reviewMode_completed")
                    .foregroundColor(memories ? Paper.secondary : Paper.accent).accessibilityAddTraits(memories ? [] : [.isSelected])
                Button { memories = true } label: { Text("回忆").frame(minHeight: 44) }.accessibilityIdentifier("reviewMode_memories")
                    .foregroundColor(memories ? Paper.accent : Paper.secondary).accessibilityAddTraits(memories ? [.isSelected] : [])
                Spacer(minLength: 0)
            }.font(.headline).buttonStyle(.plain).frame(minHeight: 48).padding(.horizontal, 16)
            if memories {
                MemoryBookView(interval: interval, embedded: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        controls
                        Divider()
                        DisclosureGroup("统计与进展", isExpanded: $showsProgress) {
                            ZStack(alignment: .top) {
                                if let result {
                                    content(result).disabled(isCalculating || cancelled).opacity(isCalculating || cancelled ? 0.55 : 1)
                                        .accessibilityElement(children: .contain).accessibilityIdentifier("reviewResults")
                                        .accessibilityValue(result.period.title + "：" + intervalLabel(result.summary.interval))
                                } else { Color.clear.frame(height: 120) }
                                if isCalculating || cancelled { calculationStatus }
                            }
                        }.font(.subheadline).padding(.vertical, 8).accessibilityIdentifier("reviewProgressDisclosure")
                        notesSection
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }.accessibilityIdentifier("page_review")
            }
        }
        .task(id: calculationID) { await calculate() }
        .sheet(isPresented: $showsDatePicker) { datePicker }
        .sheet(isPresented: $showsNotes) {
            NavigationStack {
                List(periodNotes) { note in
                    NavigationLink { CardDetailView(cardID: note.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.title).font(.headline)
                            Text(eventDate(note.createdAt)).font(.caption).foregroundColor(Paper.secondary)
                            if !note.note.isEmpty { Text(note.note).font(.subheadline).lineLimit(2) }
                        }.padding(.vertical, 6)
                    }
                }.navigationTitle("本期随手记 · \(periodNotes.count)").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsNotes = false } } }
            }
        }
        .sheet(isPresented: $exporting) { if let result { ReviewExportView(summary: result.summary) } }
        .sheet(isPresented: $showsDetails, onDismiss: {
            if actionAfterDetails == "export" { exporting = true }
            if actionAfterDetails == "explanation" { showsExplanation = true }
            actionAfterDetails = nil
        }) { if let result { detailedReview(result) } }
        .sheet(isPresented: $showsExplanation) {
            NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 20) {
                Text("统计口径").font(Paper.title(30))
                Text("完成数：这段时间内完成的待办数量。同一件重复待办，每次完成分别计数；撤销完成后不再计入。\n\n计划完成率：这段时间内计划要做的待办中，已完成的比例。跳过和取消的安排不计入；没有计划时显示“—”。\n\n长期进展：没有安排日期和截止日期的待办，在这段时间内完成的数量。\n\n分类和重要程度以完成时的记录为准，之后编辑卡片不会改变过去的统计。").font(.body).lineSpacing(7)
            }.padding(24) }.background(Paper.background).toolbar { ToolbarItem(placement: .confirmationAction) { Button("明白了") { showsExplanation = false } } } }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(ReviewPeriod.allCases) { value in
                    Button { period = value } label: {
                        Text(value.title).font(Paper.text(17)).frame(width: dynamicType.isAccessibilitySize ? 88 : 68).frame(minHeight: dynamicType.isAccessibilitySize ? 60 : 29)
                            .foregroundColor(period == value ? Paper.onAccent : Paper.secondary).background(period == value ? Paper.accent : .clear, in: Capsule())
                    }
                    .accessibilityIdentifier("reviewPeriod_" + value.rawValue)
                    .accessibilityAddTraits(period == value ? .isSelected : [])
                }
                Spacer()
            }
            (dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 7))) {
                Button {
                    dateSelection = min(date, model.now); showsDatePicker = true
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 15))
                        Text(displayedInterval).font(Paper.text(15)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }.foregroundColor(Paper.secondary).frame(minHeight: 44)
                }.accessibilityLabel("选择回顾日期").accessibilityValue(intervalLabel(interval)).accessibilityIdentifier("reviewDateSelector")
                if !dynamicType.isAccessibilitySize { Spacer(minLength: 0) }
                HStack(spacing: dynamicType.isAccessibilitySize ? 25 : 0) {
                    Button { movePeriod(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 18)).frame(width: 36, height: 44) }.accessibilityLabel("上一个周期")
                    Button { selectedDate = nil } label: {
                        Text("本" + period.title).font(Paper.text(15)).foregroundColor(Paper.secondary)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("reviewCurrentPeriod")
                    Button { movePeriod(1) } label: { Image(systemName: "chevron.right").font(.system(size: 18)).frame(width: 36, height: 44) }.disabled(isCurrentPeriod).accessibilityLabel("下一个周期")
                }
            }
        }
    }

    private var datePicker: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker("回顾日期", selection: $dateSelection, in: ...model.now, displayedComponents: .date)
                        .datePickerStyle(.graphical).accessibilityIdentifier("reviewDatePicker")
                    Text("查看所选日期所在的\(period.title)，切换周、月、年时会保留这一天。").font(.subheadline).foregroundColor(Paper.secondary)
                }.padding(16)
            }.background(Paper.background).navigationTitle("选择回顾日期").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showsDatePicker = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") { selectedDate = model.calendar.startOfDay(for: dateSelection); showsDatePicker = false }
                            .accessibilityIdentifier("confirmReviewDate")
                    }
                }
        }.environment(\.calendar, model.calendar).presentationDetents([.large])
    }

    private var calculationStatus: some View {
        VStack(spacing: 10) {
            if cancelled {
                Text("已暂停计算，本地记录仍然保留。").font(.subheadline)
                Button("重新计算") { retry += 1 }
            } else {
                ProgressView("正在更新回顾…").accessibilityIdentifier("reviewLoading")
                Button("取消计算") {
                    cancelled = true; isCalculating = false; activeCalculation = nil; computation?.cancel(); computation = nil
                }
            }
        }.padding(18).frame(maxWidth: .infinity).paperCard(radius: 14)
    }

    private var displayedInterval: String {
        let value = intervalLabel(interval)
        guard dynamicType.isAccessibilitySize else { return value }
        return value.replacingOccurrences(of: "年", with: "年\n").replacingOccurrences(of: " — ", with: "\n至 ")
    }

    private func intervalLabel(_ value: DateInterval) -> String {
        let start = value.start, end = value.end.addingTimeInterval(-1)
        let calendar = model.calendar
        let includeYear = calendar.component(.year, from: start) != calendar.component(.year, from: model.now)
        return CardPresentation.dateLabel(start, format: includeYear ? "yyyy年M月d日" : "M月d日") + " — " +
            CardPresentation.dateLabel(end, format: calendar.component(.year, from: start) != calendar.component(.year, from: end) ? "yyyy年M月d日" : "M月d日")
    }

    private func movePeriod(_ value: Int) {
        guard let moved = model.calendar.date(byAdding: period.component, value: value, to: date) else { return }
        selectedDate = min(moved, model.now)
    }

    @MainActor private func calculate() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID(), inputID = calculationID
        if completedCalculationID == inputID {
            computation?.cancel(); computation = nil; activeCalculation = nil; isCalculating = false; cancelled = false
            return
        }
        activeCalculation = requestID; cancelled = false; isCalculating = true
        let now = model.now, calendar = model.calendar, library = model.library, selectedPeriod = period, selectedInterval = interval
        let task = Task.detached(priority: .userInitiated) { () -> CalculationResult? in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting"),
               let store = ProcessInfo.processInfo.environment["NIANYI_TEST_STORE_ID"], UUID(uuidString: store) != nil,
               let delay = UInt64(ProcessInfo.processInfo.environment["NIANYI_REVIEW_DELAY_MS"] ?? "0"), delay > 0 {
                do { try await Task.sleep(nanoseconds: min(delay, 10_000) * 1_000_000) } catch { return nil }
            }
            #endif
            guard !Task.isCancelled else { return nil }
            let summary = ReviewCalculator.summarize(library: library, interval: selectedInterval, calendar: calendar, now: now, period: selectedPeriod)
            guard !Task.isCancelled else { return nil }
            let previousStart = calendar.date(byAdding: selectedPeriod.component, value: -1, to: selectedInterval.start) ?? selectedInterval.start
            let previous = ReviewCalculator.summarize(library: library, interval: DateInterval(start: previousStart, end: selectedInterval.start), calendar: calendar, now: now, period: selectedPeriod)
            guard !Task.isCancelled else { return nil }
            return CalculationResult(summary: summary, period: selectedPeriod, previousCount: previous.completed.count,
                                     snoozes: library.personalReminderEvents.filter { $0.kind == .snoozed && selectedInterval.containsHalfOpen($0.happenedAt) }.count)
        }
        computation = task
        let calculated = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard !Task.isCancelled, !task.isCancelled, activeCalculation == requestID, calculationID == inputID, let calculated else { return }
        // Publish related metrics together so an older period can never mix into the current result.
        result = calculated; completedCalculationID = inputID; isCalculating = false; computation = nil; activeCalculation = nil
    }

    private func content(_ result: CalculationResult) -> some View {
        let summary = result.summary, period = result.period
        let isCurrent = summary.interval.containsHalfOpen(model.now)
        return VStack(alignment: .leading, spacing: 8) {
            if summary.completed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isCurrent ? "这段时间还没有完成记录" : "这一周期没有完成记录").font(.headline)
                    Text("完成的待办会自动留在这里。随手记和回忆单独保存。").font(.subheadline).foregroundColor(Paper.secondary)
                    Button(isCurrent ? "看看今天" : "回到本\(period.title)") { if isCurrent { model.selectedTab = .today } else { selectedDate = nil } }.frame(minHeight: 44)
                }.padding(18).paperCard(radius: 18)
            } else if !summary.completed.isEmpty {
            (dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(summary.completed.count)").font(.system(size: 60, weight: .medium, design: .serif)).foregroundColor(Paper.accent)
                    Text("件事已完成").font(Paper.text(17))
                }.accessibilityElement(children: .ignore).accessibilityLabel("本期完成了 \(summary.completed.count) 件小事").accessibilityValue("\(summary.completed.count)").accessibilityIdentifier("reviewCount")
                if !dynamicType.isAccessibilitySize { Rectangle().fill(Paper.separator).frame(width: 0.5, height: 54) }
                VStack(alignment: .leading, spacing: 7) {
                    Text(isCurrent ? "本\(period.title)截至今天" : "这一\(period.title)的记录").font(Paper.text(14))
                    Text(model.preferences.showsReviewComparison == true ? comparison(summary.completed.count, previousCount: result.previousCount, period: period) : "做过的小事，都值得被记住").font(Paper.text(12)).foregroundColor(Paper.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !dynamicType.isAccessibilitySize {
                    Spacer(minLength: 0)
                    Image("ReviewFlowers").resizable().scaledToFit().frame(width: 90, height: 98).saturation(0.65).opacity(0.8).blendMode(.multiply).accessibilityHidden(true)
                }
            }.frame(minHeight: 99)
            (dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 20))) {
                metric(summary.completionRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "计划完成率")
                metric("\(summary.longTermCompleted) 件", "长期待办完成")
                Spacer(minLength: 0)
            }.padding(14).paperCard(radius: 13).accessibilityElement(children: .contain).accessibilityIdentifier("reviewKeyMetrics")
            if period == .week {
                if dynamicType.isAccessibilitySize { ScrollView(.horizontal, showsIndicators: false) { weeklyChart(summary) } }
                else { weeklyChart(summary) }
            }
            else {
                Chart(summary.buckets) { bucket in BarMark(x: .value("日期", bucket.id, unit: period == .year ? .month : .day), y: .value("完成数", bucket.count)).foregroundStyle(Paper.accent).cornerRadius(3) }
                    .chartYScale(domain: 0...max(1, (summary.buckets.map(\.count).max() ?? 0))).frame(height: 135)
            }
            Divider().padding(.top, 4)
            HStack {
                Text("完成过的小事").font(Paper.title(22)).padding(.vertical, -2); Spacer()
                if summary.completed.count > 5 { Button("全部 \(summary.completed.count) 件") { showsDetails = true }.font(Paper.text(13)).foregroundColor(Paper.secondary) }
            }.padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(summary.completed.prefix(5).enumerated()), id: \.element.id) { index, event in
                    Button { openCompleted(event) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 23)).foregroundColor(index == 0 ? Paper.accent : Color(hex: "9BA587"))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(event.snapshot.title).font(Paper.text(15)).foregroundColor(Paper.ink)
                                if dynamicType.isAccessibilitySize { Text(eventDate(event.happenedAt)).font(Paper.text(13)).foregroundColor(Paper.secondary) }
                            }
                            Spacer(minLength: 0)
                            if !dynamicType.isAccessibilitySize { Text(eventDate(event.happenedAt)).font(Paper.text(13)).foregroundColor(Paper.secondary) }
                        }.padding(.vertical, dynamicType.isAccessibilitySize ? 10 : 0).frame(minHeight: 46)
                    }
                    Divider()
                }
            }
            }
            Button("查看详细回顾与导出") { showsDetails = true }.font(Paper.text(12)).foregroundColor(Paper.secondary).frame(maxWidth: .infinity).padding(.top, 8)
        }
    }
    @ViewBuilder private var notesSection: some View {
            if let note = periodNotes.first {
                HStack {
                    Text("留下的随手记").font(Paper.title(22)).padding(.vertical, -2)
                    Spacer()
                    Button("全部 \(periodNotes.count) 条") { showsNotes = true }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("reviewAllNotes")
                }.padding(.top, 3)
                Button { model.selectedCard = note } label: {
                    HStack(spacing: 6) {
                        Text(note.title).font(Paper.text(16)).foregroundColor(Paper.cardInk).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if !dynamicType.isAccessibilitySize { Image("Ginkgo").resizable().scaledToFit().frame(width: 77, height: 73).saturation(0.75).opacity(0.8).blendMode(.multiply) }
                    }.padding(.horizontal, 18).frame(minHeight: 73).paperCard(Paper.card(.sage), radius: 14)
                }.accessibilityIdentifier("reviewNote")
            }
    }
    private var periodNotes: [Card] {
        let selectedInterval = result?.summary.interval ?? interval
        return model.library.cards.filter { $0.kind == .note && !$0.isMemory && $0.birthday == nil && $0.lifecycle != .deleted && selectedInterval.containsHalfOpen($0.createdAt) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    private func comparison(_ count: Int, previousCount: Int, period: ReviewPeriod) -> String {
        let difference = count - previousCount
        if difference == 0 { return "和上一\(period.title)一样多" }
        return "比上一\(period.title)\(difference > 0 ? "多" : "少")了 \(abs(difference)) 件小事"
    }
    private func eventDate(_ date: Date) -> String {
        let time = CardPresentation.dateLabel(date, format: "HH:mm")
        if model.calendar.isDate(date, inSameDayAs: model.now) { return "今天 " + time }
        if let yesterday = model.calendar.date(byAdding: .day, value: -1, to: model.now), model.calendar.isDate(date, inSameDayAs: yesterday) { return "昨天 " + time }
        return CardPresentation.dateLabel(date, format: "M月d日 HH:mm")
    }
    private func weeklyChart(_ summary: ReviewSummary) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(summary.buckets) { bucket in
                let selected = model.calendar.isDate(bucket.id, inSameDayAs: model.now)
                let future = bucket.id > model.calendar.startOfDay(for: model.now)
                VStack(spacing: 7) {
                    Spacer(minLength: 0)
                    Text(future ? "—" : "\(bucket.count)").font(Paper.text(15)).foregroundColor(selected ? Paper.accent : Paper.ink)
                    if bucket.count == 0 {
                        Rectangle().fill(Paper.secondary.opacity(0.4)).frame(width: 23, height: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(selected ? Paper.accent : Color(hex: "D4C0A4"))
                            .overlay { PaperGrain() }.frame(width: 27, height: CGFloat(bucket.count) / CGFloat(max(1, summary.buckets.map(\.count).max() ?? 1)) * 48)
                    }
                    Text(CardPresentation.dateLabel(bucket.id, format: "EEEEE")).font(Paper.text(14))
                    Text(String(model.calendar.component(.day, from: bucket.id))).font(Paper.text(14))
                }.foregroundColor(selected ? Paper.accent : Paper.secondary).frame(width: dynamicType.isAccessibilitySize ? 82 : nil).frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore).accessibilityLabel(CardPresentation.dateLabel(bucket.id) + (future ? "，尚未到来" : "，完成 \(bucket.count) 件"))
            }
        }.frame(height: chartHeight).padding(.bottom, 6).accessibilityIdentifier("weeklyChart")
    }
    private func detailedReview(_ result: CalculationResult) -> some View {
        let summary = result.summary
        return NavigationStack {
            List {
                Section("本期统计") {
                    LabeledContent("计划完成率", value: summary.completionRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    LabeledContent("长期进展", value: "\(summary.longTermCompleted) 件")
                    LabeledContent("有截止时间的按时完成", value: summary.withDeadline == 0 ? "暂无" : "\(summary.onTimeCompleted) / \(summary.withDeadline)")
                    LabeledContent("重要事项完成", value: summary.importantPlanned == 0 ? "暂无" : "\(summary.importantCompleted) / \(summary.importantPlanned)")
                    LabeledContent("这台设备的稍后提醒", value: "\(result.snoozes) 次")
                }
                Section("时间留给了什么") { ForEach(summary.categories.keys.sorted(), id: \.self) { category in LabeledContent(category, value: "\(summary.categories[category] ?? 0) 件") } }
                Section("全部完成记录") { ForEach(summary.completed) { event in
                    Button { showsDetails = false; openCompleted(event) } label: { VStack(alignment: .leading, spacing: 5) { Text(event.snapshot.title); Text(eventDate(event.happenedAt)).font(.caption).foregroundColor(Paper.secondary) } }
                } }
                Section {
                    Button("导出我的回顾") { actionAfterDetails = "export"; showsDetails = false }
                    Button("统计口径") { actionAfterDetails = "explanation"; showsDetails = false }
                }
            }.navigationTitle("详细回顾").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsDetails = false } } }
        }
    }
    private func metric(_ value: String, _ title: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(value).font(.system(.largeTitle, design: .serif).weight(.medium)).foregroundColor(Paper.cardInk); Text(title).font(.caption).foregroundColor(Paper.cardSecondary) } }
    private func openCompleted(_ event: TaskEvent) {
        guard let card = model.library.cards.first(where: { $0.id == event.cardID }) else { return }
        model.openCard(card, occurrence: model.library.occurrences.first { $0.id == event.occurrenceID })
    }
}

struct ConflictResolutionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var cardID: UUID
    @State private var error: String?
    private var heads: [CardRevision] { model.library.conflicts[cardID] ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaperPageHeader(title: "保留哪份安排？", subtitle: "不同设备分别修改了这张卡片。确认后会保留处理历史。", symbol: "arrow.triangle.branch")
                ForEach(heads) { head in
                    VStack(alignment: .leading, spacing: 12) {
                        CardTile(projection: CardProjection(card: head.snapshot, occurrence: nil), compact: true, onOpen: {}, onComplete: nil)
                        Text(head.createdAt.formatted()).font(.caption).foregroundColor(Paper.secondary)
                        Text(head.snapshot.schedule.map { "\($0.start.key) · \($0.time?.display ?? "未选时间") · \($0.frequency.title)" } ?? "不设日期").font(.subheadline)
                        Button("保留这份") {
                            model.perform {
                                _ = try await model.commands?.save(CardDraft(card: head.snapshot, isEditing: true), now: model.now, resolvingHeads: heads.map(\.id))
                                dismiss()
                            }
                        }.buttonStyle(PaperPrimaryButton())
                    }
                }
                if heads.isEmpty { Text("这张卡片没有需要确认的修改。") }
            }.padding(18)
        }.background(Paper.background).navigationTitle("确认修改").navigationBarTitleDisplayMode(.inline)
    }
}
