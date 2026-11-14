import SwiftUI
import ShiriCore

enum MemoryExportStyle: String, CaseIterable, Identifiable, Sendable {
    case paper, letter, photos
    var id: String { rawValue }
    var title: String { switch self { case .paper: return "日常纸页"; case .letter: return "时光信笺"; case .photos: return "照片故事" } }
}
enum MemoryExportFormat { case book, images }
private struct MemoryExportFiles: Identifiable { let id = UUID(); let urls: [URL] }

struct MemoryExportView: View {
    let cards: [Card]
    var format = MemoryExportFormat.book
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var initialized = false
    @State private var includeNotes = false
    @State private var includePhotos = false
    @State private var title = "我的回忆册"
    @State private var style = MemoryExportStyle.paper
    @State private var photos: [UUID: [Attachment]] = [:]
    @State private var coverID: UUID?
    @State private var pdf: Data?
    @State private var preview: UIImage?
    @State private var page = 1
    @State private var pageCount = 0
    @State private var rendering = false
    @State private var exporting = false
    @State private var error: String?
    @State private var files: MemoryExportFiles?
    @State private var retry = 0
    @State private var choosing = false
    @State private var query = ""
    @FocusState private var typing: Bool
    private var chosen: [Card] { cards.filter { selected.contains($0.id) } }
    private var renderID: String { "\(initialized)|\(chosen.map(\.revisionID))|\(includeNotes)|\(includePhotos)|\(title)|\(style.rawValue)|\(coverID?.uuidString ?? "")|\(retry)" }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if format == .book { selectionSection }
                    VStack(alignment: .leading, spacing: 12) {
                        if format == .book {
                            Text("回忆册名称").font(.subheadline).foregroundColor(Paper.secondary)
                            TextField("给回忆册起个名字", text: $title).focused($typing).onChange(of: title) { value in if value.count > 80 { title = String(value.prefix(80)) } }.accessibilityIdentifier("memoryBookTitle")
                        }
                        LabeledContent("样式") { Picker("", selection: $style) { ForEach(MemoryExportStyle.allCases) { Text($0.title).tag($0) } }.labelsHidden().accessibilityIdentifier("memoryExportStyle") }
                        Toggle("包含完整正文", isOn: $includeNotes).accessibilityIdentifier("memoryExportNotes")
                        Toggle("包含全部照片", isOn: $includePhotos).accessibilityIdentifier("memoryExportPhotos")
                        Text(includeNotes || includePhotos ? "只包含当前选择的回忆内容。" : "当前只含标题和日期。正文与照片由你选择是否加入。")
                            .font(.footnote).foregroundColor(Paper.secondary).accessibilityIdentifier("memoryExportScope")
                        if includePhotos && format == .book {
                            Menu {
                                Button("纯文字封面") { coverID = nil }
                                ForEach(chosen) { card in ForEach(photos[card.id] ?? []) { photo in Button("\(card.title) · 第 \(photo.sortIndex + 1) 张") { coverID = photo.id } } }
                            } label: { Label(coverID == nil ? "选择封面照片" : "更换封面照片", systemImage: "photo").frame(minHeight: 44) }.accessibilityIdentifier("memoryCoverPhoto")
                        }
                    }.padding(16).paperCard(radius: 18)
                    if rendering { ProgressView(format == .images ? "正在生成图片…" : "正在生成回忆册…").accessibilityIdentifier("memoryExportLoading") }
                    if let error { PaperErrorBanner(message: error); Button("重新生成") { retry += 1 }.frame(minHeight: 44) }
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("第 \(page) \(format == .images ? "张" : "页")预览").accessibilityIdentifier("memoryExportPreview")
                        HStack {
                            Button { page -= 1; updatePreview() } label: { Image(systemName: "chevron.left").frame(width: 48, height: 48) }.disabled(page <= 1 || rendering).accessibilityLabel("上一页")
                            Spacer(); Text("第 \(page) / \(pageCount) \(format == .images ? "张" : "页")").font(.subheadline).accessibilityIdentifier("memoryExportPageCount"); Spacer()
                            Button { page += 1; updatePreview() } label: { Image(systemName: "chevron.right").frame(width: 48, height: 48) }.disabled(page >= pageCount || rendering).accessibilityLabel("下一页")
                        }
                        if format == .images {
                            Button(pageCount > 1 ? "分享全部 \(pageCount) 张图片" : "分享回忆图片") { exportImages(all: true) }.buttonStyle(PaperPrimaryButton()).disabled(rendering || exporting).accessibilityIdentifier("confirmMemoryImageExport")
                            if pageCount > 1 { Button("仅分享当前第 \(page) 张") { exportImages(all: false) }.frame(maxWidth: .infinity, minHeight: 48).accessibilityIdentifier("exportMemoryPage") }
                        } else {
                            Button("导出完整回忆册 PDF · \(pageCount) 页") { exportPDF() }.buttonStyle(PaperPrimaryButton()).disabled(rendering || exporting).accessibilityIdentifier("confirmMemoryExport")
                        }
                        Text("预览内容就是导出内容。选择接收方式后才会分享。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                    if exporting { ProgressView("正在准备分享文件…") }
                }.padding(20)
            }.background(Paper.background).foregroundColor(Paper.ink).scrollDismissesKeyboard(.interactively)
                .navigationTitle(format == .images ? "回忆图片预览" : "回忆册预览").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(exporting) }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { typing = false } }
                }
                .onAppear { if !initialized { selected = Set((cards.count <= 6 ? cards : []).map(\.id)); choosing = cards.count > 6; initialized = true } }
                .task(id: renderID) { await render() }
                .sheet(item: $files) { SystemShareSheet(items: $0.urls) }
        }.interactiveDismissDisabled(exporting)
    }
    private var selectionSection: some View {
        DisclosureGroup("已选 \(chosen.count) / 6 段回忆", isExpanded: $choosing) {
            TextField("搜索要放入的回忆", text: $query).focused($typing).padding(.vertical, 8)
            ForEach(cards.filter { query.isEmpty || ($0.title + " " + $0.note).localizedStandardContains(query) }) { card in
                Toggle(isOn: Binding(get: { selected.contains(card.id) }, set: { value in if value && selected.count < 6 { selected.insert(card.id) } else if !value { selected.remove(card.id) } })) {
                    VStack(alignment: .leading) { Text(card.title); Text(CardPresentation.dateLabel(card.memoryDate ?? card.createdAt, format: "yyyy年M月d日")).font(.caption).foregroundColor(Paper.secondary) }
                }.disabled(!selected.contains(card.id) && selected.count >= 6).padding(.vertical, 6)
            }
        }
    }
    @MainActor private func render() async {
        guard initialized else { return }
        rendering = true; pdf = nil; preview = nil; error = nil
        let chosen = chosen, notes = includeNotes, wantsPhotos = includePhotos, heading = String(title.prefix(80)), design = style, cover = coverID, book = format == .book
        guard !chosen.isEmpty else { pageCount = 0; rendering = false; return }
        do {
            try await Task.sleep(nanoseconds: 180_000_000)
            var loaded: [UUID: [Attachment]] = [:]
            if wantsPhotos {
                guard let repository = model.repository else { throw ShiriError.notFound }
                for card in chosen {
                    let all = try await repository.attachments(cardID: card.id)
                    loaded[card.id] = try card.attachmentIDs.map { id in
                        guard let photo = all.first(where: { $0.id == id }) else { throw ShiriError.storage("照片尚未读取完整。请重试，或关闭照片后导出。") }
                        try photo.validate(); return photo
                    }
                    try Task.checkCancellation()
                }
            }
            let renderPhotos = loaded
            let hasBody = notes && chosen.contains { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let hasPhotos = loaded.values.contains { !$0.isEmpty }
            let work = Task.detached(priority: .userInitiated) { try MemoryBookRenderer.render(cards: chosen, photos: renderPhotos, includesNotes: notes, title: heading, style: design, coverID: cover, includesCover: book, compact: !book && !hasBody && !hasPhotos) }
            let data = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            photos = loaded
            if coverID != nil && !loaded.values.joined().contains(where: { $0.id == coverID }) { coverID = nil }
            pdf = data; pageCount = MemoryBookRenderer.pageCount(data); page = 1; updatePreview(); rendering = false
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; rendering = false } }
    }
    private func updatePreview() { guard let pdf else { return }; preview = MemoryBookRenderer.preview(pdf, page: page) }
    private func exportPDF() { do { guard let pdf else { return }; files = MemoryExportFiles(urls: [try SharedFile.write(pdf, extension: "pdf").url]) } catch { self.error = error.localizedDescription } }
    private func exportImages(all: Bool) {
        guard let pdf, !exporting else { return }
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                var urls: [URL] = []
                for number in all ? Array(1...max(1, pageCount)) : [page] {
                    guard let image = MemoryBookRenderer.preview(pdf, page: number), let data = image.pngData() else { throw ShiriError.storage("图片生成未完成，请重试") }
                    urls.append(try SharedFile.write(data, extension: "png").url)
                    await Task.yield()
                }
                files = MemoryExportFiles(urls: urls)
            } catch { self.error = error.localizedDescription }
        }
    }
}

