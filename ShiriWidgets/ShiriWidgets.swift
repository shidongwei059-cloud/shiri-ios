import SwiftUI
import WidgetKit
import ActivityKit
import ShiriCore

struct ShiriEntry: TimelineEntry { var date: Date; var snapshot: WidgetSnapshot? }
struct ShiriProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShiriEntry { ShiriWidgetSamples.entry() }
    func getSnapshot(in context: Context, completion: @escaping (ShiriEntry) -> Void) {
        if context.isPreview { completion(ShiriWidgetSamples.entry()); return }
        Task {
            do {
                let repo = try await ExtensionStore.open(author: "WidgetSnapshot")
                let library = try await repo.library()
                let preferences = try await repo.deviceValue(AppPreferences.self, key: "preferences") ?? AppPreferences()
                completion(ShiriEntry(date: Date(), snapshot: WidgetSnapshot.make(library: library, preferences: preferences, now: Date(), calendar: .current)))
            } catch { completion(ShiriEntry(date: Date(), snapshot: nil)) }
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShiriEntry>) -> Void) {
        Task {
            do {
                let repository = try await ExtensionStore.open(author: "WidgetTimeline")
                let library = try await repository.library(); let prefs = try await repository.deviceValue(AppPreferences.self, key: "preferences") ?? AppPreferences()
                let now = Date(); let calendar = Calendar.current
                let entries = (0..<5).map { index -> ShiriEntry in
                    let date = calendar.date(byAdding: .hour, value: index * 2, to: now)!
                    return ShiriEntry(date: date, snapshot: WidgetSnapshot.make(library: library, preferences: prefs, now: date, calendar: calendar))
                }
                completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800))))
            } catch { completion(Timeline(entries: [ShiriEntry(date: Date(), snapshot: nil)], policy: .after(Date().addingTimeInterval(1800)))) }
        }
    }
}
// Keep the system surfaces recognizably Shiri without competing with their content.
private struct WidgetPalette {
    var dark: Bool
    var paper: Color { dark ? Color(rgb: 0x202721) : Color(rgb: 0xFAF7F0) }
    var ink: Color { dark ? Color(rgb: 0xF1EEE3) : Color(rgb: 0x242A23) }
    var secondary: Color { dark ? Color(rgb: 0xB8C0B0) : Color(rgb: 0x696F64) }
    var accent: Color { dark ? Color(rgb: 0xEEA184) : Color(rgb: 0xA94F38) }
    var line: Color { dark ? Color(rgb: 0x444E41) : Color(rgb: 0xDEDCCE) }
    var wash: Color { dark ? Color(rgb: 0x303A30) : Color(rgb: 0xEEEEDF) }
    static let islandAccent = Color(rgb: 0xF2BD83)
}
private extension Color {
    init(rgb: UInt32) { self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255) }
}

/// The compact paper-and-sun mark echoes the app icon.
private struct ShiriSeal: View {
    var size: CGFloat = 23
    var island = false
    var body: some View {
        ShiriBrandMark(size: size, monochrome: island ? WidgetPalette.islandAccent : nil)
            .widgetAccentable().accessibilityHidden(true)
    }
}

