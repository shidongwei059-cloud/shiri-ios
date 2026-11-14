import SwiftUI
import ShiriCore

struct BirthdayEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var card: Card
    var onSave: (() -> Void)? = nil
    @State private var rule = BirthdayRule()
    @State private var year = ""
    @State private var error: String?
    @State private var reminderEnabled = false
    @State private var showsDates = false
    @State private var showsReminder = false
    @State private var showsAppearance = false
    @State private var appearanceDraft = CardDraft(card: Card(title: "", now: Date()))
    @Environment(\.dynamicTypeSize) private var typeSize
    private var artwork: String? { var preview = card; preview.birthday = rule; return CardArtwork.asset(for: preview) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PaperNavigationBar(title: rule.occasion == .anniversary ? "纪念日提醒" : "生日提醒", action: { dismiss() }) { EmptyView() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(rule.name.isEmpty ? (rule.occasion == .anniversary ? "记住一个纪念日" : "记住一个生日") : (rule.occasion == .anniversary ? rule.name : "\(rule.name)的生日")).font(Paper.title(29)).foregroundColor(Paper.cardInk)
                                Text("记住每个值得庆祝的日子").font(Paper.text(15)).foregroundColor(Paper.cardSecondary)
                            }
                            Spacer(minLength: 0)
                            if !typeSize.isAccessibilitySize, let artwork { Image(artwork).resizable().scaledToFit().frame(width: 96, height: 112).saturation(0.78).blendMode(.multiply).opacity(0.8).accessibilityHidden(true) }
                        }.padding(.horizontal, 18).frame(minHeight: 116).paperCard(Paper.card(.blush), radius: 15)
                        HStack {
                            Text(rule.occasion == .anniversary ? "名称" : "称呼").font(Paper.title(16)); Spacer()
                            TextField(rule.occasion == .anniversary ? "如相识纪念日" : "如妈妈", text: $rule.name).font(Paper.text(17)).multilineTextAlignment(.trailing).accessibilityIdentifier("birthdayName")
                            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(Paper.secondary)
                        }.frame(minHeight: 43).padding(.horizontal, 5)
                        Divider()
                        Text(rule.occasion == .anniversary ? "纪念日期" : "生日日期").font(Paper.title(18)).padding(.top, 1).padding(.horizontal, 5)
                        HStack(spacing: 0) {
                            ForEach(BirthdayCalendar.allCases, id: \.self) { value in
                                Button { rule.calendar = value } label: {
                                    Text(value.title).font(Paper.text(18)).frame(maxWidth: .infinity).frame(minHeight: 37)
                                        .foregroundColor(rule.calendar == value ? .white : Paper.ink)
                                        .background(rule.calendar == value ? Paper.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }.background(Paper.separator.opacity(0.4), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            Button { showsDates = true } label: { ComposerRow(symbol: "calendar", title: "\(rule.month)月\(rule.day)日", value: "") }
                            Divider()
                            Button { showsDates = true } label: { ComposerRow(symbol: "arrow.triangle.2.circlepath", title: "重复", value: rule.repeatsYearly ? "每年" : "仅一次") }
                            Divider()
                        }
                        Text("提醒安排").font(Paper.title(18)).padding(.horizontal, 5).padding(.top, 8)
                        VStack(spacing: 0) {
                            Button { showsReminder = true } label: { ComposerRow(symbol: "bell", title: "提前提醒", value: reminderEnabled && !rule.advanceDays.isEmpty ? "提前 \(rule.advanceDays.sorted().map(String.init).joined(separator: "、")) 天 · \(rule.advanceTime?.display ?? "待选择")" : "不提醒") }
                            Divider()
                            Button { showsReminder = true } label: { ComposerRow(symbol: "bell", title: "当天提醒", value: reminderEnabled ? (rule.dayTime?.display ?? "不提醒") : "不提醒") }
                            Divider()
                        }
                        Button { appearanceDraft = CardDraft(card: card); showsAppearance = true } label: {
                            HStack(spacing: 12) { Image(systemName: "paintpalette").font(.system(size: 22, weight: .light)); Text("卡片外观").font(Paper.text(16)); Spacer(minLength: 2); PaperSwatches(selection: card.appearance.theme, colors: [.blush, .butter, .sage]); Divider().frame(height: 24); Text("更换").font(Paper.text(14)); Image(systemName: "chevron.right").font(.system(size: 13)) }
                                .foregroundColor(Paper.ink).padding(.horizontal, 10).frame(minHeight: 48)
                        }.padding(.top, 5)
                        OccasionDateSummary(card: previewCard)
                        Text("保存后，可在详情中选择准备事项并留下往年记录。").font(.footnote).foregroundColor(Paper.secondary)
                        if let error { PaperErrorBanner(message: error) }
                    }.padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 12)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("日期和提醒时间都可以随时调整").font(Paper.text(12)).foregroundColor(Paper.secondary).padding(.leading, 4)
                    Button(rule.occasion == .anniversary ? "保存纪念日提醒" : "保存生日提醒") { save() }.buttonStyle(PaperPrimaryButton()).accessibilityIdentifier("saveBirthdayRule")
                }.padding(.horizontal, 16).padding(.bottom, 9).padding(.top, 7)
            }.background { PaperSurface().ignoresSafeArea() }.foregroundColor(Paper.ink).toolbar(.hidden, for: .navigationBar)
                .onAppear { if let birthday = card.birthday { rule = birthday; year = birthday.birthYear.map(String.init) ?? ""; reminderEnabled = card.reminders.isEnabled } }
                .sheet(isPresented: $showsDates) { dateSettings }
                .sheet(isPresented: $showsReminder) { reminderSettings }
                .sheet(isPresented: $showsAppearance, onDismiss: { card.appearance = appearanceDraft.card.appearance }) { AppearanceEditor(draft: $appearanceDraft) }
        }
    }
    private var previewCard: Card {
        var preview = card; preview.birthday = rule; preview.schedule = nil; preview.reminders.isEnabled = reminderEnabled
        return preview
    }
    private var dateSettings: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("日子类型", selection: Binding(get: { rule.occasion ?? .birthday }, set: { rule.occasion = $0 })) { ForEach(OccasionKind.allCases, id: \.self) { Text($0.title) } }
                    Picker("历法", selection: $rule.calendar) { Text("请选择").tag(BirthdayCalendar?.none); ForEach(BirthdayCalendar.allCases, id: \.self) { Text($0.title).tag(Optional($0)) } }
                    Picker("月", selection: $rule.month) { ForEach(1...12, id: \.self) { Text("\($0) 月") } }
                    Picker("日", selection: $rule.day) { ForEach(1...(rule.calendar == .lunar ? 30 : 31), id: \.self) { Text("\($0) 日") } }
                    if rule.calendar == .lunar { Toggle("闰月生日", isOn: $rule.isLeapMonth) }
                    TextField("出生年份（可不填）", text: $year).keyboardType(.numberPad)
                }
                Section("重复与特殊日期") {
                    Toggle("每年重复", isOn: $rule.repeatsYearly)
                    if !rule.repeatsYearly { DatePicker("本次提醒日期", selection: Binding(get: { rule.oneTimeDate.flatMap { OccurrenceEngine(calendar: model.calendar).date($0, time: DayTime(hour: 0)) } ?? model.now }, set: { rule.oneTimeDate = CivilDate($0, calendar: model.calendar) }), displayedComponents: .date) }
                    if (rule.calendar == .lunar && rule.day == 30) || (rule.calendar == .gregorian && rule.month == 2 && rule.day == 29) { Picker("没有这一天时", selection: $rule.missingDatePolicy) { ForEach(MissingDatePolicy.allCases, id: \.self) { Text($0.title) } } }
                    if rule.calendar == .lunar && rule.isLeapMonth { Picker("没有对应闰月时", selection: $rule.leapMonthPolicy) { ForEach(LeapMonthPolicy.allCases, id: \.self) { Text($0.title) } } }
                }
                Section("接下来三个生日") {
                    ForEach(BirthdayCalendarEngine(calendar: model.calendar).nextDates(for: rule, after: model.now), id: \.self) { Text($0.formatted(date: .long, time: rule.dayTime == nil ? .omitted : .shortened)) }
                }
            }.navigationTitle("生日日期").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsDates = false } } }
        }
    }
    private var reminderSettings: some View {
        NavigationStack {
            Form {
                Toggle("开启生日提醒", isOn: $reminderEnabled)
                if reminderEnabled {
                    Toggle("当天提醒", isOn: Binding(get: { rule.dayTime != nil }, set: { rule.dayTime = $0 ? DayTime(hour: 9) : nil }))
                    if rule.dayTime != nil { DatePicker("当天时间", selection: timeBinding(advance: false), displayedComponents: .hourAndMinute) }
                    ForEach([1,3,7], id: \.self) { days in Toggle("提前 \(days) 天", isOn: Binding(get: { rule.advanceDays.contains(days) }, set: { enabled in
                        if enabled { rule.advanceDays.append(days) } else { rule.advanceDays.removeAll { $0 == days } }
                    })) }
                    if !rule.advanceDays.isEmpty {
                        Toggle("指定提前提醒时刻", isOn: Binding(get: { rule.advanceTime != nil }, set: { rule.advanceTime = $0 ? DayTime(hour: 9) : nil }))
                        if rule.advanceTime != nil { DatePicker("提前提醒时间", selection: timeBinding(advance: true), displayedComponents: .hourAndMinute) }
                    }
                }
            }.navigationTitle("提醒安排").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsReminder = false } } }
        }
    }
    private func timeBinding(advance: Bool) -> Binding<Date> {
        Binding(get: { OccurrenceEngine(calendar: model.calendar).date(CivilDate(model.now, calendar: model.calendar), time: (advance ? rule.advanceTime : rule.dayTime) ?? DayTime(hour: 9)) ?? model.now }, set: { date in
            let time = DayTime(hour: model.calendar.component(.hour, from: date), minute: model.calendar.component(.minute, from: date))
            if advance { rule.advanceTime = time } else { rule.dayTime = time }
        })
    }
    private func save() {
        do {
            if !year.isEmpty && Int(year) == nil { throw ShiriError.validation("出生年份应为四位数字，也可以留空") }
            rule.birthYear = year.isEmpty ? nil : Int(year)
            if !rule.repeatsYearly && rule.oneTimeDate == nil { throw ShiriError.validation("请选择本次提醒的具体日期") }
            try rule.validate()
            if reminderEnabled && rule.dayTime == nil && rule.advanceDays.isEmpty { throw ShiriError.validation("请选择当天或提前提醒的时刻") }
            card.birthday = rule; card.kind = .note; card.schedule = nil
            card.title = rule.occasion == .anniversary ? rule.name : "\(rule.name)的生日"; card.category = (rule.occasion ?? .birthday).title; card.reminders.isEnabled = reminderEnabled
            card.appearance.applyRecommendation(.recommended(for: card.title, kind: .note, birthday: true)); dismiss(); onSave?()
        } catch { self.error = error.localizedDescription }
    }
}
