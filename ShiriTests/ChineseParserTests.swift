import XCTest
@testable import ShiriCore

final class ChineseParserTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; c.firstWeekday = 2; return c }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))! }
    func draft(_ text: String, places: [PlaceRule] = []) throws -> CardDraft { try ChineseCardParser(calendar: calendar).interpret(text, now: now, places: places)[0] }
    func testTwentyRequirementExamples() throws {
        let parcel = try draft("明天下午三点提醒我取快递")
        XCTAssertEqual(parcel.card.title, "取快递"); XCTAssertEqual(parcel.card.schedule?.start.key, "2026-09-12"); XCTAssertEqual(parcel.card.schedule?.time, DayTime(hour: 15))
        let hospital = try draft("后天早上九点去医院")
        XCTAssertEqual(hospital.card.schedule?.start.key, "2026-09-13"); XCTAssertEqual(hospital.card.schedule?.time?.hour, 9); XCTAssertNil(hospital.card.place)
        XCTAssertEqual(try draft("两小时后提醒我关窗").card.schedule?.absoluteInstant, now.addingTimeInterval(7_200))
        let meeting = try draft("下周三晚上八点开会")
        XCTAssertEqual(meeting.card.schedule?.start.key, "2026-09-16"); XCTAssertEqual(meeting.card.schedule?.time?.hour, 20)
        let rent = try draft("每月八号交房租")
        XCTAssertEqual(rent.card.schedule?.frequency, .monthly); XCTAssertEqual(rent.card.schedule?.monthDay, 8); XCTAssertTrue(rent.questions.contains(.time)); XCTAssertFalse(rent.card.reminders.isEnabled)
        let words = try draft("每周一三五晚上八点背单词")
        XCTAssertEqual(words.card.schedule?.weekdays, [2,4,6]); XCTAssertEqual(words.card.schedule?.time?.hour, 20)
        let ambiguous = try draft("周五前交材料，周三提醒我")
        XCTAssertTrue(ambiguous.questions.contains(.ambiguousDates)); XCTAssertNil(ambiguous.card.schedule)
        XCTAssertTrue(try draft("到公司提醒我发文件").questions.contains(.location))
        let home = PlaceRule(name: "家", address: "用户选择的地点", latitude: 31.2, longitude: 121.5)
        XCTAssertEqual(try draft("离开家提醒我带钥匙", places: [home]).card.place?.trigger, .exit)
        XCTAssertTrue(try draft("有空研究 SwiftUI").card.isUndatedTask)
        let parking = try draft("记一下停车位 B2 C16")
        XCTAssertEqual(parking.card.kind, .note); XCTAssertFalse(parking.card.canComplete)
        XCTAssertTrue(try draft("明年三月驾照到期").questions.contains(.date))
        XCTAssertTrue(try draft("每月三十一号付款").questions.contains(.invalidDate))
        let birthday = try draft("妈妈农历八月十五生日")
        XCTAssertEqual(birthday.card.birthday?.calendar, .lunar); XCTAssertEqual(birthday.card.birthday?.month, 8); XCTAssertEqual(birthday.card.birthday?.day, 15); XCTAssertFalse(birthday.questions.contains(.invalidDate))
        let workday = try draft("每个工作日九点提醒")
        XCTAssertTrue(workday.questions.contains(.workday)); XCTAssertNil(workday.card.schedule)
        let unclear = try draft("明天三点提醒我")
        XCTAssertTrue(unclear.questions.contains(.meridiem)); XCTAssertNil(unclear.card.schedule?.time)
        XCTAssertTrue(try draft("提醒我给妈妈打电话").card.isUndatedTask)
        XCTAssertTrue(try draft("明天早上九点交材料，再提前一天提醒").questions.contains(.pastReminder))
        XCTAssertEqual(try ChineseCardParser(calendar: calendar).interpret("明天买牛奶，后天取快递", now: now).count, 2)
        let correction = try draft("不要明天提醒，改成后天下午三点")
        XCTAssertEqual(correction.card.schedule?.start.key, "2026-09-13"); XCTAssertEqual(correction.card.schedule?.time?.hour, 15); XCTAssertTrue(correction.originalText.contains("不要明天"))
    }
    func testSpokenReminderSeparatesTitleTimeAndLeadTime() throws {
        for text in ["今天下午三点提前十分钟提醒我取快递", "今天下午三点，提前十分钟，提醒我取快递。", "提醒我今天下午3点去菜鸟驿站取快递，提前10分钟提醒我"] {
            let result = try draft(text)
            XCTAssertEqual(result.card.title, text.contains("菜鸟") ? "去菜鸟驿站取快递" : "取快递", text)
            XCTAssertEqual(result.card.schedule?.start.key, "2026-09-11")
            XCTAssertEqual(result.card.schedule?.time, DayTime(hour: 15))
            XCTAssertEqual(result.card.reminders.advanceMinutes, [10], text)
            XCTAssertTrue(result.questions.isEmpty, "\(text): \(result.questions)")
        }
    }
    func testSpeechPunctuationClockAndCustomNodes() throws {
        let result = try draft("今天下午 3:00，提醒我去再生书店取书，提前两小时和半小时提醒，到点也提醒，之后四十五分钟再提醒一次。")
        XCTAssertEqual(result.card.title, "去再生书店取书")
        XCTAssertEqual(result.card.schedule?.time, DayTime(hour: 15))
        XCTAssertEqual(result.card.reminders.advanceMinutes, [0,30,120])
        XCTAssertEqual(result.card.reminders.followUpMinutes, [45])
        XCTAssertTrue(result.questions.isEmpty)
        let compound = try draft("今天下午三点一刻，提前一个半小时提醒我去物业取快递")
        XCTAssertEqual(compound.card.title, "去物业取快递")
        XCTAssertEqual(compound.card.schedule?.time, DayTime(hour: 15, minute: 15))
        XCTAssertEqual(compound.card.reminders.advanceMinutes, [90])
    }
    func testCustomNodesDeduplicateAndKeepAmbiguousSpeechForReview() throws {
        let result = try draft("明天下午三点取快递，提前一小时和六十分钟提醒")
        XCTAssertEqual(result.card.reminders.advanceMinutes, [60])
        let ambiguous = try draft("今天三点提前十分钟提醒我取快递")
        XCTAssertTrue(ambiguous.questions.contains(.meridiem)); XCTAssertNil(ambiguous.card.schedule?.time)
        XCTAssertEqual(ambiguous.card.title, "取快递")
        XCTAssertTrue(try draft("今天早上九点提前十分钟提醒我取快递").questions.contains(.pastReminder))
    }
    func testTitleKeepsMeaningfulWordsAndPlaces() throws {
        let gift = try draft("明天买生日礼物")
        XCTAssertEqual(gift.card.title, "买生日礼物"); XCTAssertEqual(gift.card.kind, .task); XCTAssertNil(gift.card.birthday)
        XCTAssertEqual(try draft("请提醒我今天下午三点去再生书店取书").card.title, "去再生书店取书")
        XCTAssertEqual(try draft("今天下午三点提醒我申请请假").card.title, "申请请假")
        XCTAssertEqual(try draft("今天下午三点提醒我请假").card.title, "请假")
        XCTAssertEqual(try draft("今天下午三点提醒我再检查一次门锁").card.title, "再检查一次门锁")
        XCTAssertNil(try draft("今天下午三点提醒我去菜鸟驿站取快递").card.place)
    }
    func testExcessiveReminderNodesRequireReview() throws {
        for text in ["明天下午三点提前三百六十六天提醒我取快递", "明天下午三点取快递，之后二十五小时再提醒一次", "明天下午三点提前一分和二分和三分和四分和五分和六分和七分提醒我取快递"] {
            let result = try draft(text)
            XCTAssertTrue(result.questions.contains(.reminderNodes), text)
            XCTAssertThrowsError(try result.card.reminders.validate(), text)
        }
    }

    func testEverydayDateAndClockVocabulary() throws {
        let examples: [(String, String, String, DayTime)] = [
            ("明早七点提醒我跑步", "跑步", "2026-09-12", DayTime(hour: 7)),
            ("明晚八点给妈妈打电话", "给妈妈打电话", "2026-09-12", DayTime(hour: 20)),
            ("今晚8:30看电影", "看电影", "2026-09-11", DayTime(hour: 20, minute: 30)),
            ("后天下午两点半去人民医院复诊", "去人民医院复诊", "2026-09-13", DayTime(hour: 14, minute: 30)),
            ("三天后下午2点开会", "开会", "2026-09-14", DayTime(hour: 14)),
            ("下星期二上午10点缴水费", "缴水费", "2026-09-15", DayTime(hour: 10)),
            ("下下周一下午4点去牙科", "去牙科", "2026-09-21", DayTime(hour: 16)),
            ("这个月二十号上午九点审合同", "审合同", "2026-09-20", DayTime(hour: 9)),
            ("下个月五号早上九点缴社保", "缴社保", "2026-10-05", DayTime(hour: 9)),
            ("2026年10月18日下午3点去公园", "去公园", "2026-10-18", DayTime(hour: 15)),
            ("明天上午9时30分去图书馆", "去图书馆", "2026-09-12", DayTime(hour: 9, minute: 30)),
            ("明天下午三点钟取洗好的衣服", "取洗好的衣服", "2026-09-12", DayTime(hour: 15)),
            ("明天上午九点零五分申请请假", "申请请假", "2026-09-12", DayTime(hour: 9, minute: 5))
        ]
        for (text, title, day, time) in examples {
            let result = try draft(text)
            XCTAssertEqual(result.card.title, title, text)
            XCTAssertEqual(result.card.schedule?.start.key, day, text)
            XCTAssertEqual(result.card.schedule?.time, time, text)
            XCTAssertTrue(result.questions.isEmpty, "\(text): \(result.questions)")
        }
    }

    func testRelativeDurationsAndLeadTimesRemainSeparate() throws {
        for (text, title, minutes) in [("半小时后提醒我喝水", "喝水", 30), ("一个半小时以后提醒我休息", "休息", 90), ("过两小时二十分钟提醒我关烤箱", "关烤箱", 140), ("再过一刻钟提醒我伸展", "伸展", 15)] {
            let result = try draft(text)
            XCTAssertEqual(result.card.title, title, text)
            XCTAssertEqual(result.card.schedule?.absoluteInstant, now.addingTimeInterval(Double(minutes * 60)), text)
            XCTAssertTrue(result.questions.isEmpty, "\(text): \(result.questions)")
        }
        for text in ["明天下午三点开会，提早十分钟提醒我", "明天下午三点开会，十分钟前提醒我", "明天下午三点开会，半小时之前提醒我"] {
            let result = try draft(text)
            XCTAssertEqual(result.card.title, "开会", text)
            XCTAssertEqual(result.card.schedule?.time, DayTime(hour: 15), text)
            XCTAssertEqual(result.card.reminders.advanceMinutes, [text.contains("半小时") ? 30 : 10], text)
            XCTAssertTrue(result.questions.isEmpty, "\(text): \(result.questions)")
        }
    }

    func testRepeatVocabularyUsesRealScheduleRules() throws {
        for text in ["每周一、周三、周五晚上八点背单词", "每星期一和星期三和星期五晚上八点背单词"] {
            let result = try draft(text)
            XCTAssertEqual(result.card.title, "背单词", text)
            XCTAssertEqual(result.card.schedule?.frequency, .weekly, text)
            XCTAssertEqual(result.card.schedule?.weekdays, [2,4,6], text)
            XCTAssertTrue(result.questions.isEmpty, "\(text): \(result.questions)")
        }
        let wrap = try draft("每周五到周一晚上八点复盘")
        XCTAssertEqual(wrap.card.schedule?.weekdays, [6,7,1,2]); XCTAssertEqual(wrap.card.title, "复盘")
        let monthEnd = try draft("每月月底晚上八点交房租")
        XCTAssertEqual(monthEnd.card.schedule?.monthDay, 31); XCTAssertEqual(monthEnd.card.schedule?.missingDatePolicy, .lastValidDay)
        XCTAssertEqual(monthEnd.card.title, "交房租"); XCTAssertTrue(monthEnd.questions.isEmpty)
        for text in ["每两天晚上八点浇花", "每隔两天晚上八点浇花"] {
            let result = try draft(text)
            XCTAssertEqual(result.card.schedule?.frequency, .daily); XCTAssertEqual(result.card.schedule?.interval, 2)
            XCTAssertEqual(result.card.title, "浇花"); XCTAssertTrue(result.questions.isEmpty, text)
        }
        let yearly = try draft("每年十月一日上午九点备份资料")
        XCTAssertEqual(yearly.card.schedule?.frequency, .yearly); XCTAssertEqual(yearly.card.title, "备份资料")
        XCTAssertTrue(try draft("每天早上七点喝水").questions.isEmpty, "Repeating tasks must not be judged against today's already-past first time")
    }

    func testCorrectionRetainsActionAndRequestedReminder() throws {
        let result = try draft("明天下午三点提前十分钟提醒我去会议室开会，改成后天下午四点")
        XCTAssertEqual(result.card.title, "去会议室开会")
        XCTAssertEqual(result.card.schedule?.start.key, "2026-09-13")
        XCTAssertEqual(result.card.schedule?.time, DayTime(hour: 16))
        XCTAssertEqual(result.card.reminders.advanceMinutes, [10])
        XCTAssertTrue(result.questions.isEmpty)
        XCTAssertTrue(result.originalText.contains("改成"))
        for (text, day, time) in [("明天下午三点开会，改成后天", "2026-09-13", DayTime(hour: 15)), ("明天下午三点开会，改成下午四点", "2026-09-12", DayTime(hour: 16))] {
            let partial = try draft(text)
            XCTAssertEqual(partial.card.title, "开会"); XCTAssertEqual(partial.card.schedule?.start.key, day)
            XCTAssertEqual(partial.card.schedule?.time, time); XCTAssertTrue(partial.card.reminders.isEnabled)
            XCTAssertTrue(partial.questions.isEmpty, "\(text): \(partial.questions)")
        }
        let movedEarlier = try draft("明天下午三点提前一小时提醒我开会，改成今天上午十点半")
        XCTAssertTrue(movedEarlier.questions.contains(.pastReminder))
    }

    func testMultipleIndependentArrangementsKeepTheirOwnReminders() throws {
        let result = try ChineseCardParser(calendar: calendar).interpret("明天下午三点开会，提前十分钟提醒；后天上午九点体检，提前一小时提醒", now: now)
        XCTAssertEqual(result.count, 2)
        guard result.count == 2 else { return }
        XCTAssertEqual(result[0].card.title, "开会"); XCTAssertEqual(result[0].card.reminders.advanceMinutes, [10])
        XCTAssertEqual(result[1].card.title, "体检"); XCTAssertEqual(result[1].card.reminders.advanceMinutes, [60])
        XCTAssertEqual(result[0].card.schedule?.start.key, "2026-09-12")
        XCTAssertEqual(result[1].card.schedule?.start.key, "2026-09-13")
    }

    func testExplicitNoReminderAndMeaningfulTitleAreRespected() throws {
        for text in ["明天下午三点去医院复诊，不用提醒我", "明天下午三点去医院复诊，不需要提醒"] {
            let result = try draft(text)
            XCTAssertFalse(result.card.reminders.isEnabled, text); XCTAssertEqual(result.card.title, "去医院复诊", text)
            XCTAssertEqual(result.card.schedule?.time, DayTime(hour: 15)); XCTAssertTrue(result.questions.isEmpty)
        }
        XCTAssertEqual(try draft("明天下午三点提醒我去三点水书店买点心").card.title, "去三点水书店买点心")
        XCTAssertEqual(try draft("明天上午九点提醒我买牛奶和面包").card.title, "买牛奶和面包")
        XCTAssertEqual(try draft("明天上午九点不要忘记带护照").card.title, "带护照")
        let rename = try draft("明天下午三点提醒我把文件名改成最终版")
        XCTAssertEqual(rename.card.title, "把文件名改成最终版"); XCTAssertTrue(rename.questions.isEmpty)
        for text in ["请帮我在明天下午三点提醒我取书", "麻烦帮我明天下午三点取书", "明天下午三点提醒一下我取书"] {
            let polite = try draft(text); XCTAssertEqual(polite.card.title, "取书", text); XCTAssertTrue(polite.questions.isEmpty, text)
        }
    }

    func testUnsupportedOrAmbiguousSpeechNeverBecomesAConfidentDraft() throws {
        for text in ["明天下午三点到四点开会", "明天上午九点和下午三点吃药", "明天或者后天下午三点去公园", "下班后提醒我买菜", "周末提醒我洗车", "每隔两小时喝水", "明天下午三点左右开会", "明天下午三点如果不下雨就去公园", "明天下午三点开会然后去超市", "明天下午三点开会，一直提醒到我完成", "九月三十一号上午九点交材料"] {
            let result = try ChineseCardParser(calendar: calendar).interpret(text, now: now, defaultTime: DayTime(hour: 9))
            XCTAssertTrue(result.count > 1 || result.contains { !$0.questions.isEmpty }, text)
        }
        let vague = try ChineseCardParser(calendar: calendar).interpret("明天下午去游泳", now: now, defaultTime: DayTime(hour: 9))[0]
        XCTAssertNil(vague.card.schedule?.time); XCTAssertTrue(vague.questions.contains(.time))
        XCTAssertTrue(try draft("今天下午三点每两周开会").questions.contains(.repeatRule))
    }

    func testLocationTriggersDifferFromPlacesInTimedTitles() throws {
        let library = PlaceRule(name: "图书馆", address: "已选择的图书馆", latitude: 31.2, longitude: 121.5)
        let arrival = try draft("到图书馆提醒我还书", places: [library])
        XCTAssertEqual(arrival.card.place?.id, library.id); XCTAssertEqual(arrival.card.title, "还书"); XCTAssertTrue(arrival.questions.isEmpty)
        let unknown = try draft("到健身房提醒我拿水杯")
        XCTAssertTrue(unknown.questions.contains(.location)); XCTAssertEqual(unknown.card.title, "拿水杯")
        let timed = try draft("明天下午三点到公司开会")
        XCTAssertNil(timed.card.place); XCTAssertEqual(timed.card.title, "到公司开会"); XCTAssertTrue(timed.questions.isEmpty)
    }

    func testMalformedAndRepeatedCorrectionsStayBounded() throws {
        let longCorrection = String(repeating: "改成", count: 400) + "明天下午三点开会"
        XCTAssertTrue(try draft(longCorrection).questions.contains(.interpretation))
        let invalid = try ChineseCardParser(calendar: calendar).interpret("明天下午二十五点开会", now: now, defaultTime: DayTime(hour: 9))[0]
        XCTAssertNil(invalid.card.schedule?.time); XCTAssertTrue(invalid.questions.contains(.time))
        XCTAssertEqual(ChineseCardParser.chineseInteger("三六五"), 365)
        XCTAssertEqual(ChineseCardParser.chineseInteger("零五"), 5)
        for text in ["明天24:00开会", "明天上午18:00开会", "明天凌晨十五点开会", "一个小时后下午三点开会"] {
            XCTAssertFalse(try draft(text).questions.isEmpty, text)
        }
    }
}
