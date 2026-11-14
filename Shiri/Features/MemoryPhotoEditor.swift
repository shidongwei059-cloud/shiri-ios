import SwiftUI
import PhotosUI
import ImageIO
import ShiriCore

struct MemoryPhotoEditor: View {
    @Binding var draft: CardDraft
    @Binding var busy: Bool
    var willSelect: () -> Void
    @State private var selection: [PhotosPickerItem] = []
    @State private var managing = false
    @State private var camera = false
    @State private var preview: Attachment?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var error: String?
    @State private var failedData: [Data] = []
    @State private var suggestedDate: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading) { Text("照片 · \(draft.attachments.count)/6"); actions }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text("照片 · \(draft.attachments.count)/6"); Spacer(); actions }
                        VStack(alignment: .leading) { Text("照片 · \(draft.attachments.count)/6"); actions }
                    }
                }
            }.font(.subheadline)
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(draft.attachments) { photo in
                        Button { preview = photo } label: {
                            MemoryAttachmentThumbnail(attachment: photo).frame(width: 92, height: 84).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityLabel("查看第 \(photo.sortIndex + 1) 张照片")
                    } }
                }
            }
            if busy { ProgressView("正在保存所选照片…") }
            if let suggestedDate {
                VStack(alignment: .leading) {
                    Text("照片拍摄于 \(CardPresentation.dateLabel(suggestedDate, format: "yyyy年M月d日"))").font(.footnote).foregroundColor(Paper.secondary)
                    Button("用作经历日期") { draft.card.memoryDate = suggestedDate; self.suggestedDate = nil }.frame(minHeight: 44)
                    Button("保留当前日期") { self.suggestedDate = nil }.frame(minHeight: 44)
                }
            }
            if let error { PaperErrorBanner(message: error) }
            if !failedData.isEmpty { Button("重新处理未成功的照片") { Task { let pending = failedData; failedData = []; await loadData(pending) } }.frame(minHeight: 44) }
        }.padding(16).paperCard(radius: 16)
            .onChange(of: selection) { values in if !values.isEmpty { willSelect(); Task { await load(values) } } }
            .sheet(isPresented: $managing) { MediaEditor(draft: $draft) }
            .sheet(isPresented: $camera) { CameraCapture { data in Task { await loadData([data]) } } }
            .sheet(item: $preview) { photo in PhotoPreview(photos: draft.attachments, initialID: photo.id) }
    }
    private var actions: some View {
        (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))) {
            if draft.attachments.count < 6 {
                PhotosPicker(selection: $selection, maxSelectionCount: 6 - draft.attachments.count, selectionBehavior: .ordered, matching: .images) { Label("添加照片", systemImage: "photo.badge.plus").frame(minHeight: 44) }.disabled(busy).accessibilityIdentifier("memoryPhotos")
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { willSelect(); camera = true } label: { Image(systemName: "camera").frame(minWidth: 44, minHeight: 44) }.disabled(busy).accessibilityLabel("拍一张回忆照片")
                }
            }
            if !draft.attachments.isEmpty {
                Button("整理") { willSelect(); managing = true }.frame(minHeight: 44).disabled(busy).accessibilityLabel("整理回忆照片").accessibilityIdentifier("memoryManagePhotos")
            }
        }
    }
    private func load(_ items: [PhotosPickerItem]) async {
        busy = true; error = nil
        var raw: [Data] = []
        for item in items {
            do { guard let data = try await item.loadTransferable(type: Data.self) else { throw ShiriError.storage("照片暂时无法读取，请重新选择") }; raw.append(data) }
            catch { self.error = error.localizedDescription }
        }
        selection = []
        await loadData(raw)
    }
    private func loadData(_ values: [Data]) async {
        busy = true; defer { busy = false }
        for data in values where draft.attachments.count < 6 {
            do {
                let id = draft.card.id, index = draft.attachments.count
                let photo = try await Task.detached(priority: .userInitiated) { try PhotoProcessor.prepare(data, cardID: id, index: index) }.value
                if index == 0, let date = Self.captureDate(data), date <= Date() { suggestedDate = date }
                draft.attachments.append(photo); draft.card.attachmentIDs = draft.attachments.map(\.id)
            } catch { failedData.append(data); self.error = "有照片处理失败，已成功的照片和正文仍保留。" }
        }
    }
    private static func captureDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let value = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