struct VoiceCaptureButton: View {
    var compact = false
    var island = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var palette: WidgetPalette { WidgetPalette(dark: colorScheme == .dark) }
    var body: some View {
        Group {
            if #available(iOS 18.0, *) { Button(intent: StartWidgetVoiceIntent()) { label } }
            else if #available(iOS 17.0, *) { Button(intent: OpenVoiceComposerIntent()) { label } }
            else { Link(destination: ComposerInputMode.voiceURL) { label } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("语音新建待办")
        .accessibilityHint(voiceCaptureHint)
        .accessibilityIdentifier("widgetVoiceCapture")
    }
    private var voiceCaptureHint: String {
        if #available(iOS 18.0, *) { return "开始录音，在实时活动中停止并确认保存" }
        return "打开拾日，录音并确认新的待办"
    }
    private var label: some View {
        Group {
            if compact { Image(systemName: "mic.fill").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44) }
            else { Label("语音新建", systemImage: "mic.fill").font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(minHeight: 44) }
        }
        .foregroundColor(island ? WidgetPalette.islandAccent : palette.accent)
        .background {
            if island { Capsule().fill(WidgetPalette.islandAccent.opacity(0.14)) }
            else if renderingMode == .fullColor { Capsule().fill(palette.accent.opacity(colorScheme == .dark ? 0.13 : 0.08)) }
            else { Capsule().strokeBorder(.primary.opacity(0.4), lineWidth: 1) }
        }
        .contentShape(Capsule()).widgetAccentable()
    }
}

private struct WidgetScheduleLabel: View {
    var card: WidgetCard
    var reference: Date
    var compact = false
    private var calendar: Calendar { .current }
    var body: some View {
        Group {
            if let date = card.plannedAt {
                if card.isDateOnly == true {
                    Text(calendar.isDate(date, inSameDayAs: reference) ? "今天 · 全天" : date.formatted(.dateTime.month().day()) + " · 全天")
                } else if calendar.isDate(date, inSameDayAs: reference) {
                    Text(date, style: .time)
                } else {
                    Text(date, format: compact ? .dateTime.month().day() : .dateTime.month().day().hour().minute())
                }
            } else { Text(card.canComplete ? "有空时做" : "收好的念头") }
        }.lineLimit(1).minimumScaleFactor(0.85).monospacedDigit()
    }
}

struct ShiriWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    var entry: ShiriEntry
    private var palette: WidgetPalette { WidgetPalette(dark: colorScheme == .dark) }
    private var isAccessory: Bool { family == .accessoryInline || family == .accessoryRectangular }
    private var destination: URL { entry.snapshot?.hidesContent == true ? URL(string: "nianyi://today")! : entry.snapshot?.cards.first?.url ?? URL(string: "nianyi://today")! }
    private var showsVoiceButton: Bool {
        if #available(iOS 17.0, *) { return true }
        return family != .systemSmall
    }
    var body: some View {
        Group {
            if family == .accessoryInline { inline }
            else if family == .accessoryRectangular { accessory }
            else if family == .systemMedium { medium }
            else { small }
        }
        .foregroundColor(isAccessory ? .primary : palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(destination)
        .modifier(WidgetPaperBackground(accessory: isAccessory))
    }
    private var header: some View {
        HStack(spacing: 7) {
            ShiriSeal(size: 21)
            Text("拾日").font(.system(size: 12, weight: .semibold, design: .serif)).tracking(1)
            Spacer(minLength: 0)
            if showsVoiceButton { VoiceCaptureButton(compact: true).padding(.trailing, -6) }
        }.frame(height: 30)
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let snapshot = entry.snapshot, !snapshot.hidesContent, let card = snapshot.cards.first {
                Link(destination: card.url) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.title).font(.system(size: 18, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.9)
                        if !card.note.isEmpty { Text(card.note).font(.system(size: 11)).foregroundColor(palette.secondary).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 3) {
                        WidgetScheduleLabel(card: card, reference: entry.date).font(.system(size: 11, weight: .medium)).foregroundColor(palette.accent)
                        if snapshot.pendingCount > 1 { Text("还有 \(snapshot.pendingCount - (card.canComplete ? 1 : 0)) 件待办").font(.system(size: 10)).foregroundColor(palette.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    completeButton(card)
                }
            } else {
                quietContent
                Spacer(minLength: 0)
                Text(entry.date, format: .dateTime.month().day().weekday(.wide)).font(.system(size: 10)).foregroundColor(palette.secondary).lineLimit(1)
            }
        }
    }
    private var medium: some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { ShiriSeal(size: 20); Text("拾日").font(.system(size: 11, weight: .semibold, design: .serif)) }
                Spacer(minLength: 5)
                Text(String(Calendar.current.component(.day, from: entry.date)))
                    .font(.system(size: 39, weight: .light, design: .serif)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).widgetAccentable()
                Text(entry.date, format: .dateTime.month().weekday(.wide)).font(.system(size: 10)).foregroundColor(palette.secondary).lineLimit(1)
                Spacer(minLength: 5)
                Text("\(entry.snapshot?.pendingCount ?? 0) 件待办").font(.system(size: 10, weight: .medium)).foregroundColor(palette.accent).lineLimit(1)
            }.frame(width: 70, alignment: .leading)
            Rectangle().fill(palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(entry.snapshot?.hidesContent == true ? "留给自己" : "接下来的小事").font(.system(size: 11, weight: .medium)).foregroundColor(palette.secondary)
                    Spacer(minLength: 0)
                    VoiceCaptureButton(compact: true).padding(.trailing, -6)
                }.frame(height: 27).padding(.bottom, 4)
                if let snapshot = entry.snapshot, !snapshot.hidesContent, !snapshot.cards.isEmpty {
                    let cards = Array(snapshot.cards.prefix(3))
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        mediumRow(card, showsNote: cards.count == 1)
                        if index < cards.count - 1 { Rectangle().fill(palette.line.opacity(0.7)).frame(height: 0.5) }
                    }
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    quietContent
                    Spacer(minLength: 0)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func mediumRow(_ card: WidgetCard, showsNote: Bool) -> some View {
        HStack(spacing: 5) {
            Link(destination: card.url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        if card.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)).accessibilityLabel("置顶") }
                        WidgetScheduleLabel(card: card, reference: entry.date).font(.system(size: 10)).foregroundColor(palette.secondary)
                    }
                    if showsNote, !card.note.isEmpty { Text(card.note).font(.system(size: 11)).foregroundColor(palette.secondary).lineLimit(2).padding(.top, 3) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            completeButton(card)
        }.frame(maxHeight: .infinity).padding(.vertical, 3)
    }
    @ViewBuilder private func completeButton(_ card: WidgetCard) -> some View {
        if #available(iOS 17.0, *), card.canComplete, let occurrenceID = card.occurrenceID {
            Button(intent: CompleteCardIntent(cardID: card.id, occurrenceID: occurrenceID)) {
                Image(systemName: "circle").font(.system(size: 23, weight: .ultraLight))
                    .foregroundColor(palette.accent).frame(width: 23, height: 23)
                    .frame(width: family == .systemMedium ? 32 : 38, height: family == .systemMedium ? 32 : 38)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).widgetAccentable().accessibilityLabel("完成\(card.title)")
        }
    }
    private var quietContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let snapshot = entry.snapshot {
                if snapshot.hidesContent {
                    Image(systemName: "lock").font(.system(size: 18, weight: .light)).foregroundColor(palette.accent).widgetAccentable()
                    Text("\(snapshot.pendingCount) 件待办").font(.system(size: family == .systemMedium ? 19 : 20, weight: .medium, design: .serif))
                    Text("轻点查看，内容只留给你。").font(.system(size: 11)).foregroundColor(palette.secondary).lineLimit(2)
                } else {
                    Image(systemName: "sun.horizon").font(.system(size: 22, weight: .ultraLight)).foregroundColor(palette.accent).widgetAccentable()
                    Text("留一点空白").font(.system(size: 18, weight: .medium, design: .serif))
                    Text("想到的小事，说给拾日听。").font(.system(size: 11)).foregroundColor(palette.secondary).lineLimit(2)
                }
            } else {
                Image(systemName: "rectangle.and.pencil.and.ellipsis").font(.system(size: 21, weight: .light)).foregroundColor(palette.accent).widgetAccentable()
                Text("收好日常小事").font(.system(size: 18, weight: .medium, design: .serif))
                Text("打开拾日，让卡片来到这里。").font(.system(size: 11)).foregroundColor(palette.secondary).lineLimit(2)
            }
        }
    }
    private var inline: some View {
        Label(entry.snapshot?.hidesContent == true ? "拾日 · \(entry.snapshot?.pendingCount ?? 0) 件待办" : entry.snapshot?.cards.first?.title ?? "拾日 · 留一点空白", systemImage: "checklist")
    }
    private var accessory: some View {
        HStack(spacing: 7) {
            Rectangle().fill(.primary).frame(width: 2).widgetAccentable()
            VStack(alignment: .leading, spacing: 3) {
                Text("拾日 · 待办").font(.system(size: 10, weight: .medium)).widgetAccentable()
                Text(entry.snapshot?.hidesContent == true ? "\(entry.snapshot?.pendingCount ?? 0) 件待办" : entry.snapshot?.cards.first?.title ?? "留一点空白").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if entry.snapshot?.hidesContent != true, let card = entry.snapshot?.cards.first {
                    WidgetScheduleLabel(card: card, reference: entry.date, compact: true).font(.system(size: 10))
                } else { Text(entry.snapshot?.hidesContent == true ? "打开拾日查看" : "想到什么，说下来").font(.system(size: 10)) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VoiceCaptureButton(compact: true)
        }
    }
}

/// Also available when there is no active reminder.
struct ShiriVoiceWidget: Widget {
    let kind = "NianYiVoiceCapture"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VoiceEntryProvider()) { _ in VoiceEntryWidgetView() }
            .configurationDisplayName("拾日 · 语音待办")
            .description("iOS 18 起可直接录音，在实时活动中核对保存；首次使用请先在拾日授权语音。")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}
