import SwiftUI
import ShiriCore

enum Paper {
    static let background = adaptive("F8F7F3", "1D211E")
    static let surface = adaptive("FFFDFC", "292E29")
    static let ink = adaptive("191A17", "F1EEE3")
    static let secondary = adaptive("6B6D65", "B7BCAB")
    static let accent = adaptive("AD563F", "E69378")
    static let onAccent = adaptive("FFFFFF", "1D211E")
    static let separator = adaptive("DFDED8", "41483C")
    static let cardInk = Color(hex: "1D211A")
    static let cardSecondary = adaptive("75796B", "454D40")
    static let radius: CGFloat = 16
    static func adaptive(_ light: String, _ dark: String) -> Color {
        Color(uiColor: UIColor { trait in UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light) })
    }
    static func card(_ theme: CardTheme) -> Color {
        switch theme {
        case .butter: return adaptive("FCF3DA", "CBC298")
        case .sage: return adaptive("EDF0E3", "B2C3A0")
        case .blush: return adaptive("FAEBE5", "CBB5A4")
        case .paper: return adaptive("FFFEFC", "B7BCAF")
        case .mist: return adaptive("E2EBEA", "A6BCBB")
        }
    }
    static func title(_ size: CGFloat = 36) -> Font { .custom("NotoSerifSC-Regular", size: size, relativeTo: .body).weight(.semibold) }
    static func pageTitle() -> Font { .custom("NotoSerifSC-Regular", size: 42, relativeTo: .largeTitle).weight(.semibold) }
    static func text(_ size: CGFloat = 16) -> Font { .system(size: UIFontMetrics.default.scaledValue(for: size)) }
}
extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}
extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(cleaned, radix: 16) ?? 0xF7F5EF
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
struct PaperPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Paper.text(18)).foregroundColor(Paper.onAccent)
            .frame(maxWidth: .infinity).frame(minHeight: 50)
            .paperCard(Paper.accent, radius: 17)
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.5)
    }
}

/// The grain is drawn as part of the native surface; text and controls remain real views.
struct PaperGrain: View {
    // One small tile replaces thousands of paths per surface and per invalidation.
    // Keep the original dot size, density and opacity of the paper treatment.
    private static let texture: UIImage = {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.black.withAlphaComponent(0.025).cgColor)
            var seed: UInt64 = 73
            for _ in 0..<Int(size.width * size.height / 25) {
                seed = seed &* 6364136223846793005 &+ 1
                let x = CGFloat(seed % 10000) / 10000 * size.width
                seed = seed &* 6364136223846793005 &+ 1
                let y = CGFloat(seed % 10000) / 10000 * size.height
                context.fillEllipse(in: CGRect(x: x, y: y, width: 0.35, height: 0.35))
            }
        }
    }()
    var body: some View {
        Image(uiImage: Self.texture).resizable(resizingMode: .tile)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct PaperSurface: View {
    var color: Color = Paper.background
    var body: some View {
        color.overlay { LinearGradient(colors: [.white.opacity(0.08), .clear, .white.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing) }
            .overlay { PaperGrain() }
            .accessibilityHidden(true)
    }
}
extension View {
    func paperCard(_ color: Color = Paper.surface, radius: CGFloat = Paper.radius) -> some View {
        background { PaperSurface(color: color).clipShape(RoundedRectangle(cornerRadius: radius)) }
    }
}
struct PaperNavigationBar<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var title: String
    var back: String = "取消"
    var action: () -> Void
    @ViewBuilder var trailing: Trailing
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    Button(action: action) {
                        Image(systemName: back == "取消" ? "xmark" : "chevron.left").font(.system(size: 22, weight: .medium)).frame(width: 44, height: 44)
                    }.accessibilityLabel(back)
                    Text(title).font(Paper.title(18)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader).accessibilityIdentifier("paperNavigationTitle")
                    trailing
                }.padding(.vertical, 6)
            } else {
                ZStack {
                    Text(title).font(Paper.title(18)).accessibilityAddTraits(.isHeader).accessibilityIdentifier("paperNavigationTitle")
                    HStack { Button(back, action: action).font(Paper.text(17)).frame(minHeight: 44); Spacer(); trailing }
                }.frame(minHeight: 49)
            }
        }.foregroundColor(Paper.ink).padding(.horizontal, 21).background(Paper.background)
    }
}
struct PaperTabs: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    var labels: [String]
    var selection: String
    var fillsWidth = true
    var action: (String) -> Void
    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize { ScrollView(.horizontal, showsIndicators: false) { tabRow } }
            else { tabRow }
        }.background(alignment: .bottom) { Rectangle().fill(Paper.separator).frame(height: 0.5) }
    }
    private var tabRow: some View {
        HStack(spacing: dynamicType.isAccessibilitySize ? 28 : (fillsWidth ? 0 : 30)) {
            ForEach(labels, id: \.self) { label in
                Button { action(label) } label: {
                    VStack(spacing: 10) {
                        Text(label).font(Paper.text(18)).fontWeight(selection == label ? .semibold : .regular)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(selection == label ? Paper.accent : Paper.secondary)
                        Capsule().fill(selection == label ? Paper.accent : .clear).frame(width: label.count > 3 ? 86 : 47, height: 3)
                    }.frame(maxWidth: fillsWidth && !dynamicType.isAccessibilitySize ? .infinity : nil).padding(.top, 5)
                }.accessibilityAddTraits(selection == label ? .isSelected : [])
            }
            if !fillsWidth { Spacer(minLength: 0) }
        }
    }
}
struct PaperSwatches: View {
    var selection: CardTheme
    var colors: [CardTheme] = [.butter, .sage, .blush]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(colors, id: \.self) { theme in
                Circle().fill(Paper.card(theme)).frame(width: 26, height: 26)
                    .overlay { if selection == theme { Circle().stroke(Paper.accent, lineWidth: 1).padding(-2) } }
            }
        }.accessibilityLabel("卡片颜色：\(selection.title)")
    }
}

