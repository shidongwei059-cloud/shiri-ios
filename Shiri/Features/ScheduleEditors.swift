import SwiftUI
import ShiriCore

/// Everyday edits stay together; less common recurrence and reminder rules remain available on demand.
struct QuickScheduleFields: View {
    @EnvironmentObject private var model: AppModel
    @Binding var card: Card
    var openSchedule: () -> Void
    var openReminders: () -> Void
    private var calendar: Calendar { card.schedule?.calendar(fallback: model.calendar) ?? model.calendar }
    private var hasDate: Binding<Bool> { Binding(get: { card.schedule != nil }, set: { enabled in
        if enabled { card.schedule = ScheduleDefinition(start: CivilDate(model.now, calendar: model.calendar), time: nil) }
        else { card.schedule = nil; if card.place == nil { card.reminders.isEnabled = false } }
    }) }
    private var date: Binding<Date> { Binding(get: {
        guard let rule = card.schedule else { return model.now }
        return OccurrenceEngine(calendar: calendar).date(rule.start, time: rule.time ?? DayTime(hour: 9)) ?? model.now
    }, set: { value in
        card.schedule?.useCalendarTiming()
        card.schedule?.start = CivilDate(value, calendar: calendar)
        card.schedule?.monthDay = calendar.component(.day, from: value)
        card.schedule?.month = calendar.component(.month, from: value)
        if card.schedule?.time != nil { card.schedule?.time = DayTime(hour: calendar.component(.hour, from: value), minute: calendar.component(.minute, from: value)) }
    }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("安排日期", isOn: hasDate).accessibilityIdentifier("quickScheduleEnabled")
            if card.schedule != nil {
                DatePicker("日期", selection: date, displayedComponents: .date).accessibilityIdentifier("quickScheduleDate")
                Toggle("指定时间", isOn: Binding(get: { card.schedule?.time != nil }, set: { enabled in
                    card.schedule?.useCalendarTiming()
                    card.schedule?.time = enabled ? (model.preferences.defaultReminderTime ?? DayTime(hour: 9)) : nil
                    if !enabled && card.place == nil { card.reminders.isEnabled = false }
                })).accessibilityIdentifier("quickTimeEnabled")
                if card.schedule?.time != nil { DatePicker("时间", selection: date, displayedComponents: .hourAndMinute).accessibilityIdentifier("quickScheduleTime") }
                HStack {
                    Text("重复"); Spacer()
                    Picker("重复", selection: Binding(get: { card.schedule?.frequency ?? .never }, set: { frequency in
                        card.schedule?.useCalendarTiming()
                        card.schedule?.frequency = frequency
                        if frequency == .weekly && card.schedule?.weekdays.isEmpty == true { card.schedule?.weekdays = [calendar.component(.weekday, from: date.wrappedValue)] }
                    })) { ForEach(RepeatFrequency.allCases, id: \.self) { Text($0.title) } }.labelsHidden().accessibilityIdentifier("quickRepeat")
                }
                Button(action: openSchedule) {
                    HStack { Text("重复细节与截止时间"); Spacer(); Image(systemName: "chevron.right") }
                        .font(.footnote).foregroundColor(Paper.secondary).frame(minHeight: 36)
                }.accessibilityIdentifier("composerSchedule")
                if let due = card.schedule?.dueAt {
                    Text("截止：" + CardPresentation.dateLabel(due, format: "yyyy年M月d日 HH:mm", calendar: calendar))
                        .font(.footnote).foregroundColor(Paper.secondary).accessibilityIdentifier("composerDeadline")
                }
            }
            if card.kind == .task || card.schedule != nil || card.place != nil {
                Divider()
                Toggle("开启提醒", isOn: Binding(get: { card.reminders.isEnabled }, set: { enabled in
                    if enabled && card.schedule == nil && card.place == nil {
                        card.schedule = ScheduleDefinition(start: CivilDate(model.now, calendar: model.calendar), time: model.preferences.defaultReminderTime ?? DayTime(hour: 9))
                    } else if enabled && card.schedule?.time == nil && card.place == nil {
                        card.schedule?.time = model.preferences.defaultReminderTime ?? DayTime(hour: 9)
                    }
                    card.reminders.isEnabled = enabled
                })).accessibilityIdentifier("quickReminderEnabled")
                if card.reminders.isEnabled {
                    HStack {
                        Text("提醒方式"); Spacer()
                        Picker("提醒方式", selection: $card.reminders.channel) {
                            Text("普通通知").tag(ReminderChannel.notification)
                            if model.systemCapabilities.alarms.isSupported || card.reminders.channel == .alarm { Text("系统闹钟").tag(ReminderChannel.alarm) }
                        }.labelsHidden()
                    }
                }
                Button(action: openReminders) {
                    HStack { Text("提前提醒与锁屏显示"); Spacer(); Image(systemName: "chevron.right") }
                        .font(.footnote).foregroundColor(Paper.secondary).frame(minHeight: 36)
                }.accessibilityIdentifier("composerReminder")
            }
        }.font(Paper.text(15)).tint(Paper.accent).environment(\.timeZone, calendar.timeZone)
    }
}

