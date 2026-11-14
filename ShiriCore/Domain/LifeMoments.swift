import Foundation
import CoreData

public struct OccasionLink: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var date: CivilDate
    public var templateID: String?
    public init(cardID: UUID, date: CivilDate, templateID: String? = nil) {
        self.cardID = cardID; self.date = date; self.templateID = templateID
    }
}

public struct PreparationChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var daysBefore: Int
    public var time: DayTime
    public var reminds: Bool
    public init(id: String, title: String, daysBefore: Int, time: DayTime = DayTime(hour: 9), reminds: Bool = false) {
        self.id = id; self.title = title; self.daysBefore = daysBefore; self.time = time; self.reminds = reminds
    }
    public static func suggestions(anniversary: Bool) -> [Self] {
        [
            Self(id: "gift", title: anniversary ? "准备一份心意" : "选一份生日礼物", daysBefore: 7),
            Self(id: "meal", title: "安排一顿饭", daysBefore: 3),
            Self(id: "contact", title: anniversary ? "一起庆祝" : "送上生日祝福", daysBefore: 0)
        ]
    }
}

public enum OccasionPlanner {
    public static func nextDate(for card: Card, now: Date, calendar: Calendar) -> Date? {
        guard let rule = card.birthday, card.recurrenceClosedAt == nil else { return nil }
        return BirthdayCalendarEngine(calendar: calendar).nextDates(for: rule, after: calendar.startOfDay(for: now).addingTimeInterval(-1)).first
    }
    public static func preparationID(parent: UUID, date: CivilDate, template: String) -> UUID {
        StableID.uuid("preparation|\(parent)|\(date.key)|\(template)")
    }
    public static func drafts(for parent: Card, date: CivilDate, choices: [PreparationChoice], now: Date, calendar: Calendar) throws -> [CardDraft] {
        guard parent.birthday != nil, parent.recurrenceClosedAt == nil, parent.lifecycle == .active, !choices.isEmpty,
              Set(choices.map(\.id)).count == choices.count,
              let anchor = OccurrenceEngine(calendar: calendar).date(date, time: DayTime(hour: 0)) else {
            throw ShiriError.validation("请选择重要日子和要准备的事项")
        }
        return try choices.map { choice in
            guard (0...365).contains(choice.daysBefore), !choice.id.isEmpty,
                  let day = calendar.date(byAdding: .day, value: -choice.daysBefore, to: anchor),
                  let target = OccurrenceEngine(calendar: calendar).date(CivilDate(day, calendar: calendar), time: choice.time) else {
                throw ShiriError.validation("请检查准备事项的日期和时间")
            }
            guard target > now else { throw ShiriError.validation("“\(choice.title)”的准备时间已过去，请调整提前天数或时间") }
            var card = Card(id: preparationID(parent: parent.id, date: date, template: choice.id), title: choice.title, now: now)
            card.category = "重要日子"; card.note = "为“\(parent.title)”做准备"
            card.schedule = ScheduleDefinition(start: CivilDate(target, calendar: calendar), time: choice.time, timeZone: calendar.timeZone)
            card.reminders.isEnabled = choice.reminds
            card.occasionLink = OccasionLink(cardID: parent.id, date: date, templateID: choice.id)
            card.appearance = .recommended(for: choice.title, kind: .task)
            return CardDraft(card: try card.validated())
        }
    }
}

extension ShiriRepository {
    /// Create the explicitly selected one-off preparations together. A retry cannot create duplicates.
    public func createPreparations(parentID: UUID, revisionID: UUID, date: CivilDate, choices: [PreparationChoice], now: Date, calendar: Calendar) async throws -> [Card] {
        try await transaction { context in
            let library = try self.library(in: context)
            guard let parent = library.cards.first(where: { $0.id == parentID }), parent.revisionID == revisionID,
                  library.conflicts[parentID] == nil, parent.lifecycle == .active else {
                throw ShiriError.conflict("这个日子已变化，请重新打开后确认准备安排")
            }
            guard let next = OccasionPlanner.nextDate(for: parent, now: now, calendar: calendar),
                  CivilDate(next, calendar: calendar) == date else {
                throw ShiriError.conflict("准备日期已变化，请重新确认")
            }
            let drafts = try OccasionPlanner.drafts(for: parent, date: date, choices: choices, now: now, calendar: calendar)
            let store = try self.persistence.store(for: .local)
            for draft in drafts {
                guard !library.cards.contains(where: { $0.id == draft.card.id }) else {
                    throw ShiriError.conflict("部分准备事项已经添加过，请查看已有记录")
                }
            }
            for draft in drafts {
                let card = draft.card
                try DatabaseCodec.write(card, context: context, store: store)
                let revision = CardRevision(card: card, parents: [], actorID: self.actorID, now: now)
                try DatabaseCodec.put(revision, entity: "CardRevisionRecord", id: revision.id, context: context, store: store, fields: ["cardID": card.id])
                if let schedule = card.schedule { try DatabaseCodec.put(schedule, entity: "ScheduleVersionRecord", id: schedule.id, context: context, store: store, fields: ["cardID": card.id]) }
            }
            return drafts.map(\.card)
        }
    }
}

public enum MemoryCollection {
    public static func cards(in library: LibrarySnapshot, interval: DateInterval? = nil, occasionID: UUID? = nil) -> [Card] {
        library.cards.filter { card in
            guard card.lifecycle != .deleted, let date = card.memoryDate else { return false }
            return (interval?.containsHalfOpen(date) ?? true) && (occasionID == nil || card.occasionLink?.cardID == occasionID || card.id == occasionID)
        }.sorted {
            if $0.memoryDate != $1.memoryDate { return ($0.memoryDate ?? .distantPast) > ($1.memoryDate ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
