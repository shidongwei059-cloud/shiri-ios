import SwiftUI
import ShiriCore

struct MemoryAttachmentThumbnail: View {
    let attachment: Attachment
    var maximumPixelSize = 720
    var fills = true
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                if fills { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(uiImage: image).resizable().scaledToFit() }
            } else { Rectangle().fill(Paper.separator.opacity(0.3)).overlay { Image(systemName: "photo").foregroundColor(Paper.secondary) } }
        }.task(id: attachment.digest) {
            let loaded = await CardThumbnailCache.shared.image(data: attachment.data, cacheKey: attachment.digest, maximumPixelSize: maximumPixelSize)
            guard !Task.isCancelled else { return }; image = loaded
        }.accessibilityLabel("第 \(attachment.sortIndex + 1) 张回忆照片")
    }
}

private struct MemoryThumbnail: Identifiable { let id: UUID; let image: UIImage }

struct MemoryCardView: View {
    let card: Card
    var compact = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var model: AppModel
    @State private var photos: [MemoryThumbnail] = []
    @State private var photoUnavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(CardPresentation.dateLabel(card.memoryDate ?? card.createdAt, format: "M月d日 EEEE")).font(.caption).foregroundColor(Paper.secondary)
                Spacer(); Text(card.category).font(.caption).foregroundColor(Paper.accent)
            }
            Text(card.title).font(Paper.title(compact ? 21 : 25)).fixedSize(horizontal: false, vertical: true).lineLimit(typeSize.isAccessibilitySize ? nil : (compact ? 2 : 4))
            if !card.note.isEmpty { Text(card.note).font(Paper.text(15)).lineSpacing(5).foregroundColor(Paper.secondary).lineLimit(compact ? 2 : 4) }
            photoCollage
            if photoUnavailable { Label("照片暂未读取完整，点开重试", systemImage: "photo.badge.exclamationmark").font(.caption).foregroundColor(Paper.secondary) }
            HStack {
                if card.memory?.previousMemoryID != nil { Label("故事在继续", systemImage: "arrow.turn.down.right").font(.caption).foregroundColor(Paper.secondary) }
                Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundColor(Paper.accent)
            }
        }.foregroundColor(Paper.ink).padding(18).paperCard(radius: 20).contentShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .task(id: card.revisionID) {
                photos = []; photoUnavailable = false
                guard !card.attachmentIDs.isEmpty else { return }
                do {
                    guard let repository = model.repository else { throw ShiriError.notFound }
                    let all = try await repository.attachments(cardID: card.id)
                    var thumbnails: [MemoryThumbnail] = []
                    for id in card.attachmentIDs.prefix(compact ? 1 : 3) {
                        guard let attachment = all.first(where: { $0.id == id }),
                              let image = await CardThumbnailCache.shared.image(data: attachment.data, cacheKey: attachment.digest, maximumPixelSize: 720) else { continue }
                        thumbnails.append(MemoryThumbnail(id: id, image: image))
                        guard !Task.isCancelled else { return }
                    }
                    photos = thumbnails; photoUnavailable = thumbnails.count != min(compact ? 1 : 3, card.attachmentIDs.count)
                } catch { if !Task.isCancelled { photoUnavailable = true } }
            }
    }
    private var accessibilitySummary: String {
        let date = CardPresentation.dateLabel(card.memoryDate ?? card.createdAt, format: "yyyy年M月d日")
        let parts = [date, card.category, card.title, String(card.note.prefix(100))]
        return parts.joined(separator: "，") + (card.attachmentIDs.isEmpty ? "" : "，\(card.attachmentIDs.count) 张照片")
    }
    @ViewBuilder private var photoCollage: some View {
            if let first = photos.first {
                HStack(spacing: 5) {
                    Image(uiImage: first.image).resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: compact ? 130 : 195).clipped()
                    if photos.count > 1 && !compact {
                        VStack(spacing: 5) {
                            ForEach(Array(photos.dropFirst().prefix(2))) { photo in Image(uiImage: photo.image).resizable().scaledToFill().frame(width: 94, height: photos.count > 2 ? 95 : 195).clipped() }
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12)).overlay(alignment: .bottomTrailing) {
                    if card.attachmentIDs.count > 1 { Text("\(card.attachmentIDs.count) 张照片").font(.caption).foregroundColor(.white).padding(.horizontal, 9).padding(.vertical, 5).background(.black.opacity(0.6), in: Capsule()).padding(9) }
                }
            }
    }

}

