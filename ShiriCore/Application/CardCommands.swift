import Foundation
import CoreData

public final class CardCommands: Sendable {
    public let repository: ShiriRepository
    public init(repository: ShiriRepository) { self.repository = repository }
    public func save(_ draft: CardDraft, now: Date, resolvingHeads: [UUID]? = nil) async throws -> Card {
        let current = try await repository.library(cardID: draft.card.id)
        let old = current.cards.first { $0.id == draft.card.id }
        if old?.scope != nil, old?.scope != draft.card.scope { throw ShiriError.validation("请在 iCloud 设置中更改保存位置，以保留完整历史") }
        if current.conflicts[draft.card.id] != nil && resolvingHeads == nil { throw ShiriError.conflict("这张卡片在不同设备上被修改过，请先选择要保留的内容") }
        if let resolvingHeads {
            guard !resolvingHeads.isEmpty, Set(resolvingHeads) == Set(current.conflicts[draft.card.id]?.map(\.id) ?? []) else {
                throw ShiriError.conflict("可选内容已更新，请重新查看后选择。草稿仍然保留。")
            }
        } else if let old {
            guard draft.card.revisionID == old.revisionID else {
                throw ShiriError.conflict("卡片已更新，请重新打开后再编辑。草稿仍然保留。")
            }
        } else if draft.isEditing {
            throw ShiriError.conflict("原卡片已不存在，无法覆盖保存。草稿内容仍保留。")
        }
        var card = draft.card
        if let from = draft.editingFrom {
            guard let old, from.cardID == old.id, from.scheduleID == old.schedulingID else { throw ShiriError.conflict("重复规则已变化，请重新打开当前安排") }
            if let start = card.schedule?.start, let original = from.plannedAt,
               start.key < CivilDate(original, calendar: old.schedule?.calendar(fallback: .current) ?? .current).key {
                throw ShiriError.validation("新安排不能早于所选日期；如需提前，请单独修改这一次")
            }
        }
        card.revisionID = UUID()
        let parents = resolvingHeads ?? old.map { [$0.revisionID] } ?? []
        var feedbackToStop: [ImportLink] = []
        if let old, old.schedule != card.schedule || old.birthday != card.birthday {
            card.schedule?.id = UUID(); card.schedule?.version = (old.schedule?.version ?? 0) + 1
            // An independently edited imported schedule is no longer guaranteed to match the source series.
            feedbackToStop = current.importLinks.filter { $0.cardID == card.id && $0.feedbackConsent && $0.extent == .entireRule }
        }
        let result = try await repository.save(card, attachments: draft.attachments, parents: parents, now: now, stoppingFeedback: feedbackToStop, expectedRevisionIDs: parents)
        try await repository.setDeviceValue(result, key: "confirmed/\(result.id)")
        try await repository.deleteDeviceRecord(entity: "DraftRecord", id: draft.id)
        return result
    }
    public func complete(_ occurrence: Occurrence, operationID: UUID = UUID(), now: Date) async throws {
        try await repository.recordEvent(occurrence: occurrence, kind: .completed, operationID: operationID, now: now)
    }
    /// System surfaces retain an occurrence ID, which must still resolve to this card's schedule.
    public func complete(cardID: UUID, occurrenceID: String, now: Date, calendar: Calendar) async throws {
        let library = try await repository.library(cardID: cardID)
        guard let card = library.cards.first(where: { $0.id == cardID }), card.canComplete else { throw ShiriError.notFound }
        let engine = OccurrenceEngine(calendar: calendar)
        let relevant = engine.relevantOccurrence(for: card, at: now, overrides: library.overrides)
        let occurrence: Occurrence?
        if relevant?.id == occurrenceID { occurrence = relevant }
        else {
            let candidates = engine.occurrences(for: card, in: DateInterval(start: now.addingTimeInterval(-32*86400), end: now.addingTimeInterval(2*366*86400)), overrides: library.overrides)
            occurrence = candidates.first { $0.id == occurrenceID }
                ?? library.occurrences.first { $0.id == occurrenceID && $0.cardID == cardID }
        }
        guard let occurrence else { throw ShiriError.validation("这一次安排已变更，请打开拾日查看") }
        try await complete(occurrence, now: now)
    }
    public func undo(_ occurrence: Occurrence, operationID: UUID = UUID(), now: Date) async throws {
        try await repository.recordEvent(occurrence: occurrence, kind: .reopened, operationID: operationID, now: now)
    }
    public func skip(_ occurrence: Occurrence, now: Date) async throws {
        try await repository.recordEvent(occurrence: occurrence, kind: .skipped, operationID: UUID(), now: now)
    }
    public func unskip(_ occurrence: Occurrence, now: Date) async throws {
        try await repository.recordEvent(occurrence: occurrence, kind: .unskipped, operationID: UUID(), now: now)
    }
    public func closeSeries(card: Card, now: Date) async throws {
        guard var current = try await repository.library().cards.first(where: { $0.id == card.id }), current.lifecycle == .active, current.isRepeating else { throw ShiriError.validation("这张卡片没有正在重复的规则") }
        guard current.recurrenceClosedAt == nil else { return }
        current.recurrenceClosedAt = now
        _ = try await save(CardDraft(card: current, isEditing: true), now: now)
    }
    public func setLifecycle(card: Card, lifecycle: CardLifecycle, now: Date) async throws {
        var copy = card; copy.lifecycle = lifecycle; copy.deletedAt = lifecycle == .deleted ? now : nil
        _ = try await save(CardDraft(card: copy, isEditing: true), now: now)
    }
    public func snooze(_ occurrence: Occurrence, until: Date, now: Date) async throws {
        guard until > now else { throw ShiriError.validation("稍后提醒时间应晚于现在") }
        let library = try await repository.library()
        guard let card = library.cards.first(where: { $0.id == occurrence.cardID }), card.lifecycle == .active,
              card.schedulingID == occurrence.scheduleID, card.recurrenceClosedAt == nil else { throw ShiriError.validation("这一次的安排已变化，请打开卡片查看当前日程") }
        guard EventReducer.state(events: library.events(for: occurrence.id)) == .pending else { throw ShiriError.validation("这一次已经结束，不会重新开启提醒") }
        var state = PersonalReminderState(occurrenceID: occurrence.id, now: now); state.snoozedUntil = until; state.snoozedOccurrence = occurrence
        try await repository.savePersonalState(state, event: PersonalReminderEvent(operationID: UUID(), occurrenceID: occurrence.id, kind: .snoozed, now: now, until: until))
    }
    public func stopReminder(_ occurrence: Occurrence, now: Date, alarmOnly: Bool = false) async throws {
        let library = try await repository.library()
        guard let card = library.cards.first(where: { $0.id == occurrence.cardID }), card.lifecycle == .active,
              card.schedulingID == occurrence.scheduleID, card.recurrenceClosedAt == nil,
              EventReducer.state(events: library.events(for: occurrence.id)) == .pending else {
            throw ShiriError.validation("这一次已结束或安排已变化")
        }
        var state = PersonalReminderState(occurrenceID: occurrence.id, now: now)
        state.isStopped = true
        try await repository.savePersonalState(state, event: PersonalReminderEvent(operationID: UUID(), occurrenceID: occurrence.id, kind: alarmOnly ? .alarmStopped : .stopped, now: now))
    }
    public func rescheduleOccurrence(_ occurrence: Occurrence, to date: Date, now: Date) async throws {
        let library = try await repository.library()
        guard let card = library.cards.first(where: { $0.id == occurrence.cardID }), card.lifecycle == .active,
              card.schedulingID == occurrence.scheduleID, card.recurrenceClosedAt == nil,
              EventReducer.state(events: library.events(for: occurrence.id)) == .pending else {
            throw ShiriError.validation("这一次已结束或规则已变化，不能修改旧安排")
        }
        try await repository.saveOverride(OccurrenceOverride(occurrenceID: occurrence.id, cardID: occurrence.cardID, kind: .rescheduled, newDate: date, now: now, original: occurrence))
        try await repository.savePersonalState(PersonalReminderState(occurrenceID: occurrence.id, now: now), event: PersonalReminderEvent(operationID: UUID(), occurrenceID: occurrence.id, kind: .resumed, now: now))
    }
    public func resumeReminder(_ occurrence: Occurrence, now: Date) async throws {
        let library = try await repository.library()
        guard let card = library.cards.first(where: { $0.id == occurrence.cardID }), card.lifecycle == .active,
              card.schedulingID == occurrence.scheduleID, card.recurrenceClosedAt == nil,
              EventReducer.state(events: library.events(for: occurrence.id)) == .pending else { throw ShiriError.validation("这一次已结束，不能重新开启提醒") }
        try await repository.savePersonalState(PersonalReminderState(occurrenceID: occurrence.id, now: now), event: PersonalReminderEvent(operationID: UUID(), occurrenceID: occurrence.id, kind: .resumed, now: now))
    }
    public func importPackage(_ package: SharePackage, draft: CardDraft, allowsDuplicate: Bool, feedbackConsent: Bool, now: Date) async throws -> Card {
        try package.validate()
        let library = try await repository.library()
        if !allowsDuplicate && library.importLinks.contains(where: { $0.sessionID == package.sessionID }) { throw ShiriError.conflict("这份日程已经添加过。可打开已有卡片，或明确选择再添加一份。") }
        guard draft.card.id != package.snapshot.sourceCardID else { throw ShiriError.validation("接收日程必须创建独立副本") }
        var card = draft.card; card.revisionID = UUID()
        var link = ImportLink(cardID: card.id, package: package, feedbackConsent: feedbackConsent && package.feedbackURL != nil, now: now)
        link.feedbackAccountKey = repository.persistence.configuration.cloudAccountKey
        let result = try await repository.save(card, attachments: draft.attachments, parents: [], now: now, imported: link)
        if link.feedbackConsent {
            try await repository.enqueue(ReceiptEvent(operationID: link.id, sessionID: link.sessionID, semanticKey: link.sourceOccurrenceKey, kind: .added, now: now))
        }
        return result
    }
}

