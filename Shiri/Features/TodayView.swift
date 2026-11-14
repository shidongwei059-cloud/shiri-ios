import SwiftUI
import ShiriCore

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDate: Date?
    @State private var dayProjections: [CardProjection] = []
    @State private var projectedDate: Date?
    @State private var showsAllUpcoming = false
    @State private var showsDatePicker = false
    @State private var pendingDate = Date()
    @ScaledMetric(relativeTo: .body) private var dateStripHeight: CGFloat = 64
    private var date: Date { selectedDate ?? model.now }
    private var active: [CardProjection] { (selectedDate == nil ? model.projections : dayProjections).filter { $0.card.lifecycle == .active && !$0.card.isMemory } }
    private var upcoming: [CardProjection] {
        active.filter { p in
            p.card.kind == .task && !p.card.isUndatedTask && p.state == .pending &&
                (selectedDate == nil || p.occurrence?.plannedAt.map { model.calendar.isDate($0, inSameDayAs: date) } == true)
        }.sorted { ($0.occurrence?.plannedAt ?? .distantFuture) < ($1.occurrence?.plannedAt ?? .distantFuture) }
    }
    private var handled: [CardProjection] {
        return active.filter { $0.card.kind == .task && !$0.card.isUndatedTask && [.completed, .skipped].contains($0.state) && $0.occurrence?.plannedAt.map { model.calendar.isDate($0, inSameDayAs: date) } == true }
            .sorted { ($0.occurrence?.plannedAt ?? .distantFuture) < ($1.occurrence?.plannedAt ?? .distantFuture) }
    }
    var body: some View {
        let active = self.active, upcoming = self.upcoming, handled = self.handled
        LazyVStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    Button { pendingDate = date; showsDatePicker = true } label: {
                        HStack(spacing: 7) {
                            Text(CardPresentation.dateLabel(date, format: model.calendar.component(.year, from: date) == model.calendar.component(.year, from: model.now) ? "M月d日 · EEEE" : "yyyy年M月d日 · EEEE"))
                            Image(systemName: "chevron.down").font(.caption)
                        }.multilineTextAlignment(.leading).frame(minHeight: 44).contentShape(Rectangle())
                    }.font(Paper.text(16)).foregroundColor(Paper.secondary)
                        .accessibilityLabel("选择日期，" + date.formatted(date: .complete, time: .omitted)).accessibilityIdentifier("todayDatePicker")
                    if selectedDate != nil {
                        Spacer(minLength: 0)
                        Button("今天") { selectDate(model.now) }.font(Paper.text(14)).foregroundColor(Paper.accent).frame(minHeight: 44).accessibilityLabel("回到今天").accessibilityIdentifier("todayReturnCurrent")
                    }
                }
            }
            HStack(spacing: 0) {
                Button { moveWeek(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 44) }
                    .accessibilityLabel("上一周").accessibilityIdentifier("todayPreviousWeek")
                DateStripPager(date: date, calendar: model.calendar, onSelect: selectDate)
                    .frame(height: dateStripHeight)
                Button { moveWeek(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 44) }
                    .accessibilityLabel("下一周").accessibilityIdentifier("todayNextWeek")
            }.foregroundColor(Paper.secondary)
            HStack { Text("待处理").font(Paper.title(22)).padding(.vertical, -2); Spacer(); Button { showsAllUpcoming.toggle() } label: { HStack(spacing: 9) { Text("\(upcoming.count) 件事"); Image(systemName: showsAllUpcoming ? "chevron.up" : "chevron.right").font(.caption) }.font(Paper.text(14)).foregroundColor(Paper.secondary).frame(minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("todayUpcomingToggle") }.padding(.top, 5)
            if selectedDate != nil && projectedDate != selectedDate {
                ProgressView("正在整理这一天…").frame(maxWidth: .infinity, minHeight: 120)
            } else if upcoming.isEmpty {
                if !handled.isEmpty {
                    Text("这一天的待办都已处理，可以在下面查看记录。").font(Paper.text(14)).foregroundColor(Paper.secondary).padding(.vertical, 12)
                } else { emptySchedule }
            } else {
                let visible = Array(upcoming.prefix(showsAllUpcoming ? upcoming.count : 2))
                ForEach(Array(visible.enumerated()), id: \.element.browsingID) { index, p in
                    VStack(alignment: .leading, spacing: 8) {
                        if upcoming.count > 2 && (index == 0 || groupLabel(visible[index - 1]) != groupLabel(p)) {
                            Text(groupLabel(p)).font(.subheadline).foregroundColor(Paper.secondary).padding(.top, 6)
                        }
                        CardTile(projection: p, showsReminder: true, onOpen: { model.openCard(p) }, onComplete: { model.complete(p) })
                    }
                }
            }
            let pinned = active.filter { $0.card.isUndatedTask && $0.card.isPinned && $0.state == .pending }
            if !pinned.isEmpty {
                Text("慢慢完成").font(Paper.title(22)).padding(.vertical, -2)
                ForEach(pinned) { p in CardTile(projection: p, compact: true, onOpen: { model.openCard(p) }, onComplete: { model.complete(p) }) }
            }
            let notes = active.filter { $0.card.kind == .note && $0.card.birthday == nil }
            if !notes.isEmpty {
                Text("随手记").font(Paper.title(22)).padding(.vertical, -2).padding(.top, 5)
                ForEach(Array(notes.prefix(1))) { p in
                    Button { model.selectedCard = p.card } label: {
                        HStack(spacing: 15) { PaperSymbol(p.card.birthday == nil ? "note.text" : "birthday.cake"); Text(p.card.title).font(Paper.text(16)); Spacer() }.foregroundColor(Paper.ink).padding(.horizontal, 19).frame(maxWidth: .infinity, minHeight: 53, alignment: .leading).paperCard(radius: 13)
                    }
                }
            }
            let occasions = active.filter { $0.card.birthday != nil && $0.card.recurrenceClosedAt == nil && (selectedDate == nil || $0.occurrence?.plannedAt.map { model.calendar.isDate($0, inSameDayAs: date) } == true) }
                .sorted { ($0.occurrence?.plannedAt ?? .distantFuture) < ($1.occurrence?.plannedAt ?? .distantFuture) }
            if !occasions.isEmpty {
                Text("重要日子").font(Paper.title(22)).padding(.vertical, -2).padding(.top, 5)
                ForEach(Array(occasions.prefix(2))) { p in CardTile(projection: p, compact: true, onOpen: { model.openCard(p) }) }
            }
            if !handled.isEmpty && (selectedDate == nil || projectedDate == selectedDate) {
                Text("已处理").font(Paper.title(22)).padding(.vertical, -2).padding(.top, 5)
                ForEach(handled, id: \.browsingID) { p in
                    CardTile(projection: p, compact: true, onOpen: { model.openCard(p) }, onComplete: nil)
                }
            }
        }.task(id: "\(selectedDate?.timeIntervalSince1970 ?? 0)-\(model.snapshotRevision)") {
            guard let selectedDate else { return }
            let snapshot = model.library; let calendar = model.calendar
            let worker = Task.detached(priority: .userInitiated) { AppModel.projectDay(snapshot, on: selectedDate, calendar: calendar) }
            let projections = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            dayProjections = projections; projectedDate = selectedDate
        }
        .sheet(isPresented: $showsDatePicker) {
            NavigationStack {
                ScrollView {
                    DatePicker("查看哪一天", selection: $pendingDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().tint(Paper.accent).padding(16).accessibilityIdentifier("todayCalendar")
                }.background(Paper.background).navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showsDatePicker = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("查看") { selectDate(pendingDate); showsDatePicker = false }.accessibilityIdentifier("todayDateConfirm") }
                    }
            }.environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
        }
    }
    private func selectDate(_ date: Date) {
        selectedDate = model.calendar.isDate(date, inSameDayAs: model.now) ? nil : model.calendar.startOfDay(for: date)
        showsAllUpcoming = false
    }
    private func moveWeek(_ offset: Int) {
        guard let day = model.calendar.date(byAdding: .day, value: offset * 7, to: date) else { return }
        selectDate(day)
    }
    @ViewBuilder private var emptySchedule: some View {
        if model.library.cards.isEmpty {
            PaperEmptyState(title: "从一件小事开始", message: "想做的事、忽然想到的话，\n都可以从下方“记一件事”留下。", scene: .beginning)
            CaptureSuggestions()
        } else if active.contains(where: { $0.card.kind == .task && !$0.card.isUndatedTask && $0.state == .completed && $0.occurrence?.plannedAt.map { model.calendar.isDate($0, inSameDayAs: date) } == true }) {
            PaperEmptyState(title: selectedDate == nil ? "今天的安排都完成了" : "这一天的安排都完成了", message: "做过的小事，已留在回顾里。\n慢下来，给自己留一点时间。", scene: .quiet, actionTitle: "看看回顾", action: { model.selectedTab = .review })
        } else if selectedDate != nil {
            PaperEmptyState(title: "这一天没有安排", message: "留白也是一种安排。\n其他日期的事情还在原来的位置。", scene: .calendar, actionTitle: "回到今天", action: { selectDate(model.now) })
        } else {
            PaperEmptyState(title: "暂时没有定时安排", message: active.contains(where: { $0.card.isUndatedTask && $0.state == .pending }) ? "还有一些不赶时间的事，\n可以到卡片里慢慢安排。" : "留一点空白，按自己的节奏生活。\n有新的念头时，再记下来。", scene: .quiet, actionTitle: "看看卡片", action: { model.selectedTab = .cards })
        }
    }
    private func groupLabel(_ projection: CardProjection) -> String {
        guard let planned = projection.occurrence?.plannedAt else { return "之后的安排" }
        if model.calendar.isDate(planned, inSameDayAs: date) { return "今天的安排" }
        return planned < model.calendar.startOfDay(for: date) ? "之前待处理" : "之后的安排"
    }

}

