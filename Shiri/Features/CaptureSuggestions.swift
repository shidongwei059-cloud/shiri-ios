import SwiftUI

struct CaptureSuggestions: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        (size.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
            choice("一件待办", symbol: "checkmark.circle", id: "startTask") { model.create() }
            choice("一句随手记", symbol: "pencil.line", id: "startNote") { model.create(kind: .note) }
            choice("重要日子", symbol: "gift", id: "startOccasion") { model.createOccasion() }
        }
    }
    private func choice(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) { Image(systemName: symbol).font(.title3); Text(title).font(.subheadline) }
                .frame(maxWidth: .infinity, minHeight: 76).padding(8).paperCard(radius: 13)
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}