struct MemoryDetailView: View {
    let cardID: UUID
    var savedNotice = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var continuing = false
    @State private var exporting = false
    @State private var deleting = false
    @State private var exportImages = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var photos: [Attachment] = []
    @State private var photo: Attachment?
    @State private var error: String?
    @State private var retry = 0
    @State private var busy = false
    private var card: Card? {
        let original = model.library.cards.first { $0.id == cardID && $0.lifecycle != .deleted }
        if let original, original.memoryDate == nil && !original.isMemory {
            return model.library.cards.first { $0.id == StableID.uuid("legacy-memory|\(cardID)") && $0.lifecycle != .deleted }
        }
        return original
    }
    var body: some View {
        ScrollView {
            if let card {
                VStack(alignment: .leading, spacing: 22) {
                    if savedNotice { Label("已保存回忆", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundColor(Paper.accent).accessibilityIdentifier("memorySavedNotice") }
                    (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
                        Text(CardPresentation.dateLabel(card.memoryDate ?? card.createdAt, format: "yyyy年M月d日 EEEE"))
                        Spacer(); Text(card.category).foregroundColor(Paper.accent)
                    }.font(.subheadline).foregroundColor(Paper.secondary)
                    Text(card.title).font(Paper.title(32)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("memoryDetailTitle")
                    if !card.note.isEmpty { Text(card.note).font(Paper.text(18)).lineSpacing(8).textSelection(.enabled).accessibilityIdentifier("memoryDetailNote") }
                    ForEach(photos) { attachment in
                        Button { photo = attachment } label: { MemoryAttachmentThumbnail(attachment: attachment, maximumPixelSize: 1200, fills: false).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 16)) }
                            .buttonStyle(.plain).accessibilityLabel("查看第 \(attachment.sortIndex + 1) 张照片").accessibilityIdentifier("memoryDetailPhoto_\(attachment.sortIndex)")
                    }
                    if let error { PaperErrorBanner(message: error); Button("重新读取照片") { retry += 1 } }
                    Divider()
                    storyLinks(card)
                    if !card.isMemory {
                        Text("这份旧收藏还在等待照片读取完整，原卡片仍保留。整理完成后即可补写、续写或移除回忆。").font(.footnote).foregroundColor(Paper.secondary)
                        Button("重新整理旧回忆") { Task { await model.refresh() } }.frame(minHeight: 44)
                    }
                    Button { continuing = true } label: { Label("写后续", systemImage: "arrow.turn.down.right").frame(maxWidth: .infinity, minHeight: 48) }.disabled(!card.isMemory).accessibilityIdentifier("continueMemory")
                    Text("新建一篇后续，和这段回忆连在一起。").font(.footnote).foregroundColor(Paper.secondary)
                    Button { exportImages = true; exporting = true } label: { Label("生成回忆图片", systemImage: "photo") }.buttonStyle(PaperPrimaryButton()).accessibilityIdentifier("shareMemory")
                }.padding(22)
            } else { PaperEmptyState(title: "这段回忆已移到最近删除", message: "可在设置中的最近删除里恢复。", scene: .review, actionTitle: "返回", action: { dismiss() }).padding(20) }
        }.background { PaperSurface().ignoresSafeArea() }.foregroundColor(Paper.ink)
            .navigationTitle("这一刻").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let card {
                        Button("编辑") { editing = true }.disabled(!card.isMemory).accessibilityLabel("编辑回忆").accessibilityIdentifier("editMemory")
                        Menu {
                            Button("写后续") { continuing = true }.accessibilityIdentifier("memoryDetailContinue")
                            Button("生成回忆图片") { exportImages = true; exporting = true }.accessibilityIdentifier("memoryDetailImageExport")
                            Button("制作回忆册 PDF") { exportImages = false; exporting = true }.accessibilityIdentifier("memoryDetailPDFExport")
                            Toggle("允许在重逢中回看", isOn: Binding(get: { card.memory?.excludedFromReunion != true }, set: { updateReunion(card, allows: $0) })).accessibilityIdentifier("memoryAllowsReunion")
                            Button("移到最近删除", role: .destructive) { deleting = true }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.disabled(busy || !card.isMemory).accessibilityLabel("回忆更多操作").accessibilityIdentifier("memoryDetailActions")
                    }
                }
            }
            .task(id: "\(card?.revisionID.uuidString ?? "")-\(retry)") { await loadPhotos() }
            .sheet(isPresented: $editing) { if let card { MemoryComposerView(initialDate: card.memoryDate ?? model.now, editing: card) } }
            .sheet(isPresented: $continuing) { if let card { MemoryComposerView(initialDate: model.now, previous: card) } }
            .sheet(isPresented: $exporting) { if let card { MemoryExportView(cards: [card], format: exportImages ? .images : .book) } }
            .sheet(item: $photo) { selected in PhotoPreview(photos: photos, initialID: selected.id) }
            .confirmationDialog("把这段回忆移到最近删除？", isPresented: $deleting, titleVisibility: .visible) {
                Button("移到最近删除", role: .destructive) {
                    guard let card else { return }
                    model.perform { try await model.commands?.setLifecycle(card: card, lifecycle: .deleted, now: model.now) }
                }
            } message: { Text("来源事项和其他回忆仍保留。这段回忆可在 30 天内恢复。") }
    }
    @ViewBuilder private func storyLinks(_ card: Card) -> some View {
        if let previousID = card.memory?.previousMemoryID, let previous = model.library.cards.first(where: { $0.id == previousID && $0.lifecycle != .deleted }) {
            NavigationLink { MemoryDetailView(cardID: previous.id) } label: { Label("上一篇 · " + CardPresentation.dateLabel(previous.memoryDate ?? previous.createdAt, format: "yyyy年M月d日") + " · " + previous.title, systemImage: "book.pages").font(.subheadline).frame(minHeight: 44) }
        }
        if let previousID = card.memory?.previousMemoryID, !model.library.cards.contains(where: { $0.id == previousID && $0.lifecycle != .deleted }) {
            Text("上一篇已移除，这段回忆仍独立保留。").font(.footnote).foregroundColor(Paper.secondary)
        }
        ForEach(model.library.cards.filter { $0.memory?.previousMemoryID == card.id && $0.lifecycle != .deleted }.sorted { ($0.memoryDate ?? $0.createdAt) < ($1.memoryDate ?? $1.createdAt) }) { next in
            NavigationLink { MemoryDetailView(cardID: next.id) } label: { Label("后续 · " + CardPresentation.dateLabel(next.memoryDate ?? next.createdAt, format: "yyyy年M月d日") + " · " + next.title, systemImage: "arrow.turn.down.right").font(.subheadline).frame(minHeight: 44) }
        }
        if let sourceID = card.memory?.sourceCardID {
            if let source = model.library.cards.first(where: { $0.id == sourceID && $0.lifecycle != .deleted }) {
                NavigationLink { CardDetailView(cardID: source.id) } label: { Label("来自小事 · " + (card.memory?.sourceTitle ?? source.title), systemImage: "link").font(.subheadline).frame(minHeight: 44) }
            } else { Text("原事项已移除，这段回忆仍独立保留。").font(.footnote).foregroundColor(Paper.secondary) }
        }
    }
    private func updateReunion(_ card: Card, allows: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let commands = model.commands else { throw ShiriError.notFound }
                var copy = card; if copy.memory == nil { copy.memory = MemoryMetadata() }; copy.memory?.excludedFromReunion = !allows
                _ = try await commands.save(CardDraft(card: copy, isEditing: true), now: model.now); await model.refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func loadPhotos() async {
        guard let card else { return }
        do {
            guard let repository = model.repository else { throw ShiriError.notFound }
            let all = try await repository.attachments(cardID: card.id)
            let loaded = card.attachmentIDs.compactMap { id in all.first { $0.id == id } }
            guard !Task.isCancelled else { return }; photos = loaded
            error = loaded.count == card.attachmentIDs.count ? nil : "有照片暂时无法读取，已保留原记录。"
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct MemoryExcludedView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var cards: [Card] { MemoryCollection.cards(in: model.library).filter { $0.memory?.excludedFromReunion == true } }
    var body: some View {
        NavigationStack {
            List {
                Text("这些片刻仍留在回忆册。打开后可以重新允许在重逢中回看。").font(.subheadline).foregroundColor(Paper.secondary)
                if cards.isEmpty { Text("还没有排除的片刻") }
                ForEach(cards) { card in NavigationLink(card.title) { MemoryDetailView(cardID: card.id) } }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("不再重逢的片刻").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct MemoryCompletionPrompt: View {
    @State private var writing = false
    let candidate: MemoryCandidate
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(Paper.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("做完了，也可以留下这一刻").font(.subheadline)
                Button { writing = true } label: { Text("留成回忆").frame(minHeight: 44).contentShape(Rectangle()) }.font(.subheadline).accessibilityIdentifier("completionKeepMemory")
            }
            Spacer(minLength: 0)
            Button { model.pendingMemory = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("暂不留下回忆")
        }.padding(14).paperCard(radius: 17)
            .sheet(isPresented: $writing) { MemoryComposerView(initialDate: candidate.date, source: candidate) }
    }
}
