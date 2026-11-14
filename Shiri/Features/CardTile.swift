import SwiftUI
import ShiriCore

struct CardTile: View {
    var projection: CardProjection
    var compact = false
    var showsReminder = true
    var libraryStyle = false
    var isPreview = false
    var onOpen: () -> Void
    var onComplete: (() -> Void)?
    var backgroundData: Data? = nil
    @State private var loadedBackground: UIImage?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    private var card: Card { projection.card }
    private var hasPhoto: Bool { backgroundData != nil || loadedBackground != nil }
    private var darkPaper: Bool { card.appearance.needsLightInk }
    private var ink: Color { darkPaper ? .white : Paper.cardInk }
    private var secondary: Color { darkPaper ? .white.opacity(0.86) : Paper.cardSecondary }
    private var artwork: String? { CardArtwork.asset(for: card) }
    private var showsArtwork: Bool { artwork != nil && !hasPhoto && !typeSize.isAccessibilitySize && !darkPaper && card.title.count <= 26 }
    private var artInset: CGFloat { showsArtwork ? 82 : 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(timing).font(Paper.text(13)).foregroundColor(card.appearance.theme == .butter && !darkPaper ? Paper.adaptive("BC6049", "8A4430") : secondary)
                .padding(.trailing, onComplete == nil ? 0 : 36)
            Text(card.title).font(Paper.title(compact ? 21 : 22)).foregroundColor(ink).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                .lineLimit(isPreview ? 3 : nil).strikethrough(projection.state == .completed, color: secondary).padding(.trailing, artInset)
            if !card.note.isEmpty {
                Text(card.note.components(separatedBy: "\n").first ?? card.note).font(Paper.text(14)).foregroundColor(secondary)
                    .lineLimit(isPreview ? 2 : (typeSize.isAccessibilitySize ? nil : 2)).padding(.trailing, artInset)
            }
            if let deadline = CardPresentation.deadline(projection) {
                Label(CardPresentation.deadlineLabel(deadline, calendar: card.schedule?.calendar(fallback: model.calendar) ?? model.calendar), systemImage: "flag")
                    .font(.caption).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true).padding(.trailing, artInset)
            }
            if let state = CardPresentation.pendingTimeStatus(projection, now: model.now) {
                Label(state, systemImage: "clock").font(.caption).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true).padding(.trailing, artInset)
            }
            if projection.state == .completed { Label("已完成这一次", systemImage: "checkmark").font(.caption).foregroundColor(secondary).padding(.trailing, artInset) }
            if projection.state == .skipped { Label("已跳过这一次", systemImage: "forward.end").font(.caption).foregroundColor(secondary).padding(.trailing, artInset) }
            if projection.state == .pending, let until = projection.reminderState?.snoozedUntil, projection.reminderState?.isStopped != true {
                Label("此设备稍后：" + CardPresentation.dateLabel(until, format: "M月d日 HH:mm"), systemImage: "bell.badge")
                    .font(.caption).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true).padding(.trailing, artInset)
            }
            CardContextLine(card: card, color: secondary).padding(.trailing, artInset).padding(.top, 3)
            if projection.hasConflict {
                Label("有待确认的修改", systemImage: "arrow.triangle.branch").font(Paper.text(12)).foregroundColor(Paper.accent).padding(.trailing, artInset)
            } else if !compact && showsReminder && card.reminders.isEnabled {
                Label(isPreview ? "提醒设置 · " + card.reminders.channel.title : model.reminderStatus(for: projection).text, systemImage: "bell")
                    .font(Paper.text(12)).foregroundColor(secondary).padding(.trailing, artInset)
            }
        }.padding(14).frame(maxWidth: .infinity, minHeight: showsArtwork ? 108 : 0, alignment: .topLeading)
            .background(alignment: .bottomTrailing) {
                if showsArtwork, let artwork {
                    Image(artwork).resizable().scaledToFit().frame(width: 76, height: card.canComplete && onComplete != nil ? 48 : 62)
                        .saturation(0.78).blendMode(.multiply).opacity(projection.state == .completed ? 0.5 : 0.82)
                        .padding(.trailing, 12).padding(.bottom, 10).accessibilityHidden(true)
                }
            }
            .background {
                if let image = loadedBackground {
                    GeometryReader { geometry in Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                        .overlay(darkPaper ? Color.black.opacity(0.85) : Color.white.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: Paper.radius)).accessibilityHidden(true)
                }
            }
            .paperCard(card.appearance.customHex.map(Color.init(hex:)) ?? Paper.card(card.appearance.theme))
            .overlay { RoundedRectangle(cornerRadius: Paper.radius).strokeBorder(ink.opacity(0.05), lineWidth: 0.5).allowsHitTesting(false) }
            .contentShape(RoundedRectangle(cornerRadius: Paper.radius)).onTapGesture(perform: onOpen)
            .overlay(alignment: .topTrailing) {
                if card.canComplete, let onComplete {
                    Button(action: onComplete) {
                        Image(systemName: projection.state == .completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 23, weight: .light)).foregroundColor(secondary).frame(width: 44, height: 44)
                    }.accessibilityLabel(projection.state == .completed ? "撤销完成：\(card.title)" : "完成：\(card.title)").padding(5)
                } else if libraryStyle && card.kind == .note {
                    Image(systemName: card.isPinned ? "pin.fill" : "text.alignleft").font(.system(size: 14, weight: .regular)).foregroundColor(secondary)
                        .padding(16).accessibilityHidden(true)
                }
            }
            .task(id: BackgroundRequest(cardID: card.id, attachmentID: card.appearance.backgroundAttachmentID, preview: backgroundData)) {
                loadedBackground = nil
                let image: UIImage?
                if let backgroundData {
                    image = await CardThumbnailCache.shared.image(data: backgroundData)
                } else if let id = card.appearance.backgroundAttachmentID,
                          let attachment = try? await model.repository?.attachments(cardID: card.id).first(where: { $0.id == id }) {
                    image = await CardThumbnailCache.shared.image(data: attachment.data, cacheKey: attachment.digest)
                } else { image = nil }
                guard !Task.isCancelled else { return }
                loadedBackground = image
            }.accessibilityElement(children: .contain).accessibilityAction(named: "打开卡片", onOpen)
    }
    private struct BackgroundRequest: Equatable {
        var cardID: UUID
        var attachmentID: UUID?
        var preview: Data?
    }
    private var timing: String {
        if card.kind == .note { return card.birthday == nil ? "随手记" : CardPresentation.timing(projection) }
        let date = CardPresentation.relativeTiming(projection, now: model.now, calendar: model.calendar)
        return libraryStyle ? "待办 · \(card.isUndatedTask ? "未设日期" : date)" : date
    }
}