struct VoiceEntryProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShiriEntry { ShiriEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (ShiriEntry) -> Void) { completion(placeholder(in: context)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShiriEntry>) -> Void) { completion(Timeline(entries: [placeholder(in: context)], policy: .never)) }
}
struct VoiceEntryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    private var palette: WidgetPalette { WidgetPalette(dark: colorScheme == .dark) }
    var body: some View {
        Group {
            if #available(iOS 18.0, *), family != .accessoryInline {
                Button(intent: StartWidgetVoiceIntent()) { content }.buttonStyle(.plain)
                    .accessibilityLabel("语音新建待办").accessibilityHint("开始录音，在实时活动中停止并确认保存")
            } else {
                content.widgetURL(ComposerInputMode.voiceURL)
                    .accessibilityLabel("打开拾日语音输入")
            }
        }.accessibilityIdentifier("voiceCaptureWidget")
            .modifier(WidgetPaperBackground(accessory: family != .systemSmall))
    }
    private var content: some View {
        Group {
            if family == .accessoryInline { Label("拾日 · 语音待办", systemImage: "mic") }
            else if family == .accessoryCircular { Image(systemName: "mic.fill").font(.title2).frame(maxWidth: .infinity, maxHeight: .infinity).background { AccessoryWidgetBackground() } }
            else if family == .accessoryRectangular {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2).widgetAccentable()
                    VStack(alignment: .leading, spacing: 4) { Text("说一件小事").font(.headline); Text("拾日 · 语音待办").font(.caption) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { ShiriSeal(size: 21); Text("拾日").font(.system(size: 12, weight: .semibold, design: .serif)); Spacer(); Image(systemName: "waveform").font(.system(size: 11)).foregroundColor(palette.secondary) }
                    Spacer(minLength: 0)
                    HStack(alignment: .center, spacing: 11) {
                        Image(systemName: "mic.fill").font(.system(size: 25, weight: .light)).foregroundColor(palette.accent).widgetAccentable()
                        HStack(spacing: 3) { ForEach(Array([9.0, 18, 28, 17, 9].enumerated()), id: \.offset) { _, height in Capsule().fill(palette.accent.opacity(0.35)).frame(width: 2, height: height) } }.accessibilityHidden(true)
                    }
                    Text("说一件小事").font(.system(size: 20, weight: .medium, design: .serif)).foregroundColor(palette.ink)
                    Text("轻点录音，停止后核对保存。").font(.system(size: 11)).foregroundColor(palette.secondary).lineLimit(2)
                }
            }
        }
    }
}