struct ScheduleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var card: Card
    @State private var error: String?
    private var enabled: Binding<Bool> { Binding(get: { card.schedule != nil }, set: { value in
        if value { card.schedule = ScheduleDefinition(start: CivilDate(model.now, calendar: model.calendar), time: nil) }
        else { card.schedule = nil; if card.place == nil { card.reminders.isEnabled = false } }
    }) }
    private var rule: Binding<ScheduleDefinition> { Binding(get: { card.schedule ?? ScheduleDefinition(start: CivilDate(model.now, calendar: model.calendar), time: nil) }, set: { card.schedule = $0 }) }
    private var scheduleCalendar: Calendar { rule.wrappedValue.calendar(fallback: model.calendar) }
    private var date: Binding<Date> { Binding(get: { OccurrenceEngine(calendar: scheduleCalendar).date(rule.wrappedValue.start, time: rule.wrappedValue.time ?? model.preferences.defaultReminderTime ?? DayTime(hour: 9)) ?? model.now }, set: { value in
        rule.wrappedValue.useCalendarTiming()
        rule.wrappedValue.start = CivilDate(value, calendar: scheduleCalendar)
        rule.wrappedValue.monthDay = rule.wrappedValue.start.day; rule.wrappedValue.month = rule.wrappedValue.start.month
        if rule.wrappedValue.time != nil { rule.wrappedValue.time = DayTime(hour: scheduleCalendar.component(.hour, from: value), minute: scheduleCalendar.component(.minute, from: value)) }
    }) }
    var body: some View {
        NavigationStack {
            Form {
                Section { Toggle("安排日期", isOn: enabled) } footer: { Text("不设日期时，可以保留为长期待办或随手记。") }
                if card.schedule != nil {
                    Section("日期与时间") {
                        DatePicker("日期", selection: date, displayedComponents: .date)
                        Toggle("指定提醒时间", isOn: Binding(get: { card.schedule?.time != nil }, set: { value in card.schedule?.useCalendarTiming(); card.schedule?.time = value ? (model.preferences.defaultReminderTime ?? DayTime(hour: 9)) : nil; if !value { card.reminders.isEnabled = false } }))
                        if card.schedule?.time != nil { DatePicker("时间", selection: date, displayedComponents: .hourAndMinute) }
                    }
                    Section("重复规则") {
                        Picker("重复", selection: rule.frequency) { ForEach(RepeatFrequency.allCases, id: \.self) { Text($0.title) } }
                            .onChange(of: card.schedule?.frequency) { frequency in
                                rule.wrappedValue.useCalendarTiming()
                                if frequency == .weekly && rule.wrappedValue.weekdays.isEmpty { rule.wrappedValue.weekdays = [scheduleCalendar.component(.weekday, from: date.wrappedValue)] }
                            }
                        if card.schedule?.frequency != .never {
                            Stepper("每 \(rule.wrappedValue.interval) \(unit)", value: rule.interval, in: 1...99)
                            if card.schedule?.frequency == .weekly {
                                ForEach([2,3,4,5,6,7,1], id: \.self) { day in
                                    Toggle(["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"][day], isOn: Binding(get: { rule.wrappedValue.weekdays.contains(day) }, set: { value in if value { rule.wrappedValue.weekdays.insert(day) } else { rule.wrappedValue.weekdays.remove(day) } }))
                                }
                                Text("星期规则不包含法定节假日或调休。需要法定工作日时，请逐日确认日期。").font(.footnote).foregroundColor(Paper.secondary)
                            }
                            if [.monthly, .yearly].contains(card.schedule?.frequency ?? .never) {
                                Stepper("第 \(rule.wrappedValue.monthDay) 日", value: rule.monthDay, in: 1...31)
                                if card.schedule?.frequency == .yearly { Stepper("\(rule.wrappedValue.month) 月", value: rule.month, in: 1...12) }
                                if rule.wrappedValue.monthDay > 28 { Picker("没有这一天时", selection: rule.missingDatePolicy) { ForEach(MissingDatePolicy.allCases, id: \.self) { Text($0.title) } } }
                            }
                            Toggle("设置结束日期", isOn: Binding(get: { rule.wrappedValue.end != nil }, set: { rule.wrappedValue.end = $0 ? CivilDate(scheduleCalendar.date(byAdding: .year, value: 1, to: date.wrappedValue)!, calendar: scheduleCalendar) : nil }))
                            if rule.wrappedValue.end != nil {
                                DatePicker("结束日期", selection: Binding(get: { OccurrenceEngine(calendar: scheduleCalendar).date(rule.wrappedValue.end!, time: DayTime(hour: 0)) ?? model.now }, set: { rule.wrappedValue.end = CivilDate($0, calendar: scheduleCalendar) }), displayedComponents: .date)
                            }
                        }
                    }
                    Section("时区与截止") {
                        Picker("时区语义", selection: rule.timeZoneMode) { Text("随当地时区").tag(TimeZoneMode.floating); Text("固定时区").tag(TimeZoneMode.fixed); if rule.wrappedValue.absoluteInstant != nil { Text("固定时长").tag(TimeZoneMode.elapsed) } }
                        if rule.wrappedValue.timeZoneMode == .fixed {
                            Picker("固定时区", selection: rule.timeZoneIdentifier) { ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) } }
                        }
                        Toggle("另设完成截止", isOn: Binding(get: { rule.wrappedValue.dueAt != nil }, set: { rule.wrappedValue.dueAt = $0 ? date.wrappedValue : nil }))
                        if rule.wrappedValue.dueAt != nil { DatePicker("截止时间", selection: Binding(get: { rule.wrappedValue.dueAt ?? model.now }, set: { rule.wrappedValue.dueAt = $0 })) }
                    }
                    Section("接下来的安排") {
                        ForEach(preview, id: \.id) { occurrence in if let date = occurrence.plannedAt { Text(date.formatted(date: .abbreviated, time: card.schedule?.time == nil ? .omitted : .shortened)) } }
                        if preview.isEmpty { Text("当前规则没有可预览的日期，请检查日期与重复条件。").foregroundColor(Paper.secondary) }
                    }
                }
                if let error { Section { PaperErrorBanner(message: error) } }
            }.environment(\.timeZone, scheduleCalendar.timeZone).scrollContentBackground(.hidden).background(Paper.background).navigationTitle("日期与重复").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { do { try card.schedule?.validate(); dismiss() } catch { self.error = error.localizedDescription } } } }
        }
    }
    private var unit: String { switch card.schedule?.frequency { case .daily: return "天"; case .weekly: return "周"; case .monthly: return "个月"; case .yearly: return "年"; default: return "次" } }
    private var preview: [Occurrence] {
        let engine = OccurrenceEngine(calendar: model.calendar)
        return Array(engine.occurrences(for: card, in: DateInterval(start: model.now, end: model.calendar.date(byAdding: .year, value: 9, to: model.now)!), limit: 3).prefix(3))
    }
}

