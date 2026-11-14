import Foundation

/// Deterministic, local interpretation. This parser never saves a card or requests a permission.
public struct ChineseCardParser: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar) { self.calendar = calendar }
    private let number = "[零〇一二两三四五六七八九十百廿卅0-9]+"

    public func interpret(_ input: String, now: Date, defaultTime: DayTime? = nil, places: [PlaceRule] = []) throws -> [CardDraft] {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return [] }
        guard original.count <= AppLimits.noteLength else { throw ShiriError.validation("这段内容较长，请分成几张卡片记录") }
        // A semicolon keeps each arrangement's trailing reminder clauses together.
        let arrangements = original.components(separatedBy: CharacterSet(charactersIn: "；;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if arrangements.count > 1 && arrangements.count <= 10 && !original.contains("改成") && !original.contains("改到"),
           arrangements.allSatisfy({ first("今天|明天|明早|明晚|后天|下周|星期|每|\(number)月", in: $0) != nil }) {
            return arrangements.map { parseOne($0, now: now, defaultTime: defaultTime, places: places) }
        }
        let fragments = original.components(separatedBy: CharacterSet(charactersIn: "，,；;\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let canSplit = fragments.count > 1 && fragments.count <= 10 &&
            !original.contains("改成") && !original.contains("提前") && !original.contains("周五前") &&
            fragments.allSatisfy { $0.range(of: "明天|后天|今天|下周|周[一二三四五六日天]", options: .regularExpression) != nil }
        return (canSplit ? fragments : [original]).map { parseOne($0, now: now, defaultTime: defaultTime, places: places) }
    }

    private func parseOne(_ original: String, now: Date, defaultTime: DayTime?, places: [PlaceRule]) -> CardDraft {
        let correctionParts = original.replacingOccurrences(of: "改到", with: "改成").components(separatedBy: "改成")
        let correctionCue = correctionParts.count > 1 && (
            first("[，,；;]\\s*$", in: correctionParts[0]) != nil ||
            (!correctionParts[0].contains("把") && first("今天|明天|明早|明晚|后天|周|星期|月|\(number)[点时]|[0-9]{1,2}:[0-9]{2}|早上|上午|下午|晚上|提前|提早", in: correctionParts.last ?? "") != nil))
        if correctionCue {
            // Bound correction work to the initial action and final instruction, even for long dictation.
            let before = correctionParts[0]
            let after = correctionParts[correctionParts.count - 1]
            var result = parseOne(after, now: now, defaultTime: defaultTime, places: places)
            let previous = parseOne(before, now: now, defaultTime: defaultTime, places: places)
            if let schedule = previous.card.schedule {
                let saysTime = first("\(number)[点时]|[0-9]{1,2}:[0-9]{2}|早上|上午|下午|晚上|凌晨", in: after) != nil
                if result.card.schedule == nil && saysTime {
                    let day = schedule.start
                    result = parseOne("\(day.year)年\(day.month)月\(day.day)日" + after, now: now, defaultTime: defaultTime, places: places)
                } else if result.card.schedule != nil && !saysTime {
                    result.card.schedule?.time = schedule.time
                    if schedule.time != nil { result.questions.removeAll { $0 == .time } }
                } else if result.card.schedule == nil {
                    result.card.schedule = schedule
                    result.questions.append(.interpretation)
                }
            }
            if result.card.title.isEmpty, !before.hasPrefix("不要"), !previous.card.title.isEmpty {
                result.card.title = previous.card.title
                result.card.appearance = previous.card.appearance
                result.questions.removeAll { $0 == .title }
            }
            if first("提前|提早|之前提醒|前提醒|准时|到点|之后|不用提醒|不需要提醒", in: after) == nil {
                let enabled = result.card.reminders.isEnabled
                result.card.reminders = previous.card.reminders
                result.card.reminders.isEnabled = enabled && !before.contains("不用提醒") && !before.contains("不需要提醒")
            }
            if result.card.schedule?.time != nil && !after.contains("不用提醒") && !after.contains("不需要提醒") && !before.contains("不用提醒") && !before.contains("不需要提醒") {
                result.card.reminders.isEnabled = true
            }
            if (try? result.card.reminders.validate()) == nil { result.questions.append(.reminderNodes) }
            result.questions.removeAll { $0 == .pastReminder }
            if let schedule = result.card.schedule, schedule.frequency == .never, let time = schedule.time,
               let planned = OccurrenceEngine(calendar: calendar).date(schedule.start, time: time),
               result.card.reminders.advanceMinutes.contains(where: { planned.addingTimeInterval(-Double($0) * 60) <= now }) {
                result.questions.append(.pastReminder)
            }
            if correctionParts.count > 2 || previous.card.isRepeating { result.questions.append(.interpretation) }
            result.questions = Array(Set(result.questions)).sorted { $0.rawValue < $1.rawValue }
            result.originalText = original; result.interpretedText = original
            return result
        }
        var text = original.replacingOccurrences(of: "：", with: ":")
        for (word, expanded) in [("明早", "明天早上"), ("明晚", "明天晚上"), ("今早", "今天早上"), ("今晚", "今天晚上")] {
            text = text.replacingOccurrences(of: word, with: expanded)
        }
        let isBirthday = text.contains("生日") && !["生日礼物", "生日蛋糕", "生日聚会", "生日派对"].contains(where: text.contains)
        var card = Card(title: "", kind: text.hasPrefix("记一下") || text.hasPrefix("记住停车") ? .note : .task, now: now)
        var questions: [DraftQuestion] = []
        let today = CivilDate(now, calendar: calendar)
        var selectedDay: CivilDate?
        var selectedTime: DayTime?
        var frequency: RepeatFrequency = .never
        var repeatInterval = 1
        var missingDatePolicy: MissingDatePolicy = .unspecified
        var weekdays: Set<Int> = []
        var monthDay = today.day
        var selectedMonth = today.month
        var absolute: Date?
        var consumption: [String] = []
        let noReminders = matches("(?:不用|无需|不需要|不要)再?提醒(?:我)?", in: text)
        for match in noReminders { text = removingFirst(match.full, from: text) }
        // Parse reminder offsets before clock times: an extra reminder is not the task's date.
        let atom = "(?:\(number)个?半小时|半个?小时|一刻钟|三刻钟|\(number)个?(?:天|小时|分钟|分))"
        let duration = "(?:\(atom))(?:又?\(atom))*"
        let list = "\(duration)(?:(?:、|和|及|，|,)\\s*(?:再?提前)?\(duration))*"
        let advanceMatches = matches("(?:再)?(?:提前|提早)\\s*(\(list))\\s*(?:再?提醒(?:我)?(?:一次)?|通知(?:我)?)?", in: text)
            + matches("(\(list))(?:之)?前\\s*(?:提醒|通知)(?:我)?", in: text)
        if !advanceMatches.isEmpty {
            card.reminders.advanceMinutes = Array(Set(advanceMatches.flatMap { match in
                matches(duration, in: match.groups[0]).map { durationMinutes($0.full) ?? -1 }
            })).sorted()
            for match in advanceMatches { text = removingFirst(match.full, from: text) }
        }
        let followUps = matches("(?:之后|到点后|到时后)\\s*(\(list))\\s*(?:再)?提醒(?:我)?(?:一次)?", in: text)
        for match in followUps {
            card.reminders.followUpMinutes += matches(duration, in: match.groups[0]).map { durationMinutes($0.full) ?? -1 }
            text = removingFirst(match.full, from: text)
        }
        card.reminders.followUpMinutes = Array(Set(card.reminders.followUpMinutes)).sorted()
        for match in matches("(?:准时|到点|到时)(?:也|再)?提醒(?:我)?(?:一次)?", in: text) {
            card.reminders.advanceMinutes = Array(Set(card.reminders.advanceMinutes + [0])).sorted()
            text = removingFirst(match.full, from: text)
        }
        // Dictation commonly inserts whitespace between a period and its numeric clock.
        text = text.replacingOccurrences(of: "(今天|明天|后天|早上|早晨|上午|中午|下午|傍晚|晚上|凌晨)\\s+(?=[0-9零〇一二两三四五六七八九十])", with: "$1", options: .regularExpression)
        var title = text

        if let match = first("(?:再)?过\\s*(\(duration))(?:(?:以|之)?后)?|(\(duration))(?:以|之)?后", in: text),
           let minutes = durationMinutes(match.groups.first(where: { !$0.isEmpty }) ?? ""), minutes > 0 {
            let value = now.addingTimeInterval(Double(minutes) * 60)
            selectedDay = CivilDate(value, calendar: calendar)
            // Calendar-day language can carry a separate clock; elapsed hours retain an exact instant.
            if first("^\(number)个?天$", in: match.groups.first(where: { !$0.isEmpty }) ?? "") == nil {
                absolute = value
                selectedTime = DayTime(hour: calendar.component(.hour, from: value), minute: calendar.component(.minute, from: value))
            }
            consumption.append(match.full)
        }

        if text.contains("工作日") { questions.append(.workday); consumption.append("每个工作日") }
        if let match = first("每(?:个)?(?:周|星期|礼拜)([一二三四五六日天](?:(?:、|和|及|至|到)?(?:周|星期|礼拜)?[一二三四五六日天])*)", in: text) {
            frequency = .weekly
            let symbols = Array(match.groups[0].replacingOccurrences(of: "周|星期|礼拜", with: "", options: .regularExpression))
            let values: [Character: Int] = ["一":2,"二":3,"三":4,"四":5,"五":6,"六":7,"日":1,"天":1]
            if symbols.contains("至") || symbols.contains("到"), let first = symbols.first.flatMap({ values[$0] }), let last = symbols.last.flatMap({ values[$0] }) {
                var day = first; weekdays.insert(day)
                while day != last { day = day % 7 + 1; weekdays.insert(day) }
            } else { weekdays = Set(symbols.compactMap { values[$0] }) }
            consumption.append(match.full); selectedDay = today
        } else if let match = first("每月(?:月底|月末|最后一天)", in: text) {
            frequency = .monthly; monthDay = 31; missingDatePolicy = .lastValidDay
            selectedDay = today; consumption.append(match.full)
        } else if let match = first("每月(\(number))[日号]", in: text), let value = Self.chineseInteger(match.groups[0]) {
            frequency = .monthly; monthDay = value; selectedDay = today; consumption.append(match.full)
            if value > 28 { questions.append(.invalidDate) }
        } else if let match = first("每(?:隔)?(\(number))天", in: text), let value = Self.chineseInteger(match.groups[0]) {
            frequency = .daily; repeatInterval = value; selectedDay = today; consumption.append(match.full)
            if !(1...366).contains(value) { questions.append(.repeatRule) }
        } else if text.contains("每天") || text.contains("每日") {
            frequency = .daily; selectedDay = today; consumption += ["每天", "每日"]
        }

        if absolute == nil {
            let relatives: [(String, Int)] = [("大后天",3),("后天",2),("明天",1),("今天",0),("今晚",0)]
            for (word, days) in relatives where text.contains(word) {
                if let day = calendar.date(byAdding: .day, value: days, to: now) { selectedDay = CivilDate(day, calendar: calendar) }
                consumption.append(word); break
            }
            if let match = first("(?:这个月|本月)(\(number))[日号]", in: text), let value = Self.chineseInteger(match.groups[0]) {
                selectedDay = CivilDate(year: today.year, month: today.month, day: value); consumption.append(match.full)
            } else if let match = first("下个月(\(number))[日号]", in: text), let value = Self.chineseInteger(match.groups[0]),
               let nextMonth = calendar.date(byAdding: .month, value: 1, to: calendar.dateInterval(of: .month, for: now)!.start) {
                let next = CivilDate(nextMonth, calendar: calendar)
                selectedDay = CivilDate(year: next.year, month: next.month, day: value); consumption.append(match.full)
            } else if let match = first("(?:(20[0-9]{2})年|(明年|今年))?(\(number))月(\(number))[日号]?", in: text),
                      let month = Self.chineseInteger(match.groups[2]), let day = Self.chineseInteger(match.groups[3]) {
                let year = Int(match.groups[0]) ?? (today.year + (match.groups[1] == "明年" ? 1 : 0))
                selectedDay = CivilDate(year: year, month: month, day: day)
                selectedMonth = month; monthDay = day; consumption.append(match.full)
                if text.contains("每年") { frequency = .yearly; consumption.append("每年") }
            } else if first("明年\(number)月", in: text) != nil {
                questions.append(.date)
            }
            if frequency == .never, let match = first("(下下|下|本|这)?(?:周|星期|礼拜)([一二三四五六日天])", in: text) {
                let values = ["一":2,"二":3,"三":4,"四":5,"五":6,"六":7,"日":1,"天":1]
                let weekday = values[match.groups[1]] ?? 2
                var cal = calendar; cal.firstWeekday = 2; cal.minimumDaysInFirstWeek = 4
                if let week = cal.dateInterval(of: .weekOfYear, for: now)?.start {
                    var delta = (weekday + 5) % 7
                    if match.groups[0] == "下" { delta += 7 }
                    if match.groups[0] == "下下" { delta += 14 }
                    if let day = cal.date(byAdding: .day, value: delta, to: week) { selectedDay = CivilDate(day, calendar: cal) }
                    consumption.append(match.full)
                }
            }

            if let match = first("(早上|早晨|上午|中午|下午|傍晚|晚上|今晚|凌晨)?(?<![0-9])([01]?[0-9]|2[0-3]):([0-5][0-9])(?![0-9])", in: text) {
                var hour = Int(match.groups[1]) ?? 0
                if ["下午","晚上","傍晚"].contains(match.groups[0]) && hour < 12 { hour += 12 }
                if match.groups[0] == "中午" && hour < 11 { hour += 12 }
                if match.groups[0] == "凌晨" && hour == 12 { hour = 0 }
                if periodConflicts(match.groups[0], hour: Int(match.groups[1]) ?? 0) { questions.append(.meridiem) }
                else if match.groups[0] == "晚上" && hour == 12 { questions.append(.meridiem) }
                else { selectedTime = DayTime(hour: hour, minute: Int(match.groups[2]) ?? 0) }
                consumption.append(match.full)
            } else if let match = first("(早上|早晨|上午|中午|下午|傍晚|晚上|今晚|凌晨)?(\(number))[点时](?:(半|一刻|三刻)|(\(number))分?)?钟?", in: text),
                      let hourValue = Self.chineseInteger(match.groups[1]) {
                var hour = hourValue
                let minute = ["半": 30, "一刻": 15, "三刻": 45][match.groups[2]] ?? (Self.chineseInteger(match.groups[3]) ?? 0)
                let period = match.groups[0].isEmpty && original.contains("今晚") ? "晚上" : match.groups[0]
                if ["下午","晚上","傍晚"].contains(period) && hour < 12 { hour += 12 }
                if period == "中午" && hour < 11 { hour += 12 }
                if period == "凌晨" && hour == 12 { hour = 0 }
                if periodConflicts(period, hour: hourValue) { questions.append(.meridiem) }
                else if period.isEmpty && hour <= 12 { questions.append(.meridiem) }
                else if period == "晚上" && hourValue == 12 { questions.append(.meridiem) }
                else {
                    let value = DayTime(hour: hour, minute: minute)
                    if value.isValid { selectedTime = value } else { questions.append(.time) }
                }
                consumption.append(match.full)
            }
        }

        let explicitPeriod = "早上|早晨|上午|中午|下午|傍晚|晚上|凌晨"
        let clock = "(?:\(number))[点时](?:半|一刻|三刻|\(number)分?)?|[0-9]{1,2}:[0-9]{2}"
        let timeRange = first("(?:\(explicitPeriod))?(?:\(clock))(?:到|至|和|、|或)(?:\(explicitPeriod))?(?:\(clock))", in: text)
        if matches("(?:\(explicitPeriod))(?:\(clock))", in: text).count > 1 || timeRange != nil {
            questions.append(.multipleTimes)
        }
        if let timeRange { consumption.append(timeRange.full) }
        if absolute != nil && first("(?:\(explicitPeriod))(?:\(clock))", in: text) != nil { questions.append(.multipleTimes) }
        if selectedTime == nil && first("[0-9]+:[0-9]+", in: text) != nil { questions.append(.time) }
        if selectedTime == nil && first(explicitPeriod, in: text) != nil { questions.append(.time) }
        if first("左右|大概|差不多|有时间|下班后|吃完饭|忙完|如果|的话|然后|接着", in: text) != nil { questions.append(.interpretation) }
        if first("周末|月底|月末|下个月|下周|下星期", in: text) != nil && selectedDay == nil { questions.append(.date) }
        if first("每(?:隔)?(?:\(number)|半)?个?(?:小时|分钟|天|日|周|星期|礼拜|月|年)|一直提醒|直到.*完成|提醒到.*完成", in: text) != nil && frequency == .never { questions.append(.repeatRule) }
        if frequency == .never && matches("大后天|后天|明天|今天", in: text).count > 1 { questions.append(.ambiguousDates) }
        if selectedTime == nil && !questions.contains(.meridiem) && !questions.contains(.time) { selectedTime = defaultTime }
        if let selectedDay {
            var definition = ScheduleDefinition(start: selectedDay, time: selectedTime, frequency: frequency, timeZone: calendar.timeZone)
            definition.weekdays = weekdays; definition.monthDay = monthDay; definition.month = selectedMonth
            definition.interval = repeatInterval; definition.missingDatePolicy = missingDatePolicy
            if frequency == .never { definition.monthDay = selectedDay.day; definition.month = selectedDay.month }
            if let absolute { definition.absoluteInstant = absolute; definition.timeZoneMode = .elapsed }
            card.schedule = definition
            if (try? definition.validate()) == nil { questions.append(.invalidDate) }
            if selectedTime == nil { questions.append(.time) }
            card.reminders.isEnabled = selectedTime != nil
            if frequency == .never, let time = selectedTime,
               let value = OccurrenceEngine(calendar: calendar).date(selectedDay, time: time), value <= now { questions.append(.pastReminder) }
        } else if selectedTime != nil && !isBirthday {
            questions.append(.date)
        }

        if frequency == .never, let schedule = card.schedule, let time = schedule.time,
           let planned = OccurrenceEngine(calendar: calendar).date(schedule.start, time: time),
           card.reminders.advanceMinutes.contains(where: { $0 >= 0 && $0 <= ReminderPolicy.maximumAdvanceMinutes && planned.addingTimeInterval(-Double($0) * 60) < now }) {
            questions.append(.pastReminder)
        }
        if (try? card.reminders.validate()) == nil { questions.append(.reminderNodes) }

        if text.contains("前") && first("周[一二三四五六日天]前", in: text) != nil && text.contains("提醒") {
            questions.append(.ambiguousDates); card.schedule = nil; card.reminders.isEnabled = false
        }
        if questions.contains(.workday) { card.schedule = nil; card.reminders.isEnabled = false }
        if let match = first("(到达|回到|离开|到)([^，,。；;]{1,20}?)(?:的时候|时)?(?:提醒|通知)(?:我)?", in: text) {
            let name = match.groups[1]
            if var place = places.first(where: { $0.name == name }) {
                place.trigger = match.groups[0] == "离开" ? .exit : .enter
                card.place = place; card.reminders.isEnabled = true
            } else { questions.append(.location) }
            consumption.append(match.full)
        }

        if isBirthday {
            let namePart = text.components(separatedBy: CharacterSet(charactersIn: "公农历每0123456789一二三四五六七八九十"))[0]
                .replacingOccurrences(of: "的", with: "").trimmingCharacters(in: .whitespaces)
            var birthday = BirthdayRule(name: namePart.isEmpty ? "" : namePart, calendar: text.contains("农历") ? .lunar : (text.contains("公历") ? .gregorian : nil), month: selectedDay?.month ?? 1, day: selectedDay?.day ?? 1)
            birthday.dayTime = selectedTime
            birthday.isLeapMonth = text.contains("闰")
            card.birthday = birthday; card.kind = .note; card.schedule = nil
            card.reminders.isEnabled = selectedTime != nil && birthday.calendar != nil
            questions.append(.calendar)
            if birthday.day == 30 || (birthday.calendar == .gregorian && birthday.month == 2 && birthday.day == 29) || birthday.isLeapMonth { questions.append(.invalidDate) }
            title = birthday.name.isEmpty ? "生日提醒" : "\(birthday.name)的生日"
        } else {
            for part in consumption.sorted(by: { $0.count > $1.count }) where !part.isEmpty {
                title = removingFirst(title.contains("在" + part) ? "在" + part : part, from: title)
            }
            // Strip conversational wrappers at clause boundaries, never inside names or actions.
            let clauses = title.components(separatedBy: CharacterSet(charactersIn: "，,。；;：:！!？?"))
            title = clauses.map { clause in
                clause.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^(?:(?:麻烦|请)?(?:帮我|给我)?(?:(?:提醒|喊|叫|通知)(?:一下我|我(?:一下)?)(?![们的家爸妈哥姐弟妹爷奶叔姨]|老公|老婆|同事|朋友|室友|孩子|儿子|女儿|老师|老板|客户)|提醒(?=$)|记一下|记住)|(?:麻烦|请)?帮我|麻烦|有空|以后|到时|不要忘记)+", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }.joined(separator: "，")
        }
        if !noReminders.isEmpty { card.reminders.isEnabled = false }
        card.title = title
        card.appearance = .recommended(for: title, kind: card.kind, birthday: card.birthday != nil)
        if title.isEmpty { questions.append(.title) }
        var draft = CardDraft(card: card, originalText: original, questions: Array(Set(questions)).sorted { $0.rawValue < $1.rawValue })
        draft.interpretedText = original
        return draft
    }

    private struct Match { var full: String; var groups: [String] }
    private func periodConflicts(_ period: String, hour: Int) -> Bool {
        if ["早上", "早晨", "上午"].contains(period) { return hour >= 12 }
        if ["下午", "晚上", "傍晚"].contains(period) { return hour == 0 }
        if period == "中午" { return ![1,2,11,12,13,14].contains(hour) }
        if period == "凌晨" { return hour > 6 && hour != 12 }
        return false
    }
    private func removingFirst(_ part: String, from text: String) -> String {
        guard let range = text.range(of: part) else { return text }
        var result = text; result.removeSubrange(range); return result
    }
    private func first(_ pattern: String, in text: String) -> Match? { matches(pattern, in: text, limit: 1).first }
    private func matches(_ pattern: String, in text: String, limit: Int? = nil) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let results = limit == 1 ? regex.firstMatch(in: text, range: range).map { [$0] } ?? [] : regex.matches(in: text, range: range)
        return results.compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            return Match(full: String(text[range]), groups: (1..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
            })
        }
    }
    private func durationMinutes(_ text: String) -> Int? {
        var remaining = text, total = 0
        while !remaining.isEmpty {
            guard let match = first("^(?:(\(number))个?半小时|(半个?小时|一刻钟|三刻钟)|(\(number))个?(天|小时|分钟|分))", in: remaining) else { return nil }
            let value: Int
            if !match.groups[0].isEmpty {
                guard let amount = Self.chineseInteger(match.groups[0]), amount <= ReminderPolicy.maximumAdvanceMinutes / 60 else { return nil }
                value = amount * 60 + 30
            } else if !match.groups[1].isEmpty {
                value = match.groups[1] == "一刻钟" ? 15 : (match.groups[1] == "三刻钟" ? 45 : 30)
            } else {
                let multiplier = match.groups[3] == "天" ? 1_440 : (match.groups[3] == "小时" ? 60 : 1)
                guard let amount = Self.chineseInteger(match.groups[2]), amount <= ReminderPolicy.maximumAdvanceMinutes / multiplier else { return nil }
                value = amount * multiplier
            }
            total += value
            guard total <= ReminderPolicy.maximumAdvanceMinutes else { return nil }
            remaining = String(remaining.dropFirst(match.full.count))
            if remaining.hasPrefix("又") { remaining.removeFirst() }
        }
        return total
    }

    public static func chineseInteger(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        if text.count > 1 && text.allSatisfy({ digits[$0] != nil }) {
            return Int(text.compactMap { digits[$0].map(String.init) }.joined())
        }
        var total = 0; var current = 0
        for character in text {
            if let digit = digits[character] { current = digit }
            else if character == "十" { total += max(1,current) * 10; current = 0 }
            else if character == "百" { total += max(1,current) * 100; current = 0 }
            else if character == "廿" { total += 20 }
            else if character == "卅" { total += 30 }
            else { return nil }
        }
        return total + current
    }
}