@available(iOS 18.0, *)
struct VoiceCaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceCaptureAttributes.self) { context in
            VoiceCaptureActivityContent(attributes: context.attributes, state: context.state)
                .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "mic.fill").foregroundColor(.orange) }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .recording { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VoiceCaptureActivityContent(attributes: context.attributes, state: context.state, island: true)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .recording ? "mic.fill" : "checkmark.bubble")
            } compactTrailing: {
                Text(context.state.phase == .recording ? "录音" : "核对").font(.caption)
            } minimal: { Image(systemName: "mic.fill") }
        }
    }
}

@available(iOS 18.0, *)
struct VoiceCaptureActivityContent: View {
    let attributes: VoiceCaptureAttributes
    let state: VoiceCaptureAttributes.ContentState
    var island = false
    @Environment(\.colorScheme) private var colorScheme
    private var palette: WidgetPalette { WidgetPalette(dark: island || colorScheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(state.phase == .recording ? "拾日 · 正在录音" : "拾日 · 语音卡片", systemImage: "waveform")
                    .font(.caption).foregroundColor(palette.secondary)
                Spacer()
                if state.phase == .recording { Text(attributes.startedAt, style: .timer).font(.caption).monospacedDigit() }
            }
            Text(state.title).font(.headline).lineLimit(2).privacySensitive()
            Text(state.detail).font(.caption).foregroundColor(palette.secondary).lineLimit(2)
            HStack {
                if state.phase == .recording {
                    Button(intent: StopWidgetVoiceIntent()) { Label("停止并核对", systemImage: "stop.fill") }
                        .accessibilityIdentifier("widgetVoiceStop")
                } else if state.phase == .review {
                    Button(intent: SaveWidgetVoiceIntent(id: attributes.draftID)) { Label("确认保存", systemImage: "checkmark") }
                        .accessibilityIdentifier("widgetVoiceSave")
                } else if state.phase == .needsReview {
                    Link("打开核对", destination: URL(string: "nianyi://draft/\(attributes.draftID)")!)
                } else if state.phase == .failed {
                    Link("打开语音输入", destination: ComposerInputMode.voiceURL)
                }
                Spacer()
                if state.phase != .recording && state.phase != .processing && state.phase != .saved {
                    Button(intent: DismissWidgetVoiceIntent(id: attributes.draftID)) { Text(state.phase == .failed ? "关闭" : "保留草稿") }
                }
            }.font(.subheadline).buttonStyle(.bordered).tint(.brown)
        }.foregroundColor(palette.ink).activityBackgroundTint(palette.paper).activitySystemActionForegroundColor(palette.ink)
    }
}
struct WidgetPaperBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    var accessory: Bool
    private var palette: WidgetPalette { WidgetPalette(dark: colorScheme == .dark) }
    @ViewBuilder private var background: some View {
        if !accessory, renderingMode == .fullColor {
            palette.paper
                .overlay(alignment: .bottomTrailing) {
                    // A restrained paper fold remains behind content and disappears in tinted / clear modes.
                    RoundedRectangle(cornerRadius: 40).stroke(palette.line.opacity(0.5), lineWidth: 0.5)
                        .frame(width: 150, height: 110).rotationEffect(.degrees(-24)).offset(x: 85, y: 62)
                }
        }
    }
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) { content.containerBackground(for: .widget) { background } }
        else { content.padding(accessory ? 0 : 14).background { background } }
    }
}
struct ShiriTodayWidget: Widget {
    let kind = "NianYiToday"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ShiriProvider()) { ShiriWidgetView(entry: $0) }
            .configurationDisplayName("拾日 · 日常卡片").description("收好接下来的小事，轻点麦克风语音新增。")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}

