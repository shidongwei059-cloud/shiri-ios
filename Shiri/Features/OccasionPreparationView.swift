import SwiftUI
import ShiriCore

struct OccasionPreparationView: View {
    let cardID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [PreparationChoice] = []
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var error: String?
    @State private var savedMessage: String?
    private var parent: Card? { model.library.cards.first { $0.id == cardID } }
    private var target: Date? { parent.flatMap { OccasionPlanner.nextDate(for: $0, now: model.now, calendar: model.calendar) } }
    private var related: [Card] { model.library.cards.filter { $0.occasionLink?.cardID == cardID && $0.occasionLink?.templateID != nil && $0.lifecycle != .deleted } }
    var body: some View {
        NavigationStack {
            Form {
                if let parent, let target {
                    Section {
                        Text(parent.title).font(Paper.title(24))
                        Text("这一次：" + CardPresentation.dateLabel(target, format: "yyyy年M月d日 EEEE"))
                        Text("选几件想做的准备，确认时间后一起加入卡片。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                    ForEach($choices) { $choice in
                        Section {
                            let added = wasAdded(choice, target: target)
                            Toggle(isOn: Binding(get: { selected.contains(choice.id) }, set: { if $0 { selected.insert(choice.id) } else { selected.remove(choice.id) } })) {
                                Text(added ? choice.title + " · 已添加" : choice.title)
                            }.disabled(added || parent.lifecycle != .active).accessibilityIdentifier("prepare_" + choice.id)
                            if selected.contains(choice.id) && !added {
                                TextField("准备事项", text: $choice.title)
                                Stepper("提前 \(choice.daysBefore) 天", value: $choice.daysBefore, in: 0...365)
                                DatePicker("时间", selection: timeBinding($choice), displayedComponents: .hourAndMinute)
                                Toggle("到时提醒我", isOn: $choice.reminds)
                                Text(previewDate(choice, target: target)).font(.footnote).foregroundColor(Paper.secondary)
                            }
                        }
                    }
                    if let savedMessage { Section { Label(savedMessage, systemImage: "checkmark.circle").accessibilityIdentifier("preparationSaved") } }
                    if let error { Section { Text(error).foregroundColor(Paper.accent).accessibilityIdentifier("preparationError") } }
                    Section {
                        Button { save(parent: parent, target: target) } label: {
                            if busy { ProgressView() } else { Text("确认添加 \(selected.count) 件准备") }
                        }.disabled(selected.isEmpty || busy || parent.lifecycle != .active).accessibilityIdentifier("savePreparations")
                        Text("只添加这一次，保存在本机。修改重要日子的日期不会自动改动准备时间；每年可重新选择。主卡归档或删除后，准备事项仍保留。已删除的准备可在设置的“最近删除”中恢复。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                } else {
                    Section { Text("目前没有下一次日期。可以先检查重要日子的日期和重复规则。") }
                }
                if !related.isEmpty {
                    Section("已添加的准备") {
                        ForEach(related) { card in
                            Button { dismiss(); model.selectedCard = card } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(card.title)
                                    Text((card.occasionLink?.date.key ?? "") + " · " + (card.lifecycle == .archived ? "已归档" : "点击查看安排")).font(.caption).foregroundColor(Paper.secondary)
                                }
                            }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("为这个日子做准备")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { if choices.isEmpty { choices = PreparationChoice.suggestions(anniversary: parent?.birthday?.occasion == .anniversary) } }
        }
    }
    private func wasAdded(_ choice: PreparationChoice, target: Date) -> Bool {
        let id = OccasionPlanner.preparationID(parent: cardID, date: CivilDate(target, calendar: model.calendar), template: choice.id)
        return model.library.cards.contains { $0.id == id }
    }
    private func timeBinding(_ choice: Binding<PreparationChoice>) -> Binding<Date> {
        Binding(get: { OccurrenceEngine(calendar: model.calendar).date(CivilDate(model.now, calendar: model.calendar), time: choice.wrappedValue.time) ?? model.now },
                set: { choice.wrappedValue.time = DayTime(hour: model.calendar.component(.hour, from: $0), minute: model.calendar.component(.minute, from: $0)) })
    }
    private func previewDate(_ choice: PreparationChoice, target: Date) -> String {
        let day = model.calendar.date(byAdding: .day, value: -choice.daysBefore, to: target) ?? target
        return CardPresentation.dateLabel(day, format: "M月d日 EEEE") + " " + choice.time.display + (choice.reminds ? " · 将请求提醒" : " · 仅安排，不提醒")
    }
    private func save(parent: Card, target: Date) {
        guard !busy else { return }
        busy = true; error = nil; savedMessage = nil
        Task {
            do {
                guard let repository = model.repository else { throw ShiriError.unavailable("正在读取卡片，请稍后再试") }
                let cards = try await repository.createPreparations(parentID: parent.id, revisionID: parent.revisionID, date: CivilDate(target, calendar: model.calendar), choices: choices.filter { selected.contains($0.id) }, now: model.now, calendar: model.calendar)
                if let card = cards.first(where: { $0.reminders.isEnabled }) { await model.requestReminderPermission(for: card) }
                selected = []; await model.refresh()
                savedMessage = "已添加 \(cards.count) 件准备，可在下面查看，也可到卡片中调整和完成。"
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct OccasionDateSummary: View {
    var card: Card
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let next = OccasionPlanner.nextDate(for: card, now: model.now, calendar: model.calendar) {
                Label(CardPresentation.dateLabel(next, format: "yyyy年M月d日 EEEE"), systemImage: "calendar")
                let days = model.calendar.dateComponents([.day], from: model.calendar.startOfDay(for: model.now), to: model.calendar.startOfDay(for: next)).day ?? 0
                Text(days == 0 ? "就是今天" : "还有 \(days) 天").foregroundColor(Paper.accent)
                let plan = ReminderPlanner(calendar: model.calendar).plan(library: previewLibrary, preferences: model.preferences, now: model.now, capabilities: ReminderCapabilities(notificationsAllowed: true, alarmAllowed: true))
                if let nextReminder = plan.requests.filter({ $0.cardID == card.id }).min(by: { $0.firesAt < $1.firesAt }) {
                    Text("下次提醒安排：" + CardPresentation.dateLabel(nextReminder.firesAt, format: "M月d日 HH:mm"))
                } else { Text(card.reminders.isEnabled ? "请检查提醒时间" : "只记录日期，暂不提醒") }
            } else { Text("确认日期后，这里显示下一次公历日期和提醒安排。") }
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).paperCard(radius: 13).accessibilityElement(children: .combine).accessibilityIdentifier("occasionDateSummary")
    }
    private var previewLibrary: LibrarySnapshot { var library = LibrarySnapshot(); library.cards = [card]; return library }
}
