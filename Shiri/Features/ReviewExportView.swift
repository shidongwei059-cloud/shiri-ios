import SwiftUI
import ShiriCore

struct ReviewExportView: View {
    var summary: ReviewSummary
    @Environment(\.dismiss) private var dismiss
    @State private var includeTitles = false
    @State private var file: SharedFile?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("包含已完成事项的标题", isOn: $includeTitles)
                    Text("默认只导出统计数字。照片、地点、私人备注和他人反馈都不会加入这份回顾。").font(.footnote).foregroundColor(Paper.secondary)
                    exportContent
                    if let error { PaperErrorBanner(message: error) }
                    Button("导出回顾图片") { export() }.buttonStyle(PaperPrimaryButton())
                }.padding(20)
            }.background(Paper.background).navigationTitle("分享我的回顾").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $file) { SystemShareSheet(items: [$0.url]) }
        }
    }
    private var exportContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("拾日").font(Paper.title(25)); Spacer(); ShiriBrandMark(size: 25) }
            Text("生活的小进展").font(Paper.title(30))
            Text("\(summary.interval.start.formatted(.dateTime.month().day())) — \(summary.interval.end.addingTimeInterval(-1).formatted(.dateTime.month().day()))").font(.subheadline)
            Text("完成了 \(summary.completed.count) 件事").font(Paper.title(26))
            Text(summary.completionRate.map { "计划完成率 \(Int(($0*100).rounded()))% · 长期进展 \(summary.longTermCompleted) 件" } ?? "本期暂无可统计的计划事项").font(.subheadline)
            if includeTitles { ForEach(summary.completed.prefix(30)) { event in Text("✓  " + event.snapshot.title).font(.body) } }
            Text("按真实处理记录统计 · 截至导出时").font(.footnote).foregroundColor(Paper.cardSecondary)
        }.foregroundColor(Paper.cardInk).padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: "E4ECD7"), in: RoundedRectangle(cornerRadius: 22))
    }
    @MainActor private func export() {
        do {
            let renderer = ImageRenderer(content: exportContent.frame(width: 360).padding(20).background(Color(hex: "F7F5EF")).environment(\.colorScheme,.light)); renderer.scale = 3
            guard let data = renderer.uiImage?.pngData() else { throw ShiriError.unavailable("无法生成回顾图片，请稍后重试") }
            file = try SharedFile.write(data, extension: "png")
        } catch { self.error = error.localizedDescription }
    }
}