@available(iOS 16.1, *)
struct ShiriLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiriActivityAttributes.self) { context in
            ShiriActivityLockScreen(state: context.state, cardID: context.attributes.cardID)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) { ShiriSeal(size: 22, island: true); Text("拾日 · 待办").font(.system(size: 12, weight: .medium)).foregroundColor(WidgetPalette.islandAccent) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ShiriActivityTime(state: context.state, compact: true).foregroundColor(WidgetPalette.islandAccent).frame(maxWidth: 85)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Link(destination: URL(string: "nianyi://card/\(context.attributes.cardID)")!) {
                            Text(context.state.title).font(.system(size: 20, weight: .semibold)).foregroundColor(.white).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 8) {
                            ActivityScheduleLabel(state: context.state).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                            Spacer(minLength: 0)
                            VoiceCaptureButton(island: true)
                        }
                    }.padding(.top, 7).padding(.bottom, 5)
                }
            } compactLeading: {
                ShiriSeal(size: 21, island: true)
            } compactTrailing: {
                ShiriActivityTime(state: context.state, compact: true).foregroundColor(WidgetPalette.islandAccent).frame(maxWidth: 58)
            } minimal: {
                ShiriSeal(size: 20, island: true)
            }
            .keylineTint(WidgetPalette.islandAccent)
            .widgetURL(URL(string: "nianyi://card/\(context.attributes.cardID)"))
        }
    }
}
@available(iOS 16.1, *)
private struct ActivityScheduleLabel: View {
    var state: ShiriActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.targetDate == nil ? "circle.dashed" : state.isDateOnly == true ? "calendar" : "clock")
            if let date = state.targetDate {
                if state.isDateOnly == true { Text(date, format: .dateTime.month().day()); Text("全天") }
                else { Text(date, format: .dateTime.month().day().hour().minute()) }
            } else { Text("有空时做 · 待完成") }
        }.lineLimit(1).minimumScaleFactor(0.85)
    }
}
@available(iOS 16.1, *)
struct ShiriActivityTime: View {
    var state: ShiriActivityAttributes.ContentState
    var compact = false
    var body: some View {
        if let target = state.targetDate {
            if state.isDateOnly == true { Text(compact ? "全天" : "待完成").font(.caption) }
            else if compact { Text(target, style: .timer).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75) }
            else { Text(target, style: .relative) }
        } else { Text(compact ? "待办" : "有空时做 · 待完成").font(.caption) }
    }
}
@available(iOS 16.1, *)
struct ShiriActivityLockScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    var state: ShiriActivityAttributes.ContentState
    var cardID: String
    private var palette: WidgetPalette { WidgetPalette(dark: colorScheme == .dark) }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    ShiriSeal(size: 19)
                    Text(state.isHidden ? "留给自己的小事" : "拾日 · 待办提醒").font(.system(size: 11, weight: .medium)).foregroundColor(palette.accent)
                }
                Text(state.title).font(.system(size: 19, weight: .semibold)).foregroundColor(palette.ink).lineLimit(2)
                ActivityScheduleLabel(state: state).font(.system(size: 12)).foregroundColor(palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VoiceCaptureButton(compact: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        // Keep the paper and ink in one rendering environment when the lock screen changes appearance.
        .background(palette.paper)
        .activityBackgroundTint(.clear)
        .activitySystemActionForegroundColor(palette.ink)
        .widgetURL(URL(string: "nianyi://card/\(cardID)"))
    }
}