enum MemoryBookRenderer {
    static let size = CGSize(width: 595, height: 842)
    static func render(cards: [Card], photos: [UUID: [Attachment]], includesNotes: Bool, title: String, style: MemoryExportStyle, coverID: UUID?, includesCover: Bool = true, compact: Bool = false) throws -> Data {
        guard !cards.isEmpty, cards.count <= 6 else { throw ShiriError.validation("请选择 1 至 6 个片刻") }
        try Task.checkCancellation()
        let background = UIColor(hex: style == .letter ? "F6F0E3" : style == .photos ? "EAF0E3" : "F8F7F3")
        let ink = UIColor(hex: "252A23"), secondary = UIColor(hex: "666E5F"), accent = UIColor(hex: "AD5F49")
        let contentWidth: CGFloat = style == .letter ? 459 : 499
        let left = (size.width - contentWidth) / 2
        var number = 0
        let pageSize = compact ? CGSize(width: size.width, height: 420) : size
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { context in
            func page(_ subtitle: String) {
                context.beginPage(); number += 1
                background.setFill(); context.fill(CGRect(origin: .zero, size: pageSize))
                draw("拾日  /  " + subtitle, at: CGRect(x: left, y: 33, width: contentWidth, height: 25), font: .systemFont(ofSize: 11, weight: .medium), color: secondary)
                draw("把值得记住的留下", at: CGRect(x: left, y: pageSize.height - 45, width: 280, height: 20), font: .systemFont(ofSize: 10), color: secondary)
                draw(String(format: "%02d", number), at: CGRect(x: 520, y: pageSize.height - 45, width: 30, height: 20), font: .systemFont(ofSize: 10), color: secondary)
            }
            if includesCover {
            page(style.title)
            let coverTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我的小事回忆册" : title
            var coverFont = UIFont.systemFont(ofSize: 37, weight: .medium)
            while measured(coverTitle, width: contentWidth, font: coverFont) > 170 && coverFont.pointSize > 18 { coverFont = .systemFont(ofSize: coverFont.pointSize - 1, weight: .medium) }
            draw(coverTitle, at: CGRect(x: left, y: 103, width: contentWidth, height: 172), font: coverFont, color: ink)
            draw("\(cards.count) 个片刻 · 慢慢翻，慢慢记住", at: CGRect(x: left, y: 295, width: contentWidth, height: 30), font: .systemFont(ofSize: 15), color: accent)
            if let coverID, let cover = photos.values.joined().first(where: { $0.id == coverID }), let image = UIImage(data: cover.data) {
                image.draw(in: fit(image.size, in: CGRect(x: left, y: 357, width: contentWidth, height: 342)))
            } else {
                let dates = cards.compactMap(\.memoryDate).sorted()
                let caption = dates.first.map { CardPresentation.dateLabel($0, format: "yyyy.MM.dd") } ?? ""
                let end = dates.last.map { CardPresentation.dateLabel($0, format: "yyyy.MM.dd") } ?? ""
                draw(caption + (caption == end ? "" : " — " + end), at: CGRect(x: left, y: 650, width: contentWidth, height: 32), font: .systemFont(ofSize: 15), color: secondary)
                draw("日子里的小事，也值得成册。", at: CGRect(x: left, y: 699, width: contentWidth, height: 45), font: .systemFont(ofSize: 21), color: ink)
            }
            }
            for card in cards {
                if Task.isCancelled { return }
                let date = CardPresentation.dateLabel(card.memoryDate ?? card.createdAt, format: "yyyy年M月d日")
                func heading(continuation: Bool) -> CGFloat {
                    page(card.category)
                    draw(date + (continuation ? " · 续页" : ""), at: CGRect(x: left, y: 79, width: contentWidth, height: 25), font: .systemFont(ofSize: 13), color: accent)
                    let titleFont = UIFont.systemFont(ofSize: continuation ? 17 : 27, weight: .medium)
                    let height = measured(card.title, width: contentWidth, font: titleFont)
                    draw(card.title, at: CGRect(x: left, y: 117, width: contentWidth, height: height + 2), font: titleFont, color: ink)
                    return 140 + height
                }
                var y = heading(continuation: false)
                if includesNotes && !card.note.isEmpty {
                    let font = UIFont.systemFont(ofSize: style == .letter ? 18 : 17)
                    var remaining = card.note
                    while !remaining.isEmpty {
                        if Task.isCancelled { return }
                        let part = fittingPrefix(remaining, width: contentWidth, height: 745 - y, font: font)
                        if part.isEmpty { y = heading(continuation: true); continue }
                        let height = measured(part, width: contentWidth, font: font)
                        draw(part, at: CGRect(x: left, y: y, width: contentWidth, height: height + 2), font: font, color: ink)
                        y += height + 22; remaining.removeFirst(part.count)
                        if !remaining.isEmpty { y = heading(continuation: true) }
                    }
                }
                let album = photos[card.id] ?? []
                for (index, attachment) in album.enumerated() {
                    if Task.isCancelled { return }
                    guard let image = UIImage(data: attachment.data) else { continue }
                    let photoHeight: CGFloat = style == .photos ? 450 : style == .letter ? 335 : 260
                    if y + photoHeight + 25 > 755 { y = heading(continuation: true) }
                    image.draw(in: fit(image.size, in: CGRect(x: left, y: y, width: contentWidth, height: min(photoHeight, 730 - y))))
                    y += min(photoHeight, 730 - y) + 8
                    draw("\(index + 1) / \(album.count)", at: CGRect(x: left, y: y, width: contentWidth, height: 20), font: .systemFont(ofSize: 10), color: secondary)
                    y += 32
                }
            }
        }
    }
    private static func paragraph() -> NSMutableParagraphStyle { let p = NSMutableParagraphStyle(); p.lineSpacing = 6; p.lineBreakMode = .byWordWrapping; return p }
    private static func measured(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph()], context: nil).height)
    }
    private static func fittingPrefix(_ text: String, width: CGFloat, height: CGFloat, font: UIFont) -> String {
        let characters = Array(text); var lower = 0, upper = characters.count
        while lower < upper { let mid = (lower + upper + 1) / 2; if measured(String(characters.prefix(mid)), width: width, font: font) <= height { lower = mid } else { upper = mid - 1 } }
        return String(characters.prefix(lower))
    }
    private static func draw(_ text: String, at rect: CGRect, font: UIFont, color: UIColor) {
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph()], context: nil)
    }
    private static func fit(_ image: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / max(1, image.width), rect.height / max(1, image.height))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
    static func pageCount(_ data: Data) -> Int { guard let provider = CGDataProvider(data: data as CFData) else { return 0 }; return CGPDFDocument(provider)?.numberOfPages ?? 0 }
    static func preview(_ data: Data, page: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: page) else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1.5; format.opaque = true
        let bounds = page.getBoxRect(.mediaBox)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: bounds.size))
            context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1); context.drawPDFPage(page)
        }
    }
}