extension ShiriRepository {
    public func deviceValue<T: Decodable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
        let context = persistence.context(author: actorID)
        return try await context.perform { try DatabaseCodec.values(type, entity: "DeviceValueRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id == %@", key)).first }
    }
    public func setDeviceValue<T: Encodable>(_ value: T, key: String) async throws {
        try await transaction { context in try DatabaseCodec.put(value, entity: "DeviceValueRecord", id: key, context: context, store: self.deviceStore) }
    }
    public func saveDraft(_ draft: CardDraft) async throws {
        try await transaction { context in try DatabaseCodec.put(draft, entity: "DraftRecord", id: draft.id, context: context, store: self.deviceStore) }
    }
    public func drafts() async throws -> [CardDraft] {
        let context = persistence.context(author: actorID)
        return try await context.perform { try DatabaseCodec.values(CardDraft.self, entity: "DraftRecord", context: context, stores: [self.deviceStore]).sorted { $0.updatedAt > $1.updatedAt } }
    }
    public func deleteDeviceRecord(entity: String, id: Any) async throws {
        guard ["DraftRecord", "ReceiptOutboxRecord", "DeviceValueRecord", "MigrationJournalRecord"].contains(entity) else { throw ShiriError.validation("不允许删除此记录") }
        try await transaction { context in
            for row in try DatabaseCodec.fetch(entity, context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id == %@", argumentArray: [id])) { context.delete(row) }
        }
    }
    public func savePersonalState(_ state: PersonalReminderState, event: PersonalReminderEvent) async throws {
        try await transaction { context in
            try DatabaseCodec.put(state, entity: "DeviceValueRecord", id: "reminder/\(state.occurrenceID)", context: context, store: self.deviceStore)
            try DatabaseCodec.put(event, entity: "PersonalEventRecord", id: event.id, context: context, store: self.deviceStore, fields: ["occurrenceID":event.occurrenceID])
        }
    }
    public func recordEvent(occurrence: Occurrence, kind: TaskEventKind, operationID: UUID, now: Date) async throws {
        let library = try await self.library()
        guard let card = library.cards.first(where: { $0.id == occurrence.cardID }), card.canComplete else { throw ShiriError.validation("这张卡片不能标记完成") }
        guard occurrence.scheduleID == card.schedulingID || library.occurrences.contains(where: { $0.id == occurrence.id }) else { throw ShiriError.validation("这条旧提醒的安排已变更，请打开卡片查看当前日程") }
        let store = try persistence.store(for: card.scope)
        let produced: TaskEvent? = try await transaction { context in
            let existing = try DatabaseCodec.values(TaskEvent.self, entity: "TaskEventRecord", context: context, stores: [store], predicate: NSPredicate(format: "occurrenceID == %@", occurrence.id))
            if existing.contains(where: { $0.operationID == operationID }) { return nil }
            let active = EventReducer.effectiveCompletions(existing)
            if kind == .completed && !active.isEmpty { return nil }
            if kind == .reopened && active.isEmpty { return nil }
            let reverses = kind == .reopened ? active.map(\.id) : (kind == .unskipped ? existing.filter { $0.kind == .skipped }.map(\.id) : [])
            let event = TaskEvent(operationID: operationID, occurrence: occurrence, actorID: self.actorID, kind: kind, now: now, reverses: reverses)
            try DatabaseCodec.put(occurrence, entity: "OccurrenceRecord", id: occurrence.id, context: context, store: store, fields: ["cardID":card.id, "plannedAt":occurrence.plannedAt])
            try DatabaseCodec.put(event, entity: "TaskEventRecord", id: event.id, context: context, store: store, fields: ["cardID":card.id, "occurrenceID":occurrence.id, "operationID":operationID, "happenedAt":now, "kind":kind.rawValue])
            return event
        }
        if let event = produced, [.completed, .reopened].contains(kind) {
            for link in library.importLinks where link.cardID == card.id && link.feedbackConsent && link.feedbackAvailable {
                let key = link.extent == .currentOccurrence ? link.sourceOccurrenceKey : occurrence.semanticKey
                try await enqueue(ReceiptReducer.receipt(for: event, link: link, semanticKey: key, events: library.events))
            }
        }
    }
    public func saveOverride(_ override: OccurrenceOverride) async throws {
        guard let card = try await library().cards.first(where: { $0.id == override.cardID }) else { throw ShiriError.notFound }
        let store = try persistence.store(for: card.scope)
        try await transaction { context in try DatabaseCodec.put(override, entity: "OccurrenceOverrideRecord", id: override.id, context: context, store: store, fields: ["cardID":card.id]) }
    }
    public func enqueue(_ receipt: ReceiptEvent) async throws {
        try await transaction { context in
            guard try DatabaseCodec.fetch("ReceiptOutboxRecord", context: context, stores: [self.deviceStore], predicate: NSPredicate(format: "id == %@", receipt.id as NSUUID)).isEmpty else { return }
            try DatabaseCodec.put(ReceiptOutboxItem(receipt: receipt), entity: "ReceiptOutboxRecord", id: receipt.id, context: context, store: self.deviceStore, fields: ["sessionID":receipt.sessionID])
        }
    }
    public func updateOutbox(_ item: ReceiptOutboxItem) async throws {
        try await transaction { context in try DatabaseCodec.put(item, entity: "ReceiptOutboxRecord", id: item.id, context: context, store: self.deviceStore, fields: ["sessionID":item.receipt.sessionID]) }
    }
    public func outbox() async throws -> [ReceiptOutboxItem] {
        let context = persistence.context(author: actorID)
        return try await context.perform { try DatabaseCodec.values(ReceiptOutboxItem.self, entity: "ReceiptOutboxRecord", context: context, stores: [self.deviceStore]) }
    }
    public func stopFeedback(link: ImportLink, now: Date) async throws {
        guard let card = try await library().cards.first(where: { $0.id == link.cardID }) else { return }
        guard link.feedbackConsent else { return }
        var updated = link; updated.feedbackConsent = false
        let store = try persistence.store(for: card.scope)
        try await transaction { context in
            try self.writeStoppedFeedback(updated, now: now, context: context, store: store)
        }
    }
    func writeStoppedFeedback(_ link: ImportLink, now: Date, context: NSManagedObjectContext, store: NSPersistentStore) throws {
        var updated = link; updated.feedbackConsent = false
        try DatabaseCodec.put(updated, entity: "ImportLinkRecord", id: updated.id, context: context, store: store, fields: ["cardID":link.cardID, "sessionID":link.sessionID])
        for row in try DatabaseCodec.fetch("ReceiptOutboxRecord", context: context, stores: [deviceStore], predicate: NSPredicate(format: "sessionID == %@", link.sessionID as NSUUID)) { context.delete(row) }
        let stopped = ReceiptOutboxItem(receipt: ReceiptEvent(operationID: UUID(), sessionID: link.sessionID, semanticKey: link.sourceOccurrenceKey, kind: .feedbackStopped, now: now))
        try DatabaseCodec.put(stopped, entity: "ReceiptOutboxRecord", id: stopped.id, context: context, store: deviceStore, fields: ["sessionID":link.sessionID])
    }
}
