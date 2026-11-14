import SwiftUI
import ShiriCore

struct MemoryBookView: View {
    var interval: DateInterval?
    var occasionID: UUID?
    var sourceCardID: UUID?
    var embedded = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var category: String?
    @State private var allDates = true
    @State private var month: Date?
    @State private var collection: [Card] = []
    @State private var results: [Card] = []
    @State private var drafts: [CardDraft] = []
    @State private var limit = 40
    @State private var loading = true
    @State private var error: String?
    @State private var sheet: MemoryBookSheet?
    @State private var reload = 0
    @State private var focusID: UUID?
    @State private var monthCounts: [Date: Int] = [:]
    @FocusState private var searching: Bool
    private var selectedInterval: DateInterval? {
        if let month { return model.calendar.dateInterval(of: .month, for: month) }
        return allDates ? nil : interval
    }
    private var filterID: String { "\(model.snapshotRevision)|\(query)|\(category ?? "")|\(selectedInterval?.start.timeIntervalSince1970 ?? 0)|\(reload)" }
    private var groups: [MemoryMonth] { MemoryMonth.group(Array(results.prefix(limit)), calendar: model.calendar) }
    private var months: [MemoryMonth] { MemoryMonth.group(collection, calendar: model.calendar) }
    private var hasFilter: Bool { selectedInterval != nil || category != nil || !query.isEmpty }
    private var hasRangeFilter: Bool { selectedInterval != nil || category != nil }
    var body: some View {
        Group {
            if embedded { content }
            else {
                NavigationStack {
                    content.navigationTitle(occasionID == nil ? "回忆册" : "这个日子的回忆").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("memoryBookDone") } }
                }
            }
        }
    }
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    filters
                    if !drafts.isEmpty {
                        HStack(alignment: .top) {
                            Button { sheet = .compose(drafts[0]) } label: {
                                Label("继续上次记录 · " + MemoryDrafts.title(drafts[0]), systemImage: "doc.text").multilineTextAlignment(.leading).frame(minHeight: 44)
                            }.accessibilityIdentifier("resumeMemoryDraft")
                            if drafts.count > 1 { Button("全部草稿") { sheet = .drafts }.frame(minHeight: 44) }
                        }.font(.subheadline).padding(12).paperCard(radius: 14)
                    }
                    if let error { PaperErrorBanner(message: error) }
                    if loading { ProgressView("正在读取回忆…").accessibilityIdentifier("memoryLoading") }
                    if !loading && results.isEmpty { emptyState }
                    ForEach(groups) { group in
                        HStack(alignment: .firstTextBaseline) {
                            Text(CardPresentation.dateLabel(group.id, format: "yyyy年M月")).font(.headline)
                            Spacer()
                            Text("\(monthCounts[group.id] ?? group.cards.count) 段").font(.caption).foregroundColor(Paper.secondary)
                        }.accessibilityAddTraits(.isHeader)
                        ForEach(group.cards) { card in
                            NavigationLink { MemoryDetailView(cardID: card.id) } label: { MemoryCardView(card: card, compact: true) }
                                .buttonStyle(.plain).id(card.id).accessibilityIdentifier("memoryCard_" + card.id.uuidString)
                            if card.id == results.first?.id && !hasFilter && occasionID == nil && sourceCardID == nil { MemoryReunionView() }
                        }
                    }
                    if results.count > limit { Button("再翻一些 · 还有 \(results.count - limit) 段") { limit += 40 }.frame(maxWidth: .infinity, minHeight: 48).accessibilityIdentifier("memoryLoadMore") }
                }.padding(embedded ? 16 : 20)
            }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("memoryBookScroll")
                .background { PaperSurface().ignoresSafeArea() }.foregroundColor(Paper.ink)
                .safeAreaInset(edge: .bottom, spacing: 0) { writeBar }
                .task(id: filterID) { await filter() }
                .onChange(of: model.lastSavedMemory?.revisionID) { _ in
                    guard let saved = model.lastSavedMemory else { return }
                    query = ""; category = nil; allDates = true; month = model.calendar.startOfDay(for: saved.memoryDate ?? model.now)
                    focusID = saved.id
                }
                .onChange(of: results.map(\.id)) { _ in if let focusID { proxy.scrollTo(focusID, anchor: .top) } }
                .sheet(item: $sheet, onDismiss: { reload += 1; if let focusID { proxy.scrollTo(focusID, anchor: .top) } }) { destination in
                    switch destination {
                    case .compose(let draft): MemoryComposerView(occasionID: occasionID, initialDate: model.now, restoring: draft)
                    case .choose: MemorySourcePicker(interval: selectedInterval, occasionID: occasionID)
                    case .export: MemoryExportView(cards: results)
                    case .excluded: MemoryExcludedView()
                    case .drafts: MemoryDraftListView()
                    case .month:
                        MemoryMonthPicker(months: months.map(\.id), selected: month) { value in month = value; allDates = value == nil; sheet = nil }
                    }
                }
        }
    }
    private var writeBar: some View {
        Button { searching = false; sheet = .compose(nil) } label: { Label("写回忆", systemImage: "plus") }
            .buttonStyle(PaperPrimaryButton()).accessibilityIdentifier(embedded ? "reviewNewMemory" : "newMemory")
            .padding(.horizontal, 16).padding(.vertical, 8).background(Paper.background)
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("搜索回忆", text: $query).focused($searching).submitLabel(.search).onSubmit { searching = false }.accessibilityLabel("搜索回忆标题、正文或主题").accessibilityIdentifier("memorySearch")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("清空搜索") }
                }.padding(.horizontal, 12).frame(minHeight: 48).paperCard(radius: 12)
                Menu {
                    Button("从完成事项或随手记中选择") { sheet = .choose }.accessibilityIdentifier("chooseMemories")
                    Button("制作回忆册 PDF") { sheet = .export }.disabled(results.isEmpty).accessibilityIdentifier("exportMemoryBook")
                    Button("回忆草稿") { sheet = .drafts }
                    Toggle("展示重逢", isOn: Binding(get: { model.preferences.showsMemoryReunion != false }, set: { model.preferences.showsMemoryReunion = $0; model.perform { try await model.savePreferences() } }))
                    Button("不再推荐的回忆") { sheet = .excluded }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("回忆更多操作").accessibilityIdentifier("memoryActions")
            }
            ViewThatFits(in: .horizontal) {
                HStack { dateFilter; themeFilter; Spacer(minLength: 0); resultCount }
                VStack(alignment: .leading, spacing: 4) { dateFilter; themeFilter; resultCount }
            }
        }
    }
    private var dateFilter: some View {
        Menu {
            Button("全部日期") { month = nil; allDates = true }
            if interval != nil { Button("回顾所选日期") { month = nil; allDates = false } }
            Button("选择月份…") { sheet = .month }
        } label: {
            Label(dateFilterTitle, systemImage: "calendar").font(.subheadline).frame(minHeight: 44)
        }.accessibilityIdentifier("memoryDateFilter")
    }
    private var dateFilterTitle: String {
        if let month { return CardPresentation.dateLabel(month, format: "yyyy年M月") }
        guard let interval = selectedInterval else { return "全部日期" }
        let end = interval.end.addingTimeInterval(-1)
        let sameYear = model.calendar.component(.year, from: interval.start) == model.calendar.component(.year, from: end)
        return CardPresentation.dateLabel(interval.start, format: "yyyy年M月d日") + "–" + CardPresentation.dateLabel(end, format: sameYear ? "M月d日" : "yyyy年M月d日")
    }
    private var themeFilter: some View {
        Menu {
            Button("全部主题") { category = nil }.accessibilityIdentifier("memoryTheme_all")
            ForEach(Array(Set(collection.map(\.category))).sorted(), id: \.self) { theme in Button(theme) { category = theme }.accessibilityIdentifier("memoryTheme_" + theme) }
        } label: { Label(category ?? "全部主题", systemImage: "line.3.horizontal.decrease").font(.subheadline).frame(minHeight: 44) }.accessibilityIdentifier("memoryThemeFilter")
    }
    private var resultCount: some View {
        Text(hasFilter ? "\(results.count) / 共 \(collection.count) 段" : "共 \(collection.count) 段")
            .font(.caption).foregroundColor(Paper.secondary).accessibilityIdentifier("memoryResultCount")
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(collection.isEmpty ? "留下第一段回忆" : "当前筛选下没有回忆").font(.headline)
            Text(collection.isEmpty ? "一句话或一张照片就可以。也能从做过的事里选一个片刻。" : "回忆仍在册中，可以换个范围继续找。").font(.subheadline).foregroundColor(Paper.secondary)
            if hasFilter && !collection.isEmpty {
                Button {
                    if !hasRangeFilter { query = "" }
                    month = nil; allDates = true; category = nil
                } label: { Text(query.isEmpty ? "查看全部回忆" : hasRangeFilter ? "在全部回忆中搜索" : "清空搜索").frame(minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("memoryResetFilters")
                if !query.isEmpty && hasRangeFilter { Button { query = ""; month = nil; allDates = true; category = nil } label: { Text("清除全部筛选").frame(minHeight: 44).contentShape(Rectangle()) } }
            } else { Button { sheet = .choose } label: { Text("从已有记录选择").frame(minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("chooseMemories") }
        }.padding(18).paperCard(radius: 18)
    }
    @MainActor private func filter() async {
        loading = true; error = nil
        let library = model.library, text = query, theme = category, range = selectedInterval, occasion = occasionID, source = sourceCardID, calendar = model.calendar
        do {
            if !text.isEmpty { try await Task.sleep(nanoseconds: 160_000_000) }
            let value = await Task.detached(priority: .userInitiated) {
                let all = MemoryCollection.cards(in: library, occasionID: occasion).filter { source == nil || $0.memory?.sourceCardID == source }
                let filtered = MemoryCollection.filtered(all, query: text, category: theme, interval: range)
                let counts = Dictionary(grouping: filtered) { calendar.dateInterval(of: .month, for: $0.memoryDate ?? $0.createdAt)?.start ?? $0.createdAt }.mapValues(\.count)
                return (all, filtered, counts)
            }.value
            let pending = try await model.repository?.drafts() ?? []
            guard !Task.isCancelled else { return }
            collection = value.0; results = value.1; monthCounts = value.2; limit = 40
            drafts = pending.filter { $0.card.isMemory && (occasion == nil || $0.card.occasionLink?.cardID == occasion) && (source == nil || $0.card.memory?.sourceCardID == source) }
            loading = false
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
    }
}

private enum MemoryBookSheet: Identifiable {
    case compose(CardDraft?), choose, export, excluded, drafts, month
    var id: String { switch self { case .compose(let draft): return "compose-" + (draft?.id.uuidString ?? "new"); case .choose: return "choose"; case .export: return "export"; case .excluded: return "excluded"; case .drafts: return "drafts"; case .month: return "month" } }
}
struct MemoryMonth: Identifiable {
    let id: Date
    let cards: [Card]
    static func group(_ cards: [Card], calendar: Calendar) -> [Self] {
        Dictionary(grouping: cards) { calendar.dateInterval(of: .month, for: $0.memoryDate ?? $0.createdAt)?.start ?? $0.createdAt }
            .map { Self(id: $0.key, cards: $0.value) }.sorted { $0.id > $1.id }
    }
}
private struct MemoryMonthPicker: View {
    let months: [Date]
    var selected: Date?
    var choose: (Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button("全部日期") { choose(nil) }
                ForEach(months, id: \.self) { month in
                    Button { choose(month) } label: {
                        HStack { Text(CardPresentation.dateLabel(month, format: "yyyy年M月")); Spacer(); if selected.map({ Calendar.current.isDate($0, equalTo: month, toGranularity: .month) }) == true { Image(systemName: "checkmark") } }
                    }
                }
            }.navigationTitle("翻到哪个月").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("memoryMonthPicker")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct MemorySourcePicker: View {
    var interval: DateInterval?
    var occasionID: UUID?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MemoryCandidate] = []
    @State private var writing: SourceWriteRequest?
    @State private var allDates = false
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var limit = 40
    private var results: [MemoryCandidate] { candidates.filter { query.isEmpty || ($0.title + " " + $0.card.note).localizedStandardContains(query) } }
    var body: some View {
        NavigationStack {
            List {
                TextField("搜索已完成事项和随手记", text: $query).focused($searching).submitLabel(.search).onSubmit { searching = false }.accessibilityIdentifier("memorySourceSearch")
                if interval != nil { Toggle("查看全部日期", isOn: $allDates) }
                if results.isEmpty {
                    Text(query.isEmpty ? "还没有可选记录，可以直接写一段回忆。" : "没有找到匹配的记录。")
                    Button("直接写回忆") { writing = SourceWriteRequest() }.accessibilityIdentifier("memorySourceCreate")
                }
                ForEach(Array(results.prefix(limit))) { candidate in
                    if let saved = MemoryCollection.savedMemory(for: candidate, in: model.library.cards) {
                        NavigationLink { MemoryDetailView(cardID: saved.id) } label: { sourceRow(candidate, saved: true) }.accessibilityIdentifier("memorySource_" + candidate.id)
                    } else {
                        Button { writing = SourceWriteRequest(candidate: candidate) } label: { sourceRow(candidate, saved: false) }.accessibilityIdentifier("memorySource_" + candidate.id)
                    }
                }
                if results.count > limit { Button("查看更多记录") { limit += 40 } }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("从记录留成回忆").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task(id: "\(model.snapshotRevision)-\(allDates)") {
                    let library = model.library, range = allDates ? nil : interval, now = model.now, occasion = occasionID
                    let value = await Task.detached { MemoryCollection.candidates(in: library, interval: range, now: now).filter { occasion == nil || $0.card.occasionLink?.cardID == occasion || $0.card.id == occasion } }.value
                    guard !Task.isCancelled else { return }; candidates = value
                }
                .onChange(of: query) { _ in limit = 40 }
                .sheet(item: $writing) { request in MemoryComposerView(occasionID: occasionID, initialDate: request.candidate?.date ?? model.now, source: request.candidate) }
        }
    }
    private func sourceRow(_ candidate: MemoryCandidate, saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.title).foregroundColor(Paper.ink)
            Text(CardPresentation.dateLabel(candidate.date, format: "yyyy年M月d日") + (saved ? " · 查看已有回忆" : " · 留成回忆")).font(.caption).foregroundColor(Paper.secondary)
        }.padding(.vertical, 6)
    }
    private struct SourceWriteRequest: Identifiable { let id = UUID(); var candidate: MemoryCandidate? }
}

struct MemoryDraftListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [CardDraft] = []
    @State private var selected: CardDraft?
    @State private var reload = 0
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { PaperErrorBanner(message: error) }
                if drafts.isEmpty { Text("还没有未写完的回忆。记录时会自动保存草稿。") }
                ForEach(drafts) { draft in Button { selected = draft } label: { VStack(alignment: .leading, spacing: 6) { Text(MemoryDrafts.title(draft)); Text(draft.isEditing ? "编辑中的回忆" : "尚未保存为回忆").font(.caption).foregroundColor(Paper.secondary) } } }
            }.navigationTitle("回忆草稿").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task(id: reload) { do { drafts = try await model.repository?.drafts().filter { $0.card.isMemory } ?? [] } catch { self.error = error.localizedDescription } }
                .sheet(item: $selected, onDismiss: { reload += 1 }) { draft in MemoryComposerView(initialDate: draft.card.memoryDate ?? model.now, restoring: draft) }
        }
    }
}
