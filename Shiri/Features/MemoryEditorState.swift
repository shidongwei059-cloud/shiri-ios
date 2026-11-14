import SwiftUI
import ShiriCore

@MainActor
final class MemoryEditorState: ObservableObject {
    @Published var draft = CardDraft(card: Card(title: "", kind: .note, now: Date()))
    @Published var initialized = false
    @Published var recovered = false
    @Published var busy = false
    @Published var error: String?
    @Published var draftStatus = ""
    private var baseline: CardDraft?
    private var pendingWrite: Task<Void, Never>?

    var dirty: Bool { initialized && (recovered || baseline != draft) }
    var canSave: Bool {
        initialized && !busy && draft.card.title.count <= AppLimits.titleLength && draft.card.note.count <= AppLimits.noteLength &&
        (!draft.card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !MemoryFactory.suggestedTitle(note: draft.card.note, hasPhotos: !draft.attachments.isEmpty).isEmpty)
    }

    func load(model: AppModel, initialDate: Date, occasionID: UUID?, source: MemoryCandidate?, editing: Card?, previous: Card?, restoring: CardDraft?, allowRecovery: Bool = true) async {
        guard !initialized else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let repository = model.repository else { throw ShiriError.unavailable("正在读取回忆，请稍后重试") }
            let existing = try await repository.drafts()
            if let saved = restoring ?? (allowRecovery ? MemoryDrafts.matching(existing, editingID: editing?.id, source: source, previousID: previous?.id, occasionID: occasionID) : nil) {
                draft = saved; recovered = true; draftStatus = "已恢复上次草稿"
            } else if let editing {
                guard let current = model.library.cards.first(where: { $0.id == editing.id && $0.lifecycle != .deleted }) else { throw ShiriError.notFound }
                draft = CardDraft(card: current, isEditing: true)
                let photos = try await repository.attachments(cardID: current.id)
                draft.attachments = try current.attachmentIDs.map { id in
                    guard let photo = photos.first(where: { $0.id == id }) else { throw ShiriError.storage("照片尚未读取完整，请重试。原回忆仍保留。") }
                    return photo
                }
            } else if let source {
                draft = try MemoryFactory.draft(from: source.card, attachments: await repository.attachments(cardID: source.card.id), occurrence: source.occurrence, date: initialDate, now: model.now)
            } else {
                var card = Card(title: "", kind: .note, now: model.now)
                card.memory = MemoryMetadata(previousMemoryID: previous?.id)
                card.category = previous?.category ?? "生活"
                card.occasionLink = previous?.occasionLink
                if let occasionID { card.occasionLink = OccasionLink(cardID: occasionID, date: CivilDate(initialDate, calendar: model.calendar)) }
                draft = CardDraft(card: card)
            }
            draft.card.memoryDate = min(draft.card.memoryDate ?? initialDate, model.now)
            baseline = draft; initialized = true
        } catch { self.error = error.localizedDescription }
    }

    func autosave(model: AppModel, immediately: Bool = false) {
        guard initialized, !busy, dirty || pendingWrite != nil, let repository = model.repository else { return }
        var snapshot = draft; snapshot.updatedAt = model.now
        let previous = pendingWrite
        previous?.cancel()
        draftStatus = "正在保存草稿…"
        pendingWrite = Task {
            await previous?.value
            do {
                if !immediately { try await Task.sleep(nanoseconds: 350_000_000) }
                try Task.checkCancellation()
                if MemoryDrafts.hasContent(snapshot) { try await repository.saveDraft(snapshot) }
                else { try await repository.deleteDeviceRecord(entity: "DraftRecord", id: snapshot.id) }
                if !Task.isCancelled { draftStatus = MemoryDrafts.hasContent(snapshot) ? "草稿已保存在本机" : "空白草稿已清除" }
            } catch is CancellationError { }
            catch { self.error = "草稿暂存失败，请重试：\(error.localizedDescription)"; draftStatus = "草稿尚未保存" }
        }
    }

    /// Drain writes before deletion or a confirmed save, so a late autosave cannot resurrect a draft.
    private func drain() async { pendingWrite?.cancel(); await pendingWrite?.value; pendingWrite = nil }

    func keep(model: AppModel) async -> Bool {
        busy = true; await drain(); defer { busy = false }
        do {
            guard let repository = model.repository else { throw ShiriError.unavailable("暂时无法保存草稿") }
            draft.updatedAt = model.now
            if MemoryDrafts.hasContent(draft) { try await repository.saveDraft(draft) }
            else { try await repository.deleteDeviceRecord(entity: "DraftRecord", id: draft.id) }
            draftStatus = MemoryDrafts.hasContent(draft) ? "草稿已保存在本机" : "空白草稿已清除"; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func discard(model: AppModel) async -> Bool {
        busy = true; await drain(); defer { busy = false }
        do {
            guard let repository = model.repository else { throw ShiriError.unavailable("暂时无法处理草稿") }
            try await repository.deleteDeviceRecord(entity: "DraftRecord", id: draft.id)
            baseline = draft; recovered = false; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func save(model: AppModel) async -> Card? {
        guard canSave else { return nil }
        busy = true; error = nil; await drain(); defer { busy = false }
        do {
            guard let commands = model.commands, let repository = model.repository else { throw ShiriError.unavailable("正在读取回忆，请稍后再试") }
            // Persist first, including the original revision, so any conflict leaves a recoverable draft.
            draft.updatedAt = model.now; try await repository.saveDraft(draft)
            if !draft.isEditing, let metadata = draft.card.memory, let sourceID = metadata.sourceCardID,
               model.library.cards.contains(where: { $0.lifecycle != .deleted && $0.memory?.sourceCardID == sourceID && $0.memory?.sourceOccurrenceID == metadata.sourceOccurrenceID }) {
                throw ShiriError.conflict("这次经历已经留成回忆，请从来源事项查看已有回忆。草稿已保留。")
            }
            var confirmed = draft
            if confirmed.card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { confirmed.card.title = MemoryFactory.suggestedTitle(note: confirmed.card.note, hasPhotos: !confirmed.attachments.isEmpty) }
            if confirmed.card.occasionLink != nil, let date = confirmed.card.memoryDate { confirmed.card.occasionLink?.date = CivilDate(date, calendar: model.calendar) }
            let card = try await commands.save(confirmed, now: model.now)
            baseline = draft; recovered = false
            model.lastSavedMemory = card
            await model.refresh()
            return card
        } catch { self.error = error.localizedDescription; return nil }
    }
}
