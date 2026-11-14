import SwiftUI
import PhotosUI
import ShiriCore

struct MediaEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: CardDraft
    @State private var selection: [PhotosPickerItem] = []
    @State private var busy = false
    @State private var error: String?
    @State private var camera = false
    @State private var preview: Attachment?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("每张卡片最多 6 张图片，保存时移除拍摄位置等信息。图片会与卡片一起备份。").font(.subheadline).foregroundColor(Paper.secondary) }
                Section {
                    if draft.attachments.isEmpty && !busy {
                        PaperEmptyState(title: "给这件事添一张图片", message: "照片、手写便笺或一张截图，\n都可以和卡片一起留下。", scene: .photos, compact: true).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                    ForEach(draft.attachments) { attachment in
                        HStack(spacing: 16) {
                            if let image = UIImage(data: attachment.data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 76, height: 64).clipped().clipShape(RoundedRectangle(cornerRadius: 9)) }
                            VStack(alignment: .leading, spacing: 5) { Text("第 \(attachment.sortIndex + 1) 张图片"); Text("\(attachment.width) × \(attachment.height) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))").font(.caption).foregroundColor(Paper.secondary) }
                        }.contentShape(Rectangle()).onTapGesture { preview = attachment }
                    }.onDelete { indices in draft.attachments.remove(atOffsets: indices); normalize() }
                        .onMove { source, destination in draft.attachments.move(fromOffsets: source, toOffset: destination); normalize() }
                } header: { Text("图片 · \(draft.attachments.count)/6") } footer: { if !draft.attachments.isEmpty { Text("左滑删除，点“排序”调整图片顺序。") } }
                if draft.attachments.count < 6 {
                    Section {
                        PhotosPicker(selection: $selection, maxSelectionCount: 6 - draft.attachments.count, matching: .images) { Label("从相册选择", systemImage: "photo.on.rectangle") }.disabled(busy)
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { camera = true } label: { Label("拍一张照片", systemImage: "camera") }.disabled(busy) }
                    }
                }
                if busy { Section { ProgressView("正在处理图片…") } }
                if let error { Section { PaperErrorBanner(message: error) } }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("卡片图片").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { EditButton().labelStyle(.titleOnly).disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) }
                }
                .onChange(of: selection) { items in Task { await load(items) } }
                .sheet(isPresented: $camera) { CameraCapture { data in Task { busy = true; await append(data); busy = false } } }
                .sheet(item: $preview) { photo in PhotoPreview(photos: draft.attachments, initialID: photo.id) }
        }.interactiveDismissDisabled(busy)
    }
    private func normalize() {
        for index in draft.attachments.indices { draft.attachments[index].sortIndex = index }
        draft.card.attachmentIDs = draft.attachments.map(\.id)
        if let id = draft.card.appearance.backgroundAttachmentID, !draft.card.attachmentIDs.contains(id) { draft.card.appearance.backgroundAttachmentID = nil }
    }
    private func load(_ items: [PhotosPickerItem]) async {
        busy = true; defer { busy = false }
        for item in items where draft.attachments.count < 6 {
            do { guard let data = try await item.loadTransferable(type: Data.self) else { continue }; await append(data) }
            catch { self.error = error.localizedDescription }
        }
        selection = []
    }
    private func append(_ data: Data) async {
        guard draft.attachments.count < 6 else { return }
        let cardID = draft.card.id; let index = draft.attachments.count
        do {
            let photo = try await Task.detached(priority: .userInitiated) { try PhotoProcessor.prepare(data, cardID: cardID, index: index) }.value
            draft.attachments.append(photo); normalize()
        } catch { self.error = error.localizedDescription }
    }
}
struct CameraCapture: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onImage: (Data) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCapture
        init(parent: CameraCapture) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) { parent.onImage(data) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
struct PhotoPreview: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [Attachment]
    @State private var selectedID: UUID
    init(photo: Attachment) { photos = [photo]; _selectedID = State(initialValue: photo.id) }
    init(photos: [Attachment], initialID: UUID) { self.photos = photos; _selectedID = State(initialValue: initialID) }
    private var index: Int { photos.firstIndex { $0.id == selectedID } ?? 0 }
    var body: some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(photos) { photo in
                    ZoomableMemoryPhoto(data: photo.data).tag(photo.id)
                        .accessibilityLabel("第 \(photo.sortIndex + 1) 张照片，可缩放查看").accessibilityIdentifier("photoGalleryImage_\(photo.sortIndex)")
                }
            }.tabViewStyle(.page(indexDisplayMode: .never)).background(Color.black)
                .accessibilityIdentifier("photoGallery")
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 48, height: 48) }.disabled(index == 0).accessibilityLabel("上一张照片")
                        Spacer()
                        Text("\(index + 1) / \(photos.count)").font(.body).accessibilityIdentifier("photoGalleryCount")
                            .accessibilityLabel("第 \(index + 1) 张，共 \(photos.count) 张照片")
                        Spacer()
                        Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 48, height: 48) }.disabled(index + 1 >= photos.count).accessibilityLabel("下一张照片")
                    }.padding(.horizontal, 20).foregroundColor(.white).background(Color.black)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
    private func move(_ delta: Int) { let next = index + delta; if photos.indices.contains(next) { selectedID = photos[next].id } }
}

private struct ZoomableMemoryPhoto: UIViewRepresentable {
    let data: Data
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let scroll = PhotoZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black; scroll.bouncesZoom = true
        scroll.isAccessibilityElement = true; scroll.accessibilityTraits = [.image, .adjustable]
        scroll.accessibilityHint = "双击放大或还原，上下轻扫调整缩放。放大后可移动查看细节。"
        scroll.photoView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.photoView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(doubleTap)
        return scroll
    }
    func updateUIView(_ scroll: PhotoZoomScrollView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        scroll.setZoomScale(1, animated: false); scroll.photoView.image = UIImage(data: data); scroll.setNeedsLayout()
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var data: Data?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoZoomScrollView)?.photoView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? PhotoZoomScrollView)?.centerPhoto() }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? PhotoZoomScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: scroll.photoView), scale: CGFloat = 2.5
                scroll.zoom(to: CGRect(x: point.x - scroll.bounds.width / scale / 2, y: point.y - scroll.bounds.height / scale / 2, width: scroll.bounds.width / scale, height: scroll.bounds.height / scale), animated: true)
            }
        }
    }
}
private final class PhotoZoomScrollView: UIScrollView {
    let photoView = UIImageView()
    private var laidOutSize = CGSize.zero
    override var accessibilityValue: String? {
        get { "缩放 \(Int((zoomScale * 100).rounded()))%" }
        set { }
    }
    override func accessibilityActivate() -> Bool { setZoomScale(zoomScale > 1 ? 1 : 2.5, animated: true); return true }
    override func accessibilityIncrement() { setZoomScale(min(maximumZoomScale, zoomScale + 0.5), animated: true) }
    override func accessibilityDecrement() { setZoomScale(max(minimumZoomScale, zoomScale - 0.5), animated: true) }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size; zoomScale = 1
        photoView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size; centerPhoto()
    }
    func centerPhoto() { contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0) }
}
