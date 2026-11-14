import SwiftUI
import ShiriCore

struct AppearanceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: CardDraft
    @State private var customColor = Color(hex: "F2EDC9")
    @State private var hasLoadedColor = false
    @State private var showsFullPreview = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !typeSize.isAccessibilitySize {
                        preview
                    }
                    PaperFieldSection("纸张颜色") {
                        HStack(spacing: 12) {
                            ForEach(CardTheme.allCases, id: \.self) { theme in
                                Button {
                                    draft.card.appearance.theme = theme; draft.card.appearance.customHex = nil
                                    draft.card.appearance.overriddenFields.insert("theme")
                                } label: {
                                    Circle().fill(Paper.card(theme)).frame(width: 30, height: 30).overlay { if draft.card.appearance.theme == theme { Circle().stroke(Paper.accent, lineWidth: 2).padding(-3) } }.frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel(theme.title).accessibilityIdentifier("appearanceTheme_" + theme.rawValue)
                            }
                        }
                        ColorPicker("自选颜色", selection: $customColor, supportsOpacity: false).onChange(of: customColor) { color in
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                            draft.card.appearance.customHex = String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
                            draft.card.appearance.overriddenFields.insert("theme")
                        }
                    }
                    PaperFieldSection("一张小插画") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 15) {
                            ForEach(CardIllustration.allCases, id: \.self) { illustration in
                                Button {
                                    draft.card.appearance.illustration = illustration; draft.card.appearance.overriddenFields.insert("illustration")
                                } label: {
                                    VStack(spacing: 8) {
                                        if illustration == .none { Image(systemName: "circle.slash").frame(height: 60) }
                                        else { Image(illustration.rawValue).resizable().scaledToFit().frame(height: 60).blendMode(.multiply) }
                                        Text(illustration.title).font(.caption)
                                    }.frame(maxWidth: .infinity).padding(8).background(draft.card.appearance.illustration == illustration ? Paper.card(.butter) : Paper.surface, in: RoundedRectangle(cornerRadius: 12))
                                }.foregroundColor(draft.card.appearance.illustration == illustration ? Paper.cardInk : Paper.ink)
                            }
                        }
                    }
                    if !draft.attachments.isEmpty {
                        PaperFieldSection("自己的图片") {
                            Picker("卡片照片", selection: $draft.card.appearance.backgroundAttachmentID) {
                                Text("不使用照片").tag(nil as UUID?)
                                ForEach(Array(draft.attachments.enumerated()), id: \.element.id) { index, photo in Text("第 \(index + 1) 张照片").tag(Optional(photo.id)) }
                            }.onChange(of: draft.card.appearance.backgroundAttachmentID) { _ in draft.card.appearance.overriddenFields.insert("background") }
                        }
                    }
                    Text("手动选过的外观会保留。再次修改标题或正文，不会覆盖你的选择。").font(.footnote).foregroundColor(Paper.secondary)
                    Button("重置为推荐外观") { draft.card.appearance = .recommended(for: draft.card.title, kind: draft.card.kind, birthday: draft.card.birthday != nil) }.frame(maxWidth: .infinity)
                    if typeSize.isAccessibilitySize { preview }
                }.padding(18)
            }.background(Paper.background).navigationTitle("卡片外观").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear {
                    guard !hasLoadedColor else { return }
                    hasLoadedColor = true
                    if let hex = draft.card.appearance.customHex { customColor = Color(hex: hex) }
                }
                .sheet(isPresented: $showsFullPreview) {
                    NavigationStack { ScrollView { Text(draft.card.title + "\n\n" + draft.card.note).font(.body).padding(20) }.navigationTitle("卡片内容").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsFullPreview = false } } } }
                }
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("外观预览").font(.caption).foregroundColor(Paper.secondary)
            CardTile(projection: CardProjection(card: draft.card, occurrence: nil), showsReminder: false, isPreview: true, onOpen: {}, onComplete: nil, backgroundData: draft.attachments.first { $0.id == draft.card.appearance.backgroundAttachmentID }?.data)
            Button("查看完整内容") { showsFullPreview = true }.font(.subheadline).frame(minHeight: 44)
        }
    }
}
