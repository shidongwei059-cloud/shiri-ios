import Foundation

public struct DayTime: Codable, Equatable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int, minute: Int = 0) { self.hour = hour; self.minute = minute }
    public var display: String { String(format: "%02d:%02d", hour, minute) }
    public var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
}

public struct CivilDate: Codable, Equatable, Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public init(_ date: Date, calendar: Calendar) {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        year = values.year ?? 2000; month = values.month ?? 1; day = values.day ?? 1
    }
    public var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

public enum TimeZoneMode: String, Codable, CaseIterable, Sendable {
    case floating, fixed, elapsed
    public var title: String {
        switch self { case .floating: return "随当地时区"; case .fixed: return "固定时区"; case .elapsed: return "固定时长" }
    }
}

public enum RepeatFrequency: String, Codable, CaseIterable, Sendable {
    case never, daily, weekly, monthly, yearly
    public var title: String {
        switch self { case .never: return "不重复"; case .daily: return "每天"; case .weekly: return "每周"; case .monthly: return "每月"; case .yearly: return "每年" }
    }
}

public enum MissingDatePolicy: String, Codable, CaseIterable, Sendable {
    case unspecified, lastValidDay, skip
    public var title: String {
        switch self { case .unspecified: return "请选择"; case .lastValidDay: return "当月最后一天"; case .skip: return "跳过没有这一天的月份" }
    }
}

public struct ScheduleDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var version: Int
    public var start: CivilDate
    public var time: DayTime?
    public var frequency: RepeatFrequency
    public var interval: Int
    /// Calendar weekday: Sunday=1, Monday=2 … Saturday=7.
    @SortedSet public var weekdays: Set<Int> = []
    public var monthDay: Int
    public var month: Int
    public var end: CivilDate?
    public var missingDatePolicy: MissingDatePolicy
    public var timeZoneMode: TimeZoneMode
    public var timeZoneIdentifier: String
    public var absoluteInstant: Date?
    public var dueAt: Date?

    public init(start: CivilDate, time: DayTime?, frequency: RepeatFrequency = .never, timeZone: TimeZone = .current) {
        id = UUID(); version = 1; self.start = start; self.time = time; self.frequency = frequency
        interval = 1; weekdays = []; monthDay = start.day; month = start.month
        missingDatePolicy = .unspecified; timeZoneMode = .floating; timeZoneIdentifier = timeZone.identifier
    }
    public func calendar(fallback: Calendar) -> Calendar {
        var value = fallback
        value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        if timeZoneMode == .fixed { value.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? fallback.timeZone }
        return value
    }
    /// A manual date, clock, or repeat edit replaces a spoken duration such as “20 minutes later”.
    public mutating func useCalendarTiming() {
        if timeZoneMode == .elapsed { timeZoneMode = .floating }
        absoluteInstant = nil
    }
    public func validate() throws {
        guard interval > 0, interval <= 366, (1...12).contains(start.month), (1...31).contains(start.day),
              (1900...2200).contains(start.year), time == nil || time!.isValid else {
            throw ShiriError.validation("日期或时间不正确")
        }
        let civilCalendar = Calendar(identifier: .gregorian)
        guard let validDate = civilCalendar.date(from: DateComponents(year: start.year, month: start.month, day: start.day)), CivilDate(validDate, calendar: civilCalendar) == start,
              (1...31).contains(monthDay), (1...12).contains(month) else { throw ShiriError.validation("日期不存在，请选择有效日期") }
        if let end {
            guard let endDate = civilCalendar.date(from: DateComponents(year: end.year, month: end.month, day: end.day)), CivilDate(endDate, calendar: civilCalendar) == end else { throw ShiriError.validation("结束日期不存在") }
        }
        if frequency == .weekly && (weekdays.isEmpty || !weekdays.allSatisfy({ (1...7).contains($0) })) {
            throw ShiriError.validation("请选择每周重复的星期")
        }
        if [.monthly, .yearly].contains(frequency) && monthDay > 28 && missingDatePolicy == .unspecified {
            throw ShiriError.validation("部分月份没有这一天，请选择月末处理方式")
        }
        if timeZoneMode == .fixed && TimeZone(identifier: timeZoneIdentifier) == nil { throw ShiriError.validation("请选择有效时区") }
        if timeZoneMode == .elapsed && absoluteInstant == nil { throw ShiriError.validation("缺少倒计时目标时间") }
        if let end, end.key < start.key { throw ShiriError.validation("结束日期不能早于开始日期") }
    }
}