struct CardContextLine: View {
    let card: Card
    let color: Color
    var includesRepeat = true
    private var labels: [String] {
        var values: [String] = []
        if let place = card.place, !place.name.isEmpty { values.append(place.name) }
        if !card.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && card.category != "生活" { values.append(card.category) }
        if card.memoryDate != nil { values.append("已留在回忆册") }
        if card.importance != .normal { values.append(card.importance.title) }
        if includesRepeat && card.isRepeating && card.recurrenceClosedAt == nil { values.append(card.birthday != nil ? "每年" : card.schedule?.frequency.title ?? "重复") }
        if !card.attachmentIDs.isEmpty { values.append("\(card.attachmentIDs.count) 张图片") }
        if card.isPinned { values.append("已固定") }
        return values
    }
    var body: some View {
        if !labels.isEmpty {
            Text(labels.joined(separator: " · ")).font(Paper.text(12)).foregroundColor(color).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("cardContext")
        }
    }
}

/// UI-only fallbacks leave stored appearances and interchange formats unchanged.
/// An explicit illustration (including none), or a photo background, always wins.
enum CardArtwork {
    static func asset(for card: Card) -> String? {
        guard card.appearance.illustration != .none else { return nil }
        guard !card.appearance.overriddenFields.contains("illustration") else { return card.appearance.illustration.rawValue }
        if let birthday = card.birthday { return birthday.occasion == .anniversary ? "ReviewFlowers" : "BirthdayCandle" }
        if card.appearance.illustration == .ginkgo && !["花", "植物", "阳台"].contains(where: { card.title.contains($0) }) {
            return card.kind == .note || card.isUndatedTask ? "PaperNotebook" : "DeskCalendar"
        }
        return card.appearance.illustration.rawValue
    }
}
enum CardPresentation {
    static func deadline(_ projection: CardProjection) -> Date? {
        if let occurrence = projection.occurrence { return occurrence.dueAt }
        return projection.card.schedule?.dueAt
    }
    static func deadlineLabel(_ date: Date, calendar: Calendar) -> String {
        "截止：" + dateLabel(date, format: "yyyy年M月d日 HH:mm", calendar: calendar)
    }
    static func pendingTimeStatus(_ projection: CardProjection, now: Date) -> String? {
        guard projection.card.canComplete, projection.state == .pending else { return nil }
        if let dueAt = deadline(projection), dueAt <= now { return "已到截止 · 未标记完成" }
        return isOverdue(projection, now: now) ? "已到安排时间 · 未标记完成" : nil
    }
    static func relativeTiming(_ projection: CardProjection, now: Date, calendar: Calendar) -> String {
        if projection.card.recurrenceClosedAt != nil { return "重复已关闭" }
        let calendar = projection.card.schedule?.calendar(fallback: calendar) ?? calendar
        guard let date = projection.occurrence?.plannedAt ?? projection.card.schedule.flatMap({ OccurrenceEngine(calendar: calendar).date($0.start, time: $0.time ?? DayTime(hour: 0)) }) else { return timing(projection) }
        let time = projection.card.schedule?.time == nil ? "" : " " + DayTime(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date)).display
        if calendar.isDate(date, inSameDayAs: now) { return (calendar.component(.hour, from: date) >= 18 ? "今晚" : "今天") + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "明天" + time }
        return timing(projection)
    }
    static func dateLabel(_ date: Date, format: String = "M月d日 EEEE", calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = format
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    static func isOverdue(_ projection: CardProjection, now: Date) -> Bool {
        projection.card.canComplete && projection.state == .pending && projection.card.schedule?.time != nil && (projection.occurrence?.plannedAt.map { $0 < now } ?? false)
    }
    static func timing(_ projection: CardProjection) -> String {
        let card = projection.card
        if card.recurrenceClosedAt != nil { return "重复已关闭" }
        if let birthday = card.birthday { return "\(birthday.calendar?.title ?? "生日") · \(birthday.month)月\(birthday.day)日" }
        if let place = card.place { return "\(place.trigger.title) · \(place.name)" }
        guard let date = projection.occurrence?.plannedAt else {
            if let schedule = card.schedule { return "\(schedule.start.month)月\(schedule.start.day)日\(schedule.time.map { " " + $0.display } ?? "")" }
            return card.kind == .note ? "随手记" : "长期待办"
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = card.schedule?.calendar(fallback: .current).timeZone ?? .current
        formatter.dateFormat = card.schedule?.time == nil ? "M月d日 EEEE" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

extension CardAppearance {
    var needsLightInk: Bool {
        guard let hex = customHex, let number = UInt64(hex, radix: 16) else { return false }
        let channels = [Double((number >> 16) & 255)/255,Double((number >> 8) & 255)/255,Double(number & 255)/255].map { $0 <= 0.04045 ? $0/12.92 : pow(($0+0.055)/1.055,2.4) }
        return 0.2126*channels[0] + 0.7152*channels[1] + 0.0722*channels[2] < 0.22
    }
    var readableInk: Color { needsLightInk ? .white : Paper.cardInk }
    var readableSecondary: Color { needsLightInk ? .white.opacity(0.86) : Paper.cardSecondary }
}
