import UIKit
import SwiftUI
import UniformTypeIdentifiers
import ShiriCore

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let content = ShareCaptureView(items: (extensionContext?.inputItems as? [NSExtensionItem]) ?? [], onFinish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) })
        let host = UIHostingController(rootView: content)
        addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
    }
}
private struct ShareCaptureView: View {
    var items: [NSExtensionItem]
    var onFinish: () -> Void
    @State private var draft = CardDraft(card: Card(title: "", kind: .note, now: Date()))
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("先留在草稿里").font(.title2); Text("打开拾日后，可以继续补充日期、提醒和卡片外观。").font(.subheadline).foregroundColor(.secondary) }
                if loading { ProgressView("正在读取分享内容") }
                if let error { Text(error).foregroundColor(.red) }
                Section("内容") { TextField("标题", text: $draft.card.title); TextField("文字与链接", text: $draft.card.note, axis: .vertical).lineLimit(3...8) }
                if !draft.attachments.isEmpty {
                    Section("图片 · \(draft.attachments.count) 张") {
                        ScrollView(.horizontal) { HStack { ForEach(draft.attachments) { attachment in if let image = UIImage(data: attachment.data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 90,height: 100) } } } }
                    }
                }
                Section { Button(saving ? "正在保存…" : "保存到拾日草稿") { Task { await save() } }.disabled(loading || saving) }
            }.scrollContentBackground(.hidden).background(Color(red: 0.97, green: 0.96, blue: 0.93)).tint(Color(red: 0.74,green: 0.38,blue: 0.29))
                .navigationTitle("拾日").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: onFinish) } }
                .task { await load() }
        }
    }
    @MainActor private func load() async {
        defer { loading = false }
        do {
            let providers = items.flatMap { $0.attachments ?? [] }
            guard providers.count <= 12 else { throw ShiriError.validation("一次分享的内容过多，请减少后重试") }
            var texts: [String] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    guard draft.attachments.count < AppLimits.attachmentCount else { throw ShiriError.validation("每张卡片最多 6 张图片，请重新选择") }
                    let data = try await provider.data(for: UTType.image.identifier)
                    draft.attachments.append(try PhotoProcessor.prepare(data, cardID: draft.card.id, index: draft.attachments.count))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let item = try await provider.value(for: UTType.url.identifier)
                    if let url = item as? URL { texts.append(url.absoluteString) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let item = try await provider.value(for: UTType.plainText.identifier)
                    if let text = item as? String { texts.append(text) }
                    else if let data = item as? Data, let text = String(data: data, encoding: .utf8) { texts.append(text) }
                }
            }
            draft.card.note = texts.joined(separator: "\n\n")
            draft.card.title = draft.attachments.isEmpty ? "分享的内容" : "图片记事"
            draft.card.attachmentIDs = draft.attachments.map(\.id)
            guard !draft.card.note.isEmpty || !draft.attachments.isEmpty else { throw ShiriError.validation("没有可保存的文字、链接或图片") }
            if draft.card.note.count > AppLimits.noteLength { error = "文字超过 2,000 字，请在上面缩短后保存" }
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func save() async {
        saving = true; defer { saving = false }
        do {
            _ = try draft.card.validated()
            let repository = try await ExtensionStore.open(author: "ShareExtension")
            draft.updatedAt = Date(); try await repository.saveDraft(draft); onFinish()
        } catch { self.error = error.localizedDescription }
    }
}
private extension NSItemProvider {
    func data(for type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: type) { data,error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ShiriError.invalidFile("无法读取这张图片")) }
            }
        }
    }
    func value(for type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: type, options: nil) { value,error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: ShiriError.invalidFile("无法读取分享内容")) }
            }
        }
    }
}
