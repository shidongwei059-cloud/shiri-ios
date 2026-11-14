import SwiftUI

/// The paper-and-sun mark stays legible on small and system-tinted surfaces.
struct ShiriBrandMark: View {
    var size: CGFloat = 24
    var monochrome: Color? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color {
        monochrome ?? (colorScheme == .dark
            ? Color(red: 0.973, green: 0.945, blue: 0.859)
            : Color(red: 0.737, green: 0.376, blue: 0.286))
    }
    private var sun: Color { monochrome ?? Color(red: 0.914, green: 0.710, blue: 0.416) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(sun)
                .frame(width: size * 0.38, height: size * 0.38)
                .offset(x: size * 0.59, y: size * 0.02)
            RoundedRectangle(cornerRadius: size * 0.09)
                .fill(paper.opacity(0.42))
                .frame(width: size * 0.61, height: size * 0.73)
                .rotationEffect(.degrees(-9))
                .offset(x: size * 0.06, y: size * 0.17)
            ShiriPaperShape().fill(paper, style: FillStyle(eoFill: true))
                .frame(width: size * 0.62, height: size * 0.77)
                .offset(x: size * 0.24, y: size * 0.20)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

private struct ShiriPaperShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: rect.width * 0.15)
        let opening = CGRect(x: rect.width * 0.20, y: rect.height * 0.32,
                             width: rect.width * 0.60, height: rect.height * 0.12)
        path.addRoundedRect(in: opening, cornerSize: CGSize(width: opening.height / 2, height: opening.height / 2))
        return path
    }
}