struct PaperIconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 20, weight: .regular)).frame(width: 44, height: 44) }
            .foregroundColor(Paper.ink).accessibilityLabel(label)
    }
}
struct PaperPageHeader: View {
    var title: String
    var subtitle: String
    var symbol: String = "leaf"
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Paper.title()).foregroundColor(Paper.ink)
                Spacer(minLength: 10)
                Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundColor(Paper.secondary).accessibilityHidden(true)
            }
            Text(subtitle).font(.subheadline).foregroundColor(Paper.secondary).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5).padding(.bottom, 9)
    }
}
enum PaperScene: String {
    case beginning, quiet, search, sharing, calendar, photos, review, archive
    var asset: String {
        switch self {
        case .beginning, .archive: return "PaperNotebook"
        case .quiet: return "QuietTea"
        case .search: return "SearchCards"
        case .sharing: return "PaperEnvelope"
        case .calendar: return "DeskCalendar"
        case .photos: return "TravelPhotos"
        case .review: return "ReviewFlowers"
        }
    }
}

struct PaperEmptyState: View {
    var title: String
    var message: String
    var scene: PaperScene = .beginning
    var compact = false
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            if !typeSize.isAccessibilitySize {
                Image(scene.asset).resizable().scaledToFit().frame(width: compact ? 88 : 126, height: compact ? 70 : 104)
                    .saturation(0.72).opacity(0.92).blendMode(scene == .photos ? .multiply : .normal).accessibilityHidden(true)
            }
            Text(title).font(Paper.title(compact ? 21 : 24)).foregroundColor(Paper.ink)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("emptyStateTitle")
            Text(message).font(Paper.text(15)).foregroundColor(Paper.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(Paper.text(16)).foregroundColor(Paper.accent)
                    .frame(minHeight: 44).padding(.horizontal, 14).background(Paper.background, in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityIdentifier("emptyStateAction")
            }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(compact ? 19 : 24)
            .paperCard().accessibilityElement(children: .contain)
    }
}
struct PaperFieldSection<Content: View>: View {
    var title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.footnote.weight(.medium)).foregroundColor(Paper.secondary)
            content
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading).background(Paper.surface, in: RoundedRectangle(cornerRadius: 19))
    }
}
struct PaperPill: View {
    var text: String
    var selected = false
    var body: some View {
        Text(text).font(.subheadline.weight(selected ? .semibold : .regular)).fixedSize(horizontal: true, vertical: false).foregroundColor(selected ? .white : Paper.secondary)
            .padding(.horizontal, 17).padding(.vertical, 10)
            .background(selected ? Color(hex: "778163") : Paper.surface, in: Capsule())
    }
}
struct PaperErrorBanner: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle").font(.subheadline).foregroundColor(Paper.accent)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Paper.surface, in: RoundedRectangle(cornerRadius: 14)).accessibilityIdentifier("errorBanner")
    }
}

/// A small outline set matching the approved paper UI, independent of SF Symbols variants.
struct PaperSymbol: View {
    var name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Group {
            if ["calendar", "note.text", "clock", "filter"].contains(name) {
                Canvas { context, size in
                    let scale = min(size.width, size.height) / 24
                    var path = Path()
                    switch name {
                    case "calendar":
                        path.addRoundedRect(in: CGRect(x: 3, y: 5, width: 18, height: 17), cornerSize: CGSize(width: 2, height: 2))
                        path.move(to: CGPoint(x: 3, y: 9)); path.addLine(to: CGPoint(x: 21, y: 9))
                        for x in [7.0,17.0] { path.move(to: CGPoint(x: x, y: 2)); path.addLine(to: CGPoint(x: x, y: 6)) }
                    case "note.text":
                        path.addRoundedRect(in: CGRect(x: 5, y: 2, width: 14, height: 20), cornerSize: CGSize(width: 2, height: 2))
                        for y in [7.0,11.0,15.0] { path.move(to: CGPoint(x: 8, y: y)); path.addLine(to: CGPoint(x: y == 15 ? 13 : 16, y: y)) }
                    case "clock":
                        path.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
                        path.move(to: CGPoint(x: 12, y: 6)); path.addLine(to: CGPoint(x: 12, y: 12)); path.addLine(to: CGPoint(x: 17, y: 12))
                    default:
                        path.addLines([CGPoint(x: 3, y: 3), CGPoint(x: 21, y: 3), CGPoint(x: 14, y: 12), CGPoint(x: 14, y: 21), CGPoint(x: 10, y: 18), CGPoint(x: 10, y: 12), CGPoint(x: 3, y: 3)])
                    }
                    context.scaleBy(x: scale, y: scale)
                    context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else { Image(systemName: name).resizable().scaledToFit() }
        }.frame(width: 24, height: 24).accessibilityHidden(true)
    }
}