private extension CardProjection {
    var browsingID: String { occurrence?.id ?? card.id.uuidString }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var searchText = ""
    @State private var showsSearch = false
    @State private var kind: CardKind?
    @State private var scopeFilter = "全部"
    private let filters = ["全部", "有提醒", "长期待办", "重要日子", "已完成", "已归档"]
    private var cards: [CardProjection] {
        model.projections.filter { p in
            !p.card.isMemory && (kind == nil || p.card.kind == kind) && p.card.lifecycle != .deleted &&
            (searchText.isEmpty || p.card.title.localizedCaseInsensitiveContains(searchText) || p.card.note.localizedCaseInsensitiveContains(searchText)) &&
            (scopeFilter == "已归档" ? p.card.lifecycle == .archived : p.card.lifecycle == .active) &&
            (scopeFilter != "有提醒" || p.card.reminders.isEnabled) && (scopeFilter != "长期待办" || p.card.isUndatedTask) &&
            (scopeFilter != "重要日子" || p.card.birthday != nil) &&
            (scopeFilter != "已完成" || p.state == .completed)
        }.sorted(by: CardProjection.libraryOrder)
    }
    var body: some View {
        let cards = self.cards
        LazyVStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PaperTabs(labels: ["全部", "待办", "随手记"], selection: kind?.title ?? "全部") { label in kind = CardKind.allCases.first { $0.title == label } }
                PaperIconButton(symbol: "magnifyingglass", label: "搜索卡片") { showsSearch = true; searchFocused = true }
            }
            if showsSearch || !searchText.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("找一件事、一段话…", text: $searchText).focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }.accessibilityIdentifier("cardSearch")
                    Button { searchText = ""; showsSearch = false; searchFocused = false } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("关闭搜索")
                }.foregroundColor(Paper.secondary).padding(12).paperCard(radius: 13)
                    .onAppear { if showsSearch { searchFocused = true } }
            }
            HStack {
                Text(scopeFilter == "已完成" || scopeFilter == "已归档" ? "最近更新" : "未完成优先").font(Paper.text(16)).foregroundColor(Paper.secondary); Spacer()
                Menu { Picker("筛选", selection: $scopeFilter) { ForEach(filters, id: \.self) { Text($0) } } } label: {
                    HStack(spacing: 7) { PaperSymbol("filter").scaleEffect(0.8); Text(scopeFilter == "全部" ? "筛选" : scopeFilter) }.font(Paper.text(15)).foregroundColor(Paper.secondary)
                }.accessibilityIdentifier("libraryFilter")
            }.frame(minHeight: 32).padding(.top, 3)
            if cards.isEmpty { emptyLibrary }
            ForEach(cards) { p in CardTile(projection: p, compact: true, libraryStyle: true, onOpen: { model.selectedCard = p.card }, onComplete: { model.complete(p) }) }
        }
    }
    @ViewBuilder private var emptyLibrary: some View {
        if !searchText.isEmpty {
            PaperEmptyState(title: "没有找到这件事", message: "试试短一点的关键词，\n或清除关键词和筛选后重新看看。", scene: .search, actionTitle: "查看全部卡片", action: resetFilters)
        } else if scopeFilter != "全部" {
            PaperEmptyState(title: scopeFilter == "已归档" ? "还没有归档卡片" : scopeFilter == "已完成" ? "还没有完成的卡片" : scopeFilter == "长期待办" ? "还没有长期待办" : scopeFilter == "重要日子" ? "还没有重要日子" : "还没有开启提醒的卡片", message: scopeFilter == "已归档" ? "暂时放下的事可以归档，\n需要时，再把它放回生活里。" : "这里只显示符合当前筛选的卡片。\n其他记录都还在。", scene: scopeFilter == "已归档" ? .archive : .search, actionTitle: "查看全部卡片", action: resetFilters)
        } else if let kind {
            PaperEmptyState(title: kind == .note ? "留住一个小念头" : "还没有待办", message: kind == .note ? "一句话、一段灵感，\n不用设日期，也值得留在这里。" : "把想做的事记下来，\n可以定个时间，也可以慢慢完成。", scene: kind == .note ? .beginning : .calendar, actionTitle: "查看全部卡片", action: resetFilters)
        } else {
            PaperEmptyState(title: model.library.cards.isEmpty ? "第一张卡片，留给生活" : "这里暂时没有卡片", message: model.library.cards.isEmpty ? "待办、灵感与重要的日子，\n从下方“记一件事”开始。" : "归档或删除的记录可以在设置里查看。\n也可以记下一件新的小事。", scene: .beginning)
            CaptureSuggestions()
        }
    }
    private func resetFilters() {
        kind = nil; scopeFilter = "全部"; searchText = ""; showsSearch = false; searchFocused = false
    }
}
