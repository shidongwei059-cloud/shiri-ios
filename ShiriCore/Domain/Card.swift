import Foundation
import ImageIO
import CryptoKit

public enum AppLimits {
    public static let titleLength = 120
    public static let noteLength = 2_000
    public static let attachmentCount = 6
    public static let attachmentBytes = 2_000_000
    public static let attachmentDimension = 2_048
    public static let shareBytes = 20_000_000
    public static let backupBytes = 200_000_000
    public static let notificationBudget = 48
    public static let geofenceBudget = 20
    public static let trashRetentionDays = 30
}

public enum CardKind: String, Codable, CaseIterable, Sendable {
    case task, note
    public var title: String { self == .task ? "待办" : "随手记" }
}

public enum CardLifecycle: String, Codable, CaseIterable, Sendable {
    case active, archived, deleted
}

public enum Importance: String, Codable, CaseIterable, Sendable {
    case normal, important, critical
    public var title: String {
        switch self { case .normal: return "普通"; case .important: return "重要"; case .critical: return "关键" }
    }
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum DataScope: String, Codable, CaseIterable, Sendable {
    case local, privateCloud
    public var title: String { self == .local ? "仅本机" : "我的 iCloud" }
}

extension Card {
    public var schedulingID: UUID? {
        if let schedule { return schedule.id }
        guard let birthday else { return nil }
        let parts = [birthday.calendar?.rawValue ?? "", String(birthday.month), String(birthday.day), String(birthday.isLeapMonth), String(birthday.repeatsYearly), birthday.missingDatePolicy.rawValue, birthday.leapMonthPolicy.rawValue, birthday.oneTimeDate?.key ?? "", birthday.dayTime?.display ?? ""]
        return StableID.uuid("birthday|\(id)|" + parts.joined(separator: "|"))
    }
}

public enum CardTheme: String, Codable, CaseIterable, Sendable {
    case butter, sage, blush, paper, mist
    public var title: String {
        switch self {
        case .butter: return "淡黄"; case .sage: return "浅绿"; case .blush: return "淡粉"
        case .paper: return "暖白"; case .mist: return "雾蓝"
        }
    }
}

public enum CardIllustration: String, Codable, CaseIterable, Sendable {
    case telephone = "Telephone", ginkgo = "Ginkgo", parcel = "Parcel"
    case photos = "TravelPhotos", seaside = "Seaside", candle = "BirthdayCandle"
    case tickets = "ExhibitionTickets", concert = "ConcertTicket", none
    public var title: String {
        switch self {
        case .telephone: return "电话"; case .ginkgo: return "银杏"; case .parcel: return "快递"
        case .photos: return "照片"; case .seaside: return "海边"; case .candle: return "生日"
        case .tickets: return "看展"; case .concert: return "音乐"; case .none: return "无插画"
        }
    }
}

public struct CardAppearance: Codable, Equatable, Sendable {
    public var theme: CardTheme = .butter
    public var illustration: CardIllustration = .ginkgo
    public var backgroundAttachmentID: UUID?
    public var customHex: String?
    @SortedSet public var overriddenFields: Set<String> = []
    public var version = 1
    public init() {}

    public static func recommended(for title: String, kind: CardKind, birthday: Bool = false) -> Self {
        var result = Self()
        let rules: [(String, CardTheme, CardIllustration)] = [
            ("电话|妈妈|家人", .butter, .telephone), ("快递|取件|包裹", .butter, .parcel),
            ("花|植物|阳台", .sage, .ginkgo), ("照片|旅行", .butter, .photos),
            ("看展|展览|美术", .butter, .tickets), ("演出|音乐|唱", .sage, .concert),
            ("海|周末|散步", .paper, .seaside)
        ]
        if birthday { result.theme = .blush; result.illustration = .candle; return result }
        result.theme = kind == .note ? .paper : .butter
        for (keywords, theme, illustration) in rules where keywords.split(separator: "|").contains(where: { title.contains($0) }) {
            result.theme = theme; result.illustration = illustration; break
        }
        return result
    }

    public mutating func applyRecommendation(_ recommendation: Self) {
        if !overriddenFields.contains("theme") { theme = recommendation.theme }
        if !overriddenFields.contains("illustration") { illustration = recommendation.illustration }
        if !overriddenFields.contains("background") { backgroundAttachmentID = recommendation.backgroundAttachmentID }
    }
}

public struct Card: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: CardKind
    public var title: String
    public var note: String
    public var category: String
    public var importance: Importance
    public var lifecycle: CardLifecycle
    public var scope: DataScope
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var isPinned: Bool
    public var appearance: CardAppearance
    public var schedule: ScheduleDefinition?
    public var reminders: ReminderPolicy
    public var birthday: BirthdayRule?
    public var place: PlaceRule?
    public var attachmentIDs: [UUID]
    public var revisionID: UUID
    /// Closing a series keeps its card and past occurrences; this is independent of completion.
    public var recurrenceClosedAt: Date?
    /// Optional fields keep existing cards and backups decodable.
    public var occasionLink: OccasionLink?
    public var memoryDate: Date?
    public var memory: MemoryMetadata?

    public init(id: UUID = UUID(), title: String, kind: CardKind = .task, now: Date) {
        self.id = id; self.title = title; self.kind = kind; self.note = ""; self.category = "生活"
        self.importance = .normal; self.lifecycle = .active; self.scope = .local
        self.createdAt = now; self.updatedAt = now; self.isPinned = false
        self.appearance = .recommended(for: title, kind: kind)
        self.reminders = ReminderPolicy(); self.attachmentIDs = []; self.revisionID = UUID()
    }

