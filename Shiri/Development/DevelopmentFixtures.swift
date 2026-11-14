#if DEBUG
import Foundation
import UIKit
@preconcurrency import CoreData
import ShiriCore

/// Explicit UI-test fixtures, written only into a uniquely identified test store.
@MainActor
enum DevelopmentFixtures {
    static var sharingSessions: [ShareSession] = []
    static var receipts: [UUID: [ReceiptEvent]] = [:]
    static func prepare(model: AppModel) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting"), let id = ProcessInfo.processInfo.environment["NIANYI_TEST_STORE_ID"], UUID(uuidString: id) != nil,
              ProcessInfo.processInfo.environment["NIANYI_FIXTURE"] == "warm-paper", let repository = model.repository, let commands = model.commands else { return }
        if ProcessInfo.processInfo.environment["NIANYI_SCENARIO"] == "memory-upgrade" {
            try await prepareMemoryExperience(model: model, repository: repository)
            return
        }
        if ProcessInfo.processInfo.environment["NIANYI_SCENARIO"] == "performance-standard" {
            if try await repository.searchCardIDs("", limit: 1).isEmpty { try await seedStandardPerformance(repository: repository, now: model.now, calendar: model.calendar) }
            model.selectedTab = .cards
            return
        }
        if ProcessInfo.processInfo.environment["NIANYI_SCENARIO"] == "performance" {
            try await preparePerformance(model: model, repository: repository)
            return
        }
        if let scenario = ProcessInfo.processInfo.environment["NIANYI_SCENARIO"] {
            try await prepareScenario(scenario, model: model)
            return
        }
        let now = model.now, calendar = model.calendar
        let today = calendar.startOfDay(for: now)
        func date(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        if try await repository.library().cards.isEmpty {
            let specs: [(String, String, CardKind, CardTheme, CardIllustration, Date?)] = [
                ("给妈妈打个电话", "聊聊这个星期的新鲜事", .task, .butter, .telephone, date(0,21)),
                ("去花店取花", "周六，给家里添一点颜色\n取一束白色洋桔梗，回家前记得带上花瓶。", .task, .sage, .ginkgo, date(1,10)),
                ("整理旅行照片", "慢慢选出最喜欢的那些", .task, .butter, .photos, nil),
                ("想找个周末，去海边走走", "把这个念头先留下", .note, .paper, .seaside, nil)
            ]
            for (index,spec) in specs.enumerated() {
                let (title,note,kind,theme,illustration,planned) = spec
                let updated = now.addingTimeInterval(Double(index == 0 ? -300 : -index * 15))
                var card = Card(title: title,kind: kind,now: updated); card.note = note
                card.appearance.theme = theme; card.appearance.illustration = illustration
                if let planned { card.schedule = ScheduleDefinition(start: CivilDate(planned,calendar: calendar),time: DayTime(hour: calendar.component(.hour,from: planned))); card.reminders.isEnabled = true }
                _ = try await commands.save(CardDraft(card: card),now: updated)
            }
            let counts = [(-4,2),(-3,1),(-2,3),(-1,1),(0,1)]
            for (offset,count) in counts {
                for index in 0..<count {
                    let doneAt = date(offset, offset == 0 ? 18 : (offset == -1 ? 19 : 10+index), offset == 0 ? 30 : (offset == -1 ? 10 : 0))
                    let title = offset == 0 ? "把阳台收拾干净" : offset == -1 ? "给绿植浇水" : ["整理书桌","去公园散步","给家人寄照片"][index]
                    var card = Card(title: title,now: doneAt); card.schedule = ScheduleDefinition(start: CivilDate(doneAt,calendar: calendar),time: DayTime(hour: 9))
                    let saved = try await commands.save(CardDraft(card: card),now: doneAt)
                    let occurrence = OccurrenceEngine(calendar: calendar).next(for: saved,after: calendar.startOfDay(for: doneAt))!
                    try await commands.complete(occurrence,now: doneAt)
                }
            }
            for index in 0..<6 {
                let doneAt = date(-7,10+index)
                var card = Card(title: "上周的小事 \(index+1)",now: doneAt); card.schedule = ScheduleDefinition(start: CivilDate(doneAt,calendar: calendar),time: DayTime(hour: 9))
                let saved = try await commands.save(CardDraft(card: card),now: doneAt)
                try await commands.complete(OccurrenceEngine(calendar: calendar).next(for: saved,after: calendar.startOfDay(for: doneAt))!,now: doneAt)
            }
            var birthday = Card(title: "妈妈的生日",kind: .note,now: now.addingTimeInterval(-600))
            birthday.birthday = BirthdayRule(name: "妈妈",calendar: .gregorian,month: 10,day: 18)
            birthday.birthday?.dayTime = DayTime(hour: 9); birthday.birthday?.advanceDays = [3]; birthday.birthday?.advanceTime = DayTime(hour: 9)
            birthday.reminders.isEnabled = true; birthday.appearance = .recommended(for: birthday.title,kind: .note,birthday: true)
            _ = try await commands.save(CardDraft(card: birthday),now: now.addingTimeInterval(-600))
            for (index,title) in ["周六去看展", "领取演出票"].enumerated() {
                var card = Card(title: title,now: now); let planned = index == 0 ? date(1,14) : date(-1,18)
                card.schedule = ScheduleDefinition(start: CivilDate(planned,calendar: calendar),time: DayTime(hour: index == 0 ? 14 : 18))
                card.appearance.theme = index == 0 ? .butter : .sage; card.appearance.illustration = index == 0 ? .tickets : .concert
                let snapshot = SharedCardSnapshot(card: card,attachments: [],occurrence: nil,extent: .entireRule,includeNote: true,includePhotos: false)
                var session = ShareSession(snapshot: snapshot,recipientLabel: index == 0 ? "林小满" : "陈可",feedback: true,now: now.addingTimeInterval(Double(-index*60)))
                session.status = .accepted
                try await repository.saveLocalShareSession(session)
                sharingSessions.append(session)
            }
            try await repository.setDeviceValue(sharingSessions, key: "visual-test-sharing-sessions")
            if ProcessInfo.processInfo.environment["NIANYI_LONG_TEXT"] == "1", var card = try await repository.library().cards.first(where: { $0.title == "给妈妈打个电话" }) {
                card.title = "回家后给妈妈打个电话，听她说说最近的生活，也告诉她这个周末的安排"; card.note = String(repeating: "把想说的话慢慢讲清楚。",count: 10)
                _ = try await commands.save(CardDraft(card: card,isEditing: true),now: now)
            }
        }
        // Receipt data feeds the same native view as cloud receipts, without contacting shared services.
        sharingSessions = try await repository.deviceValue([ShareSession].self, key: "visual-test-sharing-sessions") ?? []
        for session in sharingSessions {
            receipts[session.id] = [ReceiptEvent(operationID: UUID(),sessionID: session.id,semanticKey: nil,kind: session.recipientLabel == "陈可" ? .completed : .added,now: session.recipientLabel == "陈可" ? date(-1,17,42) : date(0,9))]
        }
        if ProcessInfo.processInfo.environment["NIANYI_DARK"] == "1" { model.preferences.colorScheme = .dark }
        let snapshot = try await repository.library(); model.library = snapshot; model.projections = AppModel.project(snapshot,now: model.now,calendar: model.calendar)
        switch ProcessInfo.processInfo.environment["NIANYI_PAGE"] ?? "today" {
        case "cards": model.selectedTab = .cards
        case "review": model.selectedTab = .review
        case "sharing": model.selectedTab = .sharing
        case "detail": model.selectedCard = snapshot.cards.first { $0.title == "去花店取花" }
        case "composer":
            var draft = try ChineseCardParser(calendar: model.calendar).interpret("明天下午三点提醒我去取快递",now: model.now).first!
            draft.card.title = "去取快递"; draft.originalText = "明天下午三点，\n提醒我去取快递"
            draft.interpretedText = draft.originalText; model.composer = draft
        case "birthday":
            model.startsBirthdayEditor = true; model.composer = CardDraft(card: snapshot.cards.first { $0.birthday != nil }!,isEditing: true)
        case "place", "appearance", "media", "reminders", "speech":
            model.startsEditor = ProcessInfo.processInfo.environment["NIANYI_PAGE"]
            model.composer = CardDraft(card: snapshot.cards.first { $0.kind == .task }!,isEditing: true)
        case "receive":
            var card = Card(title: "周六去看展",now: now)
            card.schedule = ScheduleDefinition(start: CivilDate(date(1,14),calendar: calendar),time: DayTime(hour: 14))
            card.note = "城市美术馆"; card.appearance.illustration = .tickets
            model.importPackage = SharePackage(session: ShareSession(snapshot: SharedCardSnapshot(card: card,attachments: [],occurrence: nil,extent: .entireRule,includeNote: true,includePhotos: false),recipientLabel: "",feedback: false,now: now),senderLabel: "林小满")
        default: break
        }
    }