public enum ReminderChannel: String, Codable, CaseIterable, Sendable {
    case notification, alarm
    public var title: String { self == .notification ? "普通通知" : "系统闹钟" }
}

public struct ReminderPolicy: Codable, Equatable, Sendable {
    public static let advanceLimit = 6
    public static let followUpLimit = 3
    public static let maximumAdvanceMinutes = 525_600
    public static let maximumFollowUpMinutes = 1_440
    public var isEnabled = false
    public var channel: ReminderChannel = .notification
    /// Minutes before occurrence. Zero is the main at-time reminder.
    public var advanceMinutes: [Int] = [0]
    /// Finite extra reminders after occurrence, only populated by an explicit choice.
    public var followUpMinutes: [Int] = []
    public var enablesLiveActivity = false
    public var scheduledLiveActivity = false
    public init() {}
    public static func nodeLabel(_ minutes: Int, followUp: Bool = false) -> String {
        if minutes < 0 { return "待修正的提醒时间" }
        if minutes == 0 { return "准时" }
        let days = minutes / 1_440, hours = minutes % 1_440 / 60, remainder = minutes % 60
        let duration = [(days, "天"), (hours, "小时"), (remainder, "分钟")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " ")
        return (followUp ? "之后 " : "提前 ") + duration
    }
    public var nodesSummary: String {
        (Set(advanceMinutes).sorted(by: >).map { Self.nodeLabel($0) }
         + Set(followUpMinutes).sorted().map { Self.nodeLabel($0, followUp: true) }).joined(separator: "、")
    }
    /// Validate a copy before applying an edit; equivalent units collapse to one node.
    public mutating func setNode(_ minutes: Int, followUp: Bool, replacing oldValue: Int? = nil) throws {
        var copy = self
        var values = Set(followUp ? followUpMinutes : advanceMinutes)
        if let oldValue { values.remove(oldValue) }
        values.insert(minutes)
        if followUp { copy.followUpMinutes = values.sorted() }
        else { copy.advanceMinutes = values.sorted() }
        try copy.validate()
        self = copy
    }
    public func validate() throws {
        guard Set(advanceMinutes).count <= Self.advanceLimit, Set(followUpMinutes).count <= Self.followUpLimit,
              advanceMinutes.allSatisfy({ (0...Self.maximumAdvanceMinutes).contains($0) }),
              followUpMinutes.allSatisfy({ (1...Self.maximumFollowUpMinutes).contains($0) }) else {
            throw ShiriError.validation("提醒时间超出支持范围，请减少次数或调整时间")
        }
        if isEnabled && advanceMinutes.isEmpty { throw ShiriError.validation("请选择至少一个提醒时间") }
    }
}

public enum BirthdayCalendar: String, Codable, CaseIterable, Sendable {
    case gregorian, lunar
    public var title: String { self == .gregorian ? "公历" : "农历" }
}

public enum LeapMonthPolicy: String, Codable, CaseIterable, Sendable {
    case unspecified, leapOnly, regularWhenMissing
    public var title: String {
        switch self { case .unspecified: return "请选择"; case .leapOnly: return "只在对应闰月提醒"; case .regularWhenMissing: return "没有闰月时用同名普通月" }
    }
}

