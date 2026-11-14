import SwiftUI
import PhotosUI
import ShiriCore

struct ScreenshotImportView: View {
    var existingImages: [Attachment] = []
    let onUse: (CardDraft, Attachment?) throws -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PhotosPickerItem?
    @State private var image: Attachment?
    @State private var text = ""
    @State private var uncertain = false
    @State private var confirmed = false
    @State private var keepsSource = true
    @State private var busy = false
    @State private var error: String?
    @State private var inputData: Data?
    @State private var sourceAttachment: Attachment?
    @State private var requestID = UUID()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("截图里的安排，确认后留下").font(Paper.title(26))
                    Text("在设备上识别。请核对日期、时间和地点，保存前仍可修改。").font(.subheadline).foregroundColor(Paper.secondary)
                    PhotosPicker(selection: $selected, matching: .images) { Label("选择一张截图", systemImage: "photo.on.rectangle") }.frame(minHeight: 44)
                    if !existingImages.isEmpty {
                        Menu("从这张卡片的图片识别") {
                            ForEach(Array(existingImages.enumerated()), id: \.element.id) { index, photo in Button("第 \(index + 1) 张图片") { sourceAttachment = photo; inputData = photo.data; requestID = UUID() } }
                        }.frame(minHeight: 44).accessibilityIdentifier("recognizeExistingImage")
                    }
                    if busy { ProgressView("正在识别文字…").accessibilityIdentifier("screenshotRecognitionLoading") }
                    if let image, let uiImage = UIImage(data: image.data) {
                        Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel("待核对的原图")
                    }
                    TextField("识别文字，也可以在这里手动输入", text: $text, axis: .vertical).lineLimit(5...12).textFieldStyle(.roundedBorder).accessibilityIdentifier("recognizedText")
                    if uncertain { Text("有些文字识别把握较低，请对照原图逐项核对。").font(.subheadline).foregroundColor(Paper.accent) }
                    if image != nil { Toggle("把原图保留在卡片中", isOn: $keepsSource) }
                    Toggle("我已核对文字，继续确认具体安排", isOn: $confirmed).accessibilityIdentifier("confirmRecognizedText")
                    if let error { PaperErrorBanner(message: error).accessibilityIdentifier("screenshotRecognitionError") }
                    Button("使用文字确认安排") { use() }.buttonStyle(PaperPrimaryButton()).disabled(!confirmed || busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("useRecognizedText")
                    Text("此步骤不会保存卡片或开启提醒。原图只有选择保留后才会随卡片保存。").font(.footnote).foregroundColor(Paper.secondary)
                }.padding(18)
            }.background(Paper.background).navigationTitle("截图变卡片")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onChange(of: text) { _ in confirmed = false }
                .onChange(of: selected) { _ in sourceAttachment = nil; inputData = nil; requestID = UUID() }
                .task(id: requestID) { await recognize() }
        }
    }
    private func recognize() async {
        guard selected != nil || inputData != nil else { return }
        busy = true; error = nil; confirmed = false; text = ""; image = nil
        do {
            let data: Data
            if let inputData { data = inputData }
            else if let selected, let loaded = try await selected.loadTransferable(type: Data.self) { data = loaded }
            else { throw ShiriError.invalidFile("图片尚未下载，可以联网下载到相册后重试") }
            let original = sourceAttachment
            let worker = Task.detached(priority: .userInitiated) {
                // Existing attachments have already been normalized. Re-encoding creates a second digest and photo.
                let photo = try original ?? PhotoProcessor.prepare(data, cardID: UUID(), index: 0)
                return (photo, try ScreenshotRecognition.recognize(photo.data))
            }
            let (photo, result) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            image = photo; text = result.text; uncertain = !result.uncertainLines.isEmpty
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
        busy = false
    }
    private func use() {
        do {
            let draft = try ScreenshotDraftBuilder.make(text: text, now: model.now, calendar: model.calendar)
            try onUse(draft, keepsSource ? image : nil); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