    public var canComplete: Bool { kind == .task && birthday == nil && lifecycle == .active && recurrenceClosedAt == nil }
    public var isMemory: Bool { memory != nil }
    public var isUndatedTask: Bool { kind == .task && schedule == nil && birthday == nil && place == nil }
    public var isRepeating: Bool { birthday?.repeatsYearly == true || (schedule != nil && schedule?.frequency != .never) }

    public func validated() throws -> Self {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw ShiriError.validation("请填写想记住的事情") }
        guard cleanTitle.count <= AppLimits.titleLength else { throw ShiriError.validation("标题最多 120 个字，请精简后保存") }
        guard note.count <= AppLimits.noteLength else { throw ShiriError.validation("备注最多 2,000 个字") }
        guard attachmentIDs.count <= AppLimits.attachmentCount else { throw ShiriError.validation("每张卡片最多添加 6 张图片") }
        if let schedule { try schedule.validate() }
        if let birthday { try birthday.validate() }
        if let place { try place.validate() }
        try reminders.validate()
        if reminders.isEnabled && schedule == nil && birthday == nil && place == nil {
            throw ShiriError.validation("请先选择提醒日期与时间，或关闭提醒后保存为长期待办")
        }
        if reminders.isEnabled && schedule?.time == nil && birthday == nil && place == nil {
            throw ShiriError.validation("请选择提醒时间；只有日期时不会自动安排凌晨提醒")
        }
        var copy = self; copy.title = cleanTitle; return copy
    }
}

public struct CardDraft: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var card: Card
    public var originalText: String
    /// Last text actually interpreted. Nil in old drafts requires a fresh review before saving.
    public var interpretedText: String?
    public var questions: [DraftQuestion]
    public var isEditing: Bool
    public var attachments: [Attachment]
    public var updatedAt: Date
    public var editingFrom: Occurrence?
    public var additionalDrafts: [CardDraft]?
    /// Unconfirmed memory dictation stays local with the draft until the user uses it.
    public var memorySpeechText: String?
    public init(card: Card, originalText: String = "", questions: [DraftQuestion] = [], isEditing: Bool = false) {
        self.id = card.id; self.card = card; self.originalText = originalText; self.questions = questions
        self.isEditing = isEditing; self.attachments = []; self.updatedAt = card.updatedAt
    }
}

public enum DraftQuestion: String, Codable, CaseIterable, Identifiable, Sendable {
    case title, date, time, meridiem, workday, invalidDate, location, calendar, pastReminder, ambiguousDates, reminderNodes, multipleTimes, repeatRule, interpretation
    public var id: String { rawValue }
    public var message: String {
        switch self {
        case .multipleTimes: return "说了多个时刻或时间范围，请确认提醒时间"
        case .repeatRule: return "这条重复规则无法直接生成，请核对重复方式或提醒时间"
        case .interpretation: return "这句话还有条件或多个动作，请核对内容和安排"
        case .reminderNodes: return "请检查提醒时间的时长和数量"
        case .title: return "想提醒自己做什么？"
        case .date: return "请选择具体日期"
        case .time: return "请选择提醒时间"
        case .meridiem: return "这个时间是上午还是下午？"
        case .workday: return "请选择周一至周五，或自行指定工作日期"
        case .invalidDate: return "部分月份没有这一天，请选择处理方式"
        case .location: return "请选择实际地点"
        case .calendar: return "请确认历法与生日日期"
        case .pastReminder: return "有提醒时间已经过去，不会补发，请确认安排"
        case .ambiguousDates: return "句子里有多个日期，请分别确认计划时间和提醒时间"
        }
    }
}

public struct Attachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var cardID: UUID
    public var mediaType: String
    public var width: Int
    public var height: Int
    public var data: Data
    public var digest: String
    public var sortIndex: Int
    public init(id: UUID = UUID(), cardID: UUID, data: Data, width: Int, height: Int, mediaType: String = "image/jpeg", sortIndex: Int = 0) {
        self.id = id; self.cardID = cardID; self.data = data; self.width = width; self.height = height
        self.mediaType = mediaType; self.digest = StableID.digest(data); self.sortIndex = sortIndex
    }
    public func validate() throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let realWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let realHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              realWidth == width, realHeight == height,
              (CGImageSourceGetType(source) as String?) == (mediaType == "image/jpeg" ? "public.jpeg" : "public.png") else { throw ShiriError.invalidFile("无法读取这张图片，请重新选择。") }
        guard data.count <= AppLimits.attachmentBytes, width > 0, height > 0,
              max(width, height) <= AppLimits.attachmentDimension,
              ["image/jpeg", "image/png"].contains(mediaType), StableID.digest(data) == digest else {
            throw ShiriError.invalidFile("图片无法使用，请重新选择或缩小图片后再试。")
        }
    }
}

public struct CardRevision: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var cardID: UUID
    public var parents: [UUID]
    public var actorID: String
    public var snapshot: Card
    public var createdAt: Date
    public init(card: Card, parents: [UUID], actorID: String, now: Date) {
        id = card.revisionID; cardID = card.id; self.parents = parents; self.actorID = actorID
        snapshot = card; createdAt = now
    }
}

public enum StableID {
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func hash(_ text: String) -> String { digest(Data(text.utf8)) }
    public static func uuid(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

public enum ShiriError: Error, LocalizedError, Equatable {
    case validation(String), invalidFile(String), storage(String), unavailable(String), conflict(String), notFound, canceled
    public var errorDescription: String? {
        switch self {
        case .validation(let message), .invalidFile(let message), .storage(let message), .unavailable(let message), .conflict(let message): return message
        case .notFound: return "这张卡片已不存在，请返回后刷新"
        case .canceled: return "操作已取消"
        }
    }
}