public enum OccasionKind: String, Codable, CaseIterable, Sendable {
    case birthday, anniversary
    public var title: String { self == .birthday ? "生日" : "纪念日" }
}
public struct BirthdayRule: Codable, Equatable, Sendable {
    public var occasion: OccasionKind?
    public var name: String
    public var calendar: BirthdayCalendar?
    public var month: Int
    public var day: Int
    public var birthYear: Int?
    public var isLeapMonth = false
    public var repeatsYearly = true
    public var missingDatePolicy: MissingDatePolicy = .unspecified
    public var leapMonthPolicy: LeapMonthPolicy = .unspecified
    public var advanceDays: [Int] = []
    public var advanceTime: DayTime?
    public var dayTime: DayTime?
    public var oneTimeDate: CivilDate?
    public init(name: String = "", calendar: BirthdayCalendar? = nil, month: Int = 1, day: Int = 1) {
        self.name = name; self.calendar = calendar; self.month = month; self.day = day
    }
    public func validate() throws {
        guard calendar != nil else { throw ShiriError.validation("请先选择公历或农历") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShiriError.validation("请填写称呼") }
        guard (1...12).contains(month), (1...(calendar == .lunar ? 30 : 31)).contains(day) else { throw ShiriError.validation("生日日期不正确") }
        if (calendar == .gregorian && month == 2 && day >= 29) || (calendar == .lunar && day == 30) {
            guard missingDatePolicy != .unspecified else { throw ShiriError.validation("有些年份或月份没有这一天，请选择处理方式") }
        }
        if calendar == .lunar && isLeapMonth && leapMonthPolicy == .unspecified { throw ShiriError.validation("请选择没有对应闰月时如何提醒") }
        if calendar == .gregorian && [4,6,9,11].contains(month) && day == 31 { throw ShiriError.validation("这个公历月份没有 31 日") }
        if calendar == .gregorian && month == 2 && day > 29 { throw ShiriError.validation("公历二月没有这一天") }
        if let birthYear, !(1900...2200).contains(birthYear) { throw ShiriError.validation("出生年份不正确") }
        if let dayTime, !dayTime.isValid { throw ShiriError.validation("当天提醒时间不正确") }
        if !repeatsYearly && oneTimeDate == nil { throw ShiriError.validation("请选择仅提醒这一次的具体公历日期") }
        if !advanceDays.isEmpty && (advanceTime == nil || !advanceTime!.isValid) { throw ShiriError.validation("请选择提前提醒的具体时刻") }
        guard advanceDays.count <= 5, advanceDays.allSatisfy({ (1...365).contains($0) }) else { throw ShiriError.validation("提前提醒应在 1 至 365 天之间") }
    }
}

public enum PlaceTrigger: String, Codable, CaseIterable, Sendable {
    case enter, exit
    public var title: String { self == .enter ? "到达时" : "离开时" }
}

public enum AlreadyInsidePolicy: String, Codable, CaseIterable, Sendable {
    case ask, notifyNow, nextEntry
}

public struct PlaceRule: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var address: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var trigger: PlaceTrigger
    public var startAt: Date?
    public var endAt: Date?
    public var alreadyInsidePolicy: AlreadyInsidePolicy = .ask
    public var provider = "Apple MapKit"
    public var providerPlaceID: String?
    public init(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Double = 200, trigger: PlaceTrigger = .enter) {
        self.name = name; self.address = address; self.latitude = latitude; self.longitude = longitude
        self.radiusMeters = radiusMeters; self.trigger = trigger
    }
    public var geofenceKey: String { StableID.hash(String(format: "%.5f,%.5f,%.0f", latitude, longitude, radiusMeters)) }
    public func validate() throws {
        guard !name.isEmpty, latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude),
              (-180...180).contains(longitude), (100...2_000).contains(radiusMeters) else { throw ShiriError.validation("请在地图上选择有效地点与范围") }
        if let startAt, let endAt, endAt < startAt { throw ShiriError.validation("地点提醒结束时间不能早于开始时间") }
    }
}

extension DateInterval {
    public func containsHalfOpen(_ date: Date) -> Bool { date >= start && date < end }
}