    /// The documented workload: 10k cards, 50k causal events, mixed schedules and 90% history.
    /// A private context writes bounded batches; no production store can select this fixture.
    static func seedStandardPerformance(repository: ShiriRepository, now: Date, calendar: Calendar) async throws {
        let context = repository.persistence.context(author: repository.actorID)
        let store = try repository.persistence.store(for: .local)
        try await context.perform {
            let created = now.addingTimeInterval(-40 * 86400)
            let engine = OccurrenceEngine(calendar: calendar)
            for index in 0..<10_000 {
                try autoreleasepool {
                    var card = Card(title: String(format: "生活事项 %04d", index), now: created)
                    card.note = index == 9876 ? "目标关键词 银杏雨" : "日常安排与处理历史"
                    if index % 4 != 1 {
                        card.schedule = ScheduleDefinition(start: CivilDate(index % 20 == 0 ? created : now, calendar: calendar), time: DayTime(hour: 21), frequency: index % 20 == 0 ? .daily : .never)
                    }
                    let occurrence = engine.relevantOccurrence(for: card, at: created)!
                    func encoded<T: Encodable>(_ value: T, entity: String, id: Any, cardID: UUID) throws {
                        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context); context.assign(row, to: store)
                        row.setValue(id, forKey: "id"); row.setValue(cardID, forKey: "cardID"); row.setValue(try ValueCodec.encode(value), forKey: "payload")
                    }
                    try encoded(occurrence, entity: "OccurrenceRecord", id: occurrence.id, cardID: card.id)
                    var previousCompletion: UUID?
                    for step in 0..<5 {
                        let kind: TaskEventKind = step % 2 == 0 ? .completed : .reopened
                        let event = TaskEvent(operationID: UUID(), occurrence: occurrence, actorID: "performance", kind: kind, now: created.addingTimeInterval(Double((step + 1) * 86400)), reverses: kind == .reopened ? [previousCompletion!] : [])
                        if kind == .completed { previousCompletion = event.id }
                        try encoded(event, entity: "TaskEventRecord", id: event.id, cardID: card.id)
                    }
                    if index >= 1000 { card.lifecycle = .archived }
                    let row = NSEntityDescription.insertNewObject(forEntityName: "CardRecord", into: context); context.assign(row, to: store)
                    for (key, value) in ["title": card.title, "note": card.note, "kind": card.kind.rawValue, "category": card.category, "importance": card.importance.rawValue, "lifecycle": card.lifecycle.rawValue, "scope": card.scope.rawValue] { row.setValue(value, forKey: key) }
                    row.setValue(card.id, forKey: "id"); row.setValue(card.revisionID, forKey: "revisionID")
                    row.setValue(created, forKey: "createdAt"); row.setValue(now.addingTimeInterval(Double(-index)), forKey: "updatedAt"); row.setValue(false, forKey: "isPinned")
                    if let schedule = card.schedule { row.setValue(try ValueCodec.encode(schedule), forKey: "schedule"); try encoded(schedule, entity: "ScheduleVersionRecord", id: schedule.id, cardID: card.id) }
                    card.updatedAt = now.addingTimeInterval(Double(-index))
                    let revision = CardRevision(card: card, parents: [], actorID: "performance", now: card.updatedAt)
                    try encoded(revision, entity: "CardRevisionRecord", id: revision.id, cardID: card.id)
                }
                if index % 500 == 499 { try context.save(); context.reset() }
            }
        }
    }

    // Persistent, local-only data. Seeding is excluded from performance measurements.
    private static func preparePerformance(model: AppModel, repository: ShiriRepository) async throws {
        let now = model.now, calendar = model.calendar
        if try await repository.library().cards.isEmpty {
            let source = UIImage(named: "TravelPhotos")?.jpegData(compressionQuality: 0.9)
            for index in 0..<1000 {
                let created = now.addingTimeInterval(Double(-index))
                var card = Card(title: String(format: "生活事项 %04d", index), kind: index % 4 == 3 ? .note : .task, now: created)
                card.note = "把生活里的小事收好。第 \(index) 张卡片，包含备注、分类和不同日期。"
                card.category = index % 2 == 0 ? "生活" : "旅行"
                card.appearance.theme = index % 2 == 0 ? .butter : .sage
                if card.kind == .task && index % 2 == 0 {
                    card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 21), frequency: index % 10 == 0 ? .daily : .never)
                }
                var photos: [Attachment] = []
                if index < 240 && index % 3 == 0, let source {
                    let photoSource: Data
                    if ProcessInfo.processInfo.environment["NIANYI_DISTINCT_PHOTOS"] == "1" {
                        photoSource = autoreleasepool {
                            let names = ["TravelPhotos", "Seaside", "ReviewFlowers", "DeskCalendar", "PaperNotebook", "QuietTea"]
                            let format = UIGraphicsImageRendererFormat(); format.scale = 1
                            let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { context in
                                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
                                UIImage(named: names[(index / 3) % names.count])?.draw(in: CGRect(x: 0, y: 0, width: 1600, height: 1200))
                                ("独立照片样本 \(index)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black])
                            }
                            return image.jpegData(compressionQuality: 0.9) ?? source
                        }
                    } else { photoSource = source }
                    photos = [try PhotoProcessor.prepare(photoSource, cardID: card.id, index: 0)]
                    card.attachmentIDs = photos.map(\.id); card.appearance.backgroundAttachmentID = photos[0].id
                }
                _ = try await repository.save(card, attachments: photos, parents: [], now: created)
            }
        }
        model.selectedTab = ProcessInfo.processInfo.environment["NIANYI_PAGE"] == "today" ? .today : .cards
    }

    private static func prepareMemoryExperience(model: AppModel, repository: ShiriRepository) async throws {
        let now = model.now, calendar = model.calendar, commands = CardCommands(repository: repository)
        if try await repository.deviceValue(Bool.self, key: "memory-experience-seeded") != true {
            let specs: [(Int, String, String, String, [String])] = [
                (-365, "和妈妈一起吃生日面", "她说，平平安安就是最好的一年。\n回家的路上，晚风刚刚好。", "家人", ["ReviewFlowers"]),
                (-2, "周末的海边，风很轻", "走了一条从未走过的小路，看到了日落。\n想把这种慢下来的感觉记住。", "旅行", ["Seaside", "TravelPhotos", "ExhibitionTickets"]),
                (-34, "给未来的自己", "不必急着得到所有答案，认真过好今天。", "成长", []),
                (-90, "山间的六个片刻", String(repeating: "那天沿着山路往前走，树影落在身上。", count: 45) + "回忆正文最后一句", "旅行", ["Seaside", "TravelPhotos", "ReviewFlowers", "QuietTea", "PaperNotebook", "Ginkgo"])
            ]
            for (offset, title, note, theme, assets) in specs {
                var card = Card(title: title, kind: .note, now: now)
                card.memory = MemoryMetadata(); card.memoryDate = calendar.date(byAdding: .day, value: offset, to: now); card.note = note; card.category = theme
                var draft = CardDraft(card: card)
                for (index, asset) in assets.enumerated() {
                    guard let data = UIImage(named: asset)?.pngData() else { continue }
                    draft.attachments.append(try PhotoProcessor.prepare(data, cardID: card.id, index: index))
                }
                draft.card.attachmentIDs = draft.attachments.map(\.id)
                _ = try await commands.save(draft, now: now)
            }
            var task = Card(title: "一起去公园散步", now: now)
            task.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 9))
            _ = try await commands.save(CardDraft(card: task), now: now)
            try await repository.setDeviceValue(true, key: "memory-experience-seeded")
        }
        if ProcessInfo.processInfo.environment["NIANYI_DARK"] == "1" { model.preferences.colorScheme = .dark }
        model.selectedTab = .review
    }

    private static func prepareScenario(_ scenario: String, model: AppModel) async throws {
        guard ["empty", "completed", "notes", "mixed", "sharing-states", "unavailable", "invalid-file", "product-flow", "card-density", "experience-upgrade", "five-issues"].contains(scenario), let repository = model.repository, let commands = model.commands else {
            throw ShiriError.validation("Unknown isolated UI scenario")
        }
        sharingSessions = []; receipts = [:]
        let now = model.now, calendar = model.calendar
        if try await repository.deviceValue(Bool.self, key: "state-scenario-seeded") != true {
            if scenario == "five-issues" {
                for (offset, title) in [(0, "今天待办取快递"), (-7, "上周二去书店"), (7, "下周二去公园")] {
                    let day = calendar.date(byAdding: .day, value: offset, to: now)!
                    var card = Card(title: title, now: now.addingTimeInterval(-120))
                    card.schedule = ScheduleDefinition(start: CivilDate(day, calendar: calendar), time: DayTime(hour: 15))
                    _ = try await commands.save(CardDraft(card: card), now: now.addingTimeInterval(-120))
                }
                var finished = Card(title: "今天已完成并固定", now: now); finished.isPinned = true
                finished.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 8))
                let saved = try await commands.save(CardDraft(card: finished), now: now)
                let occurrence = OccurrenceEngine(calendar: calendar).relevantOccurrence(for: saved, at: now)!
                try await commands.complete(occurrence, now: now)
                var note = Card(title: "今天的随手记", kind: .note, now: now); note.note = "这条记录不会计入完成数。"
                _ = try await commands.save(CardDraft(card: note), now: now)
            }
            if scenario == "card-density" || scenario == "experience-upgrade" {
                var short = Card(title: "散步", now: now); short.isPinned = true
                var note = Card(title: "给未来的自己", kind: .note, now: now)
                note.note = "把值得记住的小事留下。\n走过的路、认真做过的选择，都值得被看见。"; note.appearance.theme = .paper; note.appearance.illustration = .none
                var repeating = Card(title: "每周整理一次照片", now: now)
                repeating.category = "个人"; repeating.importance = .important
                repeating.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 21), frequency: .weekly)
                repeating.schedule?.weekdays = [calendar.component(.weekday, from: now)]
                var long = Card(title: "准备周末的短途旅行，把车票、住处和行李逐一确认，给自己留一点从容出发的时间", now: now)
                long.note = "出发前确认车票和入住时间。\n随身带好证件、充电器和雨伞。\n最后检查门窗，轻装出发。"; long.importance = .critical; long.category = "旅行"
                var dark = Card(title: "深色纸张上的一句提醒", now: now); dark.appearance.customHex = "29332E"; dark.note = "留一点安静的时间给自己。"
                var birthday = Card(title: "妈妈的生日", kind: .note, now: now)
                birthday.birthday = BirthdayRule(name: "妈妈", calendar: .gregorian, month: 10, day: 18); birthday.birthday?.dayTime = DayTime(hour: 9)
                birthday.appearance = .recommended(for: birthday.title, kind: .note, birthday: true)
                for (index, card) in [short, note, repeating, long, dark, birthday].enumerated() {
                    _ = try await commands.save(CardDraft(card: card), now: now.addingTimeInterval(Double(-index)))
                }
                if let data = UIImage(named: "TravelPhotos")?.pngData() {
                    var card = Card(title: "这次旅行的三个瞬间", kind: .note, now: now); card.category = "旅行"
                    card.note = "把喜欢的画面放在一起。"
                    let images = try (0..<3).map { try PhotoProcessor.prepare(data, cardID: card.id, index: $0) }
                    card.attachmentIDs = images.map(\.id); card.appearance.backgroundAttachmentID = images.first?.id
                    var draft = CardDraft(card: card); draft.attachments = images
                    _ = try await commands.save(draft, now: now.addingTimeInterval(-7))
                }
            }
            if scenario == "experience-upgrade" {
                for (offset, title) in ["晚上散步", "明天整理相册", "后天去公园"].enumerated() {
                    var task = Card(title: title, now: now)
                    task.schedule = ScheduleDefinition(start: CivilDate(calendar.date(byAdding: .day, value: offset, to: now)!, calendar: calendar), time: DayTime(hour: 21))
                    _ = try await commands.save(CardDraft(card: task), now: now)
                }
                for title in ["周末公园里的晚霞", "晚饭后的一句话"] {
                    var note = Card(title: title, kind: .note, now: now); note.note = "和喜欢的人在一起，普通的一天也值得记住。"
                    _ = try await commands.save(CardDraft(card: note), now: now)
                }
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 700))
                let image = renderer.image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.black]
                    ("预约名称：去看展\n2026-10-20 15:00\n地点：城市美术馆" as NSString).draw(in: CGRect(x: 60, y: 70, width: 880, height: 500), withAttributes: attributes)
                }
                var card = Card(title: "待识别截图", now: now)
                let photo = try PhotoProcessor.prepare(image.pngData()!, cardID: card.id, index: 0)
                card.attachmentIDs = [photo.id]
                var draft = CardDraft(card: card); draft.attachments = [photo]
                _ = try await commands.save(draft, now: now)
            }
            if scenario == "product-flow" {
                func date(_ day: Int, _ hour: Int) -> Date {
                    calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
                }
                var repeatCard = Card(title: "每天读十页书", now: now)
                repeatCard.schedule = ScheduleDefinition(start: CivilDate(date(1,9), calendar: calendar), time: DayTime(hour: 9), frequency: .daily)
                var deadline = Card(title: "提交旅行材料", now: now)
                deadline.schedule = ScheduleDefinition(start: CivilDate(date(12,15), calendar: calendar), time: DayTime(hour: 15))
                deadline.schedule?.dueAt = date(14,18); deadline.reminders.isEnabled = true
                var archived = Card(title: "归档的取件安排", now: now)
                archived.schedule = ScheduleDefinition(start: CivilDate(date(13,10), calendar: calendar), time: DayTime(hour: 10))
                archived.reminders.isEnabled = true; archived.lifecycle = .archived
                var past = Card(title: "过去的一次提醒", now: now)
                past.schedule = ScheduleDefinition(start: CivilDate(date(10,9), calendar: calendar), time: DayTime(hour: 9))
                past.reminders.isEnabled = true; past.lifecycle = .deleted; past.deletedAt = now
                var note = Card(title: "替换前保留的内容", kind: .note, now: now)
                for card in [repeatCard, deadline, archived, past] { _ = try await commands.save(CardDraft(card: card), now: now) }
                note = try await commands.save(CardDraft(card: note), now: now)
                _ = try await repository.createRecoveryPoint(now: now)
                note.title = "替换后的内容"
                _ = try await commands.save(CardDraft(card: note, isEditing: true), now: now)
            }
            if scenario == "completed" {
                var card = Card(title: "收拾好今天的书桌", now: now)
                card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 18))
                let saved = try await commands.save(CardDraft(card: card), now: now)
                if let occurrence = OccurrenceEngine(calendar: calendar).next(for: saved, after: calendar.startOfDay(for: now)) { try await commands.complete(occurrence, now: now) }
            }
            if scenario == "notes" || scenario == "mixed" {
                var note = Card(title: "今天读到的一句话", kind: .note, now: now)
                note.note = "把这个念头轻轻留下。"; note.appearance.theme = .paper
                _ = try await commands.save(CardDraft(card: note), now: now)
            }
            if scenario == "mixed" {
                var scheduled = Card(title: "周一整理本周安排", now: now)
                scheduled.schedule = ScheduleDefinition(start: CivilDate(calendar.date(byAdding: .day, value: 3, to: now)!, calendar: calendar), time: DayTime(hour: 9))
                var undated = Card(title: "慢慢整理家里的书", now: now); undated.isPinned = true
                var plain = Card(title: "没有配图，也能把一句长长的话完整留下，让文字有足够舒展的空间", kind: .note, now: now)
                plain.note = "这里保留用户选择的无插画外观。"; plain.appearance.illustration = .none; plain.appearance.theme = .paper; plain.appearance.overriddenFields.insert("illustration")
                var long = Card(title: "读完这本书以后，把喜欢的段落整理出来，写一封信寄给很久没有见面的朋友", now: now)
                long.note = String(repeating: "慢慢记录，不必一次写完。", count: 6)
                var anniversary = Card(title: "相识纪念日", kind: .note, now: now)
                anniversary.birthday = BirthdayRule(name: "相识纪念日", calendar: .gregorian, month: 10, day: 18); anniversary.birthday?.occasion = .anniversary
                anniversary.appearance.theme = .blush; anniversary.appearance.illustration = .candle
                var chosen = Card(title: "保留我选的小银杏", kind: .note, now: now)
                chosen.appearance.overriddenFields.insert("illustration"); chosen.appearance.theme = .sage
                var dark = Card(title: "深色纸张上的一句提醒", now: now); dark.appearance.customHex = "29332E"
                for (index, card) in [scheduled, undated, plain, long, anniversary, chosen, dark].enumerated() {
                    _ = try await commands.save(CardDraft(card: card), now: now.addingTimeInterval(Double(-index-1)))
                }
                if let image = UIImage(named: "TravelPhotos")?.pngData() {
                    var card = Card(title: "用自己的图片留住这一刻", kind: .note, now: now)
                    let photo = try PhotoProcessor.prepare(image, cardID: card.id, index: 0)
                    card.attachmentIDs = [photo.id]; card.appearance.backgroundAttachmentID = photo.id; card.appearance.overriddenFields.insert("background")
                    var draft = CardDraft(card: card); draft.attachments = [photo]
                    _ = try await commands.save(draft, now: now.addingTimeInterval(-9))
                }
            }
            if scenario == "sharing-states" {
                for (index,status) in [ShareSessionStatus.prepared, .invited, .stopped, .revoked].enumerated() {
                    var card = Card(title: ["周末一起读书", "约好下次见面的时间", "各自安排的一件小事", "已经取消的邀请"][index], now: now)
                    card.schedule = ScheduleDefinition(start: CivilDate(now, calendar: calendar), time: DayTime(hour: 21))
                    var session = ShareSession(snapshot: SharedCardSnapshot(card: card, attachments: [], occurrence: nil, extent: .entireRule, includeNote: true, includePhotos: false), recipientLabel: "朋友", feedback: index != 0, now: now.addingTimeInterval(Double(-index)))
                    session.status = status
                    try await repository.saveLocalShareSession(session)
                    sharingSessions.append(session)
                }
                try await repository.setDeviceValue(sharingSessions, key: "state-scenario-sharing-sessions")
            }
            try await repository.setDeviceValue(true, key: "state-scenario-seeded")
        }
        if scenario == "sharing-states" { sharingSessions = try await repository.deviceValue([ShareSession].self, key: "state-scenario-sharing-sessions") ?? [] }
        if ProcessInfo.processInfo.environment["NIANYI_DARK"] == "1" { model.preferences.colorScheme = .dark }
        let snapshot = try await repository.library(); model.library = snapshot; model.projections = AppModel.project(snapshot, now: now, calendar: calendar)
        switch ProcessInfo.processInfo.environment["NIANYI_PAGE"] ?? "today" {
        case "cards": model.selectedTab = .cards
        case "review": model.selectedTab = .review
        case "sharing": model.selectedTab = .sharing
        case "detail": model.selectedCard = scenario == "unavailable" ? Card(title: "已移除的卡片", now: now) : snapshot.cards.first { $0.title.hasPrefix("读完") }
        case "birthday": if let card = snapshot.cards.first(where: { $0.birthday != nil }) { model.startsBirthdayEditor = true; model.composer = CardDraft(card: card, isEditing: true) }
        case "media": if let card = snapshot.cards.first { model.startsEditor = "media"; model.composer = CardDraft(card: card, isEditing: true) }
        default: break
        }
        if ["card-density", "experience-upgrade", "five-issues"].contains(scenario), let title = ProcessInfo.processInfo.environment["NIANYI_CARD_TITLE"] {
            model.selectedCard = snapshot.cards.first { $0.title == title }
        }
        if scenario == "experience-upgrade", ProcessInfo.processInfo.environment["NIANYI_PAGE"] == "screenshot", let card = snapshot.cards.first(where: { $0.title == "待识别截图" }) {
            var draft = CardDraft(card: card, isEditing: true); draft.attachments = try await repository.attachments(cardID: card.id)
            model.startsEditor = "screenshot"; model.composer = draft
        }
        if scenario == "invalid-file" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-state-fixture.nianyi")
            try Data("invalid schedule".utf8).write(to: url)
            await model.openFile(url)
        }
    }
}
#endif