struct ReminderEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var card: Card
    @State private var editingNode: ReminderNodeSelection?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section { Toggle("开启提醒", isOn: $card.reminders.isEnabled) } footer: { Text("保存卡片后再请求相应权限。关闭提醒不会删除日程。") }
                if card.reminders.isEnabled {
                    Section("提醒方式") {
                        Picker("方式", selection: $card.reminders.channel) {
                            Text("普通通知").tag(ReminderChannel.notification)
                            if model.systemCapabilities.alarms.isSupported { Text("系统闹钟").tag(ReminderChannel.alarm) }
                            else if card.reminders.channel == .alarm { Text("系统闹钟（暂不可用）").tag(ReminderChannel.alarm) }
                        }
                        Text(card.reminders.channel == .notification ? "普通通知受系统静音和专注模式影响。点开到点后的提醒，可完成待办、稍后提醒或更改时间。" : "停止响铃不会完成待办。请同时允许通知，以便收到完成确认，并选择已完成、稍后提醒或更改时间。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                    nodeSection(followUp: false)
                    nodeSection(followUp: true)
                    if let error { PaperErrorBanner(message: error).accessibilityIdentifier("reminderValidationError") }

                }
                if #available(iOS 16.1, *), !card.reminders.isEnabled || card.reminders.channel != .alarm {
                    Section("锁屏与灵动岛") {
                        Toggle("显示待办卡片", isOn: $card.reminders.enablesLiveActivity).accessibilityIdentifier("liveActivityToggle")
                        if #available(iOS 26.0, *), card.reminders.enablesLiveActivity, LiveActivityService.hasClockTime(card) {
                            Toggle("提前 30 分钟再显示", isOn: $card.reminders.scheduledLiveActivity).accessibilityIdentifier("scheduledLiveActivityToggle")
                        }
                        Text(card.reminders.scheduledLiveActivity && LiveActivityService.hasClockTime(card) ? "保存后预约显示；距安排不足 30 分钟时立即显示。" : "保存后在锁屏显示这件待办，无需开启普通通知。")
                            .font(.footnote).foregroundColor(Paper.secondary)
                        Text("首次使用时，请允许拾日显示“实时活动”。卡片停止显示后，可以在提醒状态中重新开启。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                }
            }.scrollContentBackground(.hidden).background(Paper.background).navigationTitle("提醒方式").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        do { if card.reminders.isEnabled { try card.reminders.validate() }; dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("reminderDone")
                } }
                .sheet(item: $editingNode) { selection in ReminderNodeEditor(policy: $card.reminders, selection: selection) }
        }
    }
    private func nodeSection(followUp: Bool) -> some View {
        let values = Array(Set(followUp ? card.reminders.followUpMinutes : card.reminders.advanceMinutes)).sorted { followUp ? $0 < $1 : $0 > $1 }
        let limit = followUp ? ReminderPolicy.followUpLimit : ReminderPolicy.advanceLimit
        let prefix = followUp ? "followUp" : "advance"
        return Section {
            ForEach(values, id: \.self) { value in
                HStack {
                    Button { error = nil; editingNode = ReminderNodeSelection(followUp: followUp, minutes: value) } label: {
                        HStack {
                            Text(ReminderPolicy.nodeLabel(value, followUp: followUp)).foregroundColor(Paper.ink)
                            Spacer()
                            Image(systemName: "pencil").foregroundColor(Paper.secondary)
                        }
                    }.buttonStyle(.borderless).accessibilityIdentifier("\(prefix)Node_\(value)")
                    Button(role: .destructive) {
                        if followUp { card.reminders.followUpMinutes.removeAll { $0 == value } }
                        else { card.reminders.advanceMinutes.removeAll { $0 == value } }
                        error = nil
                    } label: { Image(systemName: "minus.circle").frame(width: 36, height: 36) }
                        .buttonStyle(.borderless).accessibilityLabel("删除" + ReminderPolicy.nodeLabel(value, followUp: followUp))
                        .accessibilityIdentifier("delete_\(prefix)_\(value)")
                }
            }
            if values.isEmpty { Text(followUp ? "到点后不再提醒" : "尚未选择提醒时间").foregroundColor(Paper.secondary) }
            Button { error = nil; editingNode = ReminderNodeSelection(followUp: followUp, minutes: nil) } label: {
                Label("添加提醒时间", systemImage: "plus.circle")
            }.disabled(values.count >= limit).accessibilityIdentifier("add_\(prefix)")
            Menu("常用时间") {
                ForEach(followUp ? [5,15,30] : [0,10,30,60,1440], id: \.self) { value in
                    Button(ReminderPolicy.nodeLabel(value, followUp: followUp)) {
                        do { try card.reminders.setNode(value, followUp: followUp); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(values.contains(value) || values.count >= limit)
                }
            }.accessibilityIdentifier("presets_\(prefix)")
        } header: { Text("\(followUp ? "到点后再提醒" : "提醒时间") · \(values.count)/\(limit)") }
          footer: { Text(followUp ? "最多添加 3 次，最晚在安排时间之后 24 小时提醒。完成后取消剩余提醒。" : "最多添加 6 次提醒，可提前 365 天。相同时间只提醒一次，已过去的提醒不会补发。") }
    }
}

private struct ReminderNodeSelection: Identifiable {
    let id = UUID()
    var followUp: Bool
    var minutes: Int?
}

private struct ReminderNodeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var policy: ReminderPolicy
    let selection: ReminderNodeSelection
    @State private var amount: String
    @State private var unit: Int
    @State private var error: String?
    init(policy: Binding<ReminderPolicy>, selection: ReminderNodeSelection) {
        _policy = policy; self.selection = selection
        let value = selection.minutes ?? (selection.followUp ? 45 : 120)
        let unit = value > 0 && value % 1440 == 0 ? 1440 : (value > 0 && value % 60 == 0 ? 60 : 1)
        _unit = State(initialValue: unit); _amount = State(initialValue: String(value / unit))
    }
    private var minutes: Int? {
        guard let value = Int(amount.trimmingCharacters(in: .whitespaces)), value >= 0,
              value <= ReminderPolicy.maximumAdvanceMinutes / unit else { return nil }
        return value * unit
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(selection.followUp ? "在安排时间之后" : "在安排时间之前") {
                    TextField("时长", text: $amount).keyboardType(.numberPad).accessibilityIdentifier("nodeAmount")
                    Picker("单位", selection: $unit) {
                        Text("分钟").tag(1); Text("小时").tag(60); Text("天").tag(1440)
                    }.pickerStyle(.segmented).accessibilityIdentifier("nodeUnit")
                    if let minutes {
                        Text(ReminderPolicy.nodeLabel(minutes, followUp: selection.followUp)).foregroundColor(Paper.accent)
                        let existing = selection.followUp ? policy.followUpMinutes : policy.advanceMinutes
                        if existing.contains(minutes) && minutes != selection.minutes { Text("这个时间已添加，只会提醒一次。").font(.footnote).foregroundColor(Paper.secondary) }
                    }
                }
                Section { Text(selection.followUp ? "请输入 1 分钟至 24 小时，最多添加 3 次提醒。" : "输入 0 表示准时提醒；最长可提前 365 天，最多添加 6 次。").font(.footnote).foregroundColor(Paper.secondary) }
                if let error { PaperErrorBanner(message: error).accessibilityIdentifier("nodeError") }
            }.scrollContentBackground(.hidden).background(Paper.background)
                .navigationTitle(selection.minutes == nil ? "添加提醒时间" : "编辑提醒时间").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("cancelReminderNode") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            guard let minutes else { error = "请输入有效的整数时长"; return }
                            do { try policy.setNode(minutes, followUp: selection.followUp, replacing: selection.minutes); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("saveReminderNode")
                    }
                }
        }
    }
}
