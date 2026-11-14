import SwiftUI
import ShiriCore

struct MemoryReunionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var reunion: Card?
    @State private var skipped: MemoryReunionSkip?
    @State private var refresh = 0
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.preferences.showsMemoryReunion != false, let reunion {
                VStack(alignment: .leading, spacing: 12) {
                    (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())) {
                        Label("重逢", systemImage: "sparkle").font(.headline).fixedSize(horizontal: true, vertical: false)
                        if !typeSize.isAccessibilitySize { Spacer() }
                        Text(caption(reunion)).font(.subheadline).foregroundColor(Paper.secondary)
                    }
                    NavigationLink { MemoryDetailView(cardID: reunion.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(reunion.title).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            Text(CardPresentation.dateLabel(reunion.memoryDate ?? reunion.createdAt, format: "yyyy年M月d日")).font(.caption).foregroundColor(Paper.secondary)
                            if !reunion.note.isEmpty { Text(reunion.note).font(.subheadline).foregroundColor(Paper.secondary).lineLimit(2) }
                            Text("看看那一天").font(.subheadline).foregroundColor(Paper.accent)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).paperCard(radius: 18)
                    }.buttonStyle(.plain).accessibilityIdentifier("memoryReunion")
                    Menu {
                        Button("今天先不看") { skip(reunion) }.accessibilityIdentifier("skipMemoryReunionToday")
                        Button("不再推荐这段回忆") { exclude(reunion) }
                    } label: { Label("重逢偏好", systemImage: "ellipsis").font(.subheadline).frame(minHeight: 44) }.disabled(busy).accessibilityIdentifier("memoryReunionActions")
                }
            }
            if let error { PaperErrorBanner(message: error) }
        }.task(id: "\(model.snapshotRevision)|\(CivilDate(model.now, calendar: model.calendar).key)|\(refresh)|\(model.preferences.showsMemoryReunion != false)") {
            guard model.preferences.showsMemoryReunion != false else { reunion = nil; error = nil; return }
            do {
                skipped = try await model.repository?.deviceValue(MemoryReunionSkip.self, key: "memory-reunion-skip")
                reunion = MemoryCollection.reunion(in: MemoryCollection.cards(in: model.library), now: model.now, calendar: model.calendar, skippedIDs: skipped?.skippedIDs(on: model.now, calendar: model.calendar) ?? [])
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private func caption(_ card: Card) -> String {
        guard let date = card.memoryDate else { return "翻翻以前的回忆" }
        if model.calendar.component(.month, from: date) == model.calendar.component(.month, from: model.now), model.calendar.component(.day, from: date) == model.calendar.component(.day, from: model.now) {
            let years = model.calendar.component(.year, from: model.now) - model.calendar.component(.year, from: date)
            return years == 1 ? "去年的今天" : "\(years) 年前的今天"
        }
        return "以前留下的一段回忆"
    }
    private func skip(_ card: Card) {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let repository = model.repository else { throw ShiriError.unavailable("暂时无法保存偏好") }
                var value = MemoryReunionSkip(day: CivilDate(model.now, calendar: model.calendar), cardIDs: skipped?.skippedIDs(on: model.now, calendar: model.calendar) ?? [])
                value.cardIDs.insert(card.id)
                try await repository.setDeviceValue(value, key: "memory-reunion-skip"); skipped = value; refresh += 1
            } catch { self.error = error.localizedDescription }
        }
    }
    private func exclude(_ card: Card) {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let commands = model.commands else { throw ShiriError.unavailable("暂时无法保存偏好") }
                var changed = card; changed.memory?.excludedFromReunion = true
                _ = try await commands.save(CardDraft(card: changed, isEditing: true), now: model.now)
                await model.refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
}