private enum ShiriWidgetSamples {
    static let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 18, minute: 40))!
    static func entry(empty: Bool = false, hidden: Bool = false, at date: Date = Date()) -> ShiriEntry {
        var library = LibrarySnapshot()
        if !empty {
            for (index, title) in ["给妈妈打个电话", "去花店取花", "整理旅行照片"].enumerated() {
                var card = Card(title: title, now: date)
                card.note = index == 0 ? "聊聊这个星期的新鲜事" : ""
                if index < 2 { card.schedule = ScheduleDefinition(start: CivilDate(date, calendar: .current), time: DayTime(hour: 19 + index, minute: 30)) }
                library.cards.append(card)
            }
        }
        var preferences = AppPreferences(); if hidden { preferences.widgetPrivacy = .hidden }
        return ShiriEntry(date: date, snapshot: WidgetSnapshot.make(library: library, preferences: preferences, now: date, calendar: .current))
    }
}
#if DEBUG
struct ShiriWidgetPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            ShiriWidgetView(entry: ShiriWidgetSamples.entry(at: ShiriWidgetSamples.date)).previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("小尺寸 · 有待办")
            ShiriWidgetView(entry: ShiriWidgetSamples.entry(at: ShiriWidgetSamples.date)).previewContext(WidgetPreviewContext(family: .systemMedium)).previewDisplayName("中尺寸 · 三件事")
            ShiriWidgetView(entry: ShiriWidgetSamples.entry(empty: true, at: ShiriWidgetSamples.date)).previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("留白空态")
            ShiriWidgetView(entry: ShiriWidgetSamples.entry(hidden: true, at: ShiriWidgetSamples.date)).previewContext(WidgetPreviewContext(family: .systemMedium)).preferredColorScheme(.dark).previewDisplayName("深色 · 隐藏内容")
            ShiriWidgetView(entry: ShiriEntry(date: ShiriWidgetSamples.date, snapshot: nil)).previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("等待同步")
            VoiceEntryWidgetView().previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("语音待办")
        }
    }
}
#endif

@main
struct ShiriWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder var body: some Widget {
        ShiriTodayWidget()
        ShiriVoiceWidget()
        if #available(iOS 18.0, *) { VoiceCaptureLiveActivity() }
        if #available(iOS 16.1, *) { ShiriLiveActivityWidget() }
    }
}
