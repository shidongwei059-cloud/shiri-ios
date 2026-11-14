import SwiftUI
import MapKit
import CoreLocation
import ShiriCore

struct PlaceEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var card: Card
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.4, longitude: 108.9), span: MKCoordinateSpan(latitudeDelta: 25, longitudeDelta: 25))
    @State private var selected: PlaceRule?
    @State private var busy = false
    @State private var error: String?
    @State private var trigger = PlaceTrigger.enter
    @State private var radius = 200.0
    @State private var name = ""
    @State private var insidePolicy = AlreadyInsidePolicy.ask
    @State private var starts = Date()
    @State private var ends = Date().addingTimeInterval(86_400)
    @State private var limitsTime = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PaperPageHeader(title: "路过时，想起它", subtitle: "选一个地点，按到达或离开来提醒。", symbol: "mappin.and.ellipse")
                    HStack { TextField("搜索地点或地址", text: $query).submitLabel(.search).onSubmit { search() }; Button("搜索") { search() }.disabled(query.isEmpty || busy) }.padding(15).background(Paper.surface, in: RoundedRectangle(cornerRadius: 14))
                    if busy { ProgressView("正在搜索…") }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        Button { select(item) } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(item.name ?? "地图地点").foregroundColor(Paper.ink); Text(item.placemark.title ?? "").font(.caption).foregroundColor(Paper.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Paper.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    ZStack { Map(coordinateRegion: $region).frame(height: 220); Image(systemName: "mappin.circle.fill").font(.title).foregroundColor(Paper.accent).allowsHitTesting(false) }.clipShape(RoundedRectangle(cornerRadius: 17)).accessibilityLabel("地点地图，移动后可选择地图中心")
                    Button("使用地图中心") {
                        selected = PlaceRule(name: name.isEmpty ? "地图所选地点" : name, address: "手动选择的地图位置", latitude: region.center.latitude, longitude: region.center.longitude, radiusMeters: radius, trigger: trigger)
                        name = selected!.name
                    }.font(.subheadline)
                    if selected != nil {
                        PaperFieldSection("地点规则") {
                            TextField("给地点起个名字，如公司", text: $name)
                            Picker("什么时候", selection: $trigger) { ForEach(PlaceTrigger.allCases, id: \.self) { Text($0.title) } }.pickerStyle(.segmented)
                            Text("范围约 \(Int(radius)) 米").font(.subheadline)
                            Slider(value: $radius, in: 100...2_000, step: 100)
                            Picker("如果已经在地点内", selection: $insidePolicy) {
                                Text("请先选择").tag(AlreadyInsidePolicy.ask)
                                Text("现在提醒一次").tag(AlreadyInsidePolicy.notifyNow)
                                Text("等下次进入再提醒").tag(AlreadyInsidePolicy.nextEntry)
                            }
                            Toggle("限制生效时段", isOn: $limitsTime)
                            if limitsTime { DatePicker("开始", selection: $starts); DatePicker("结束", selection: $ends) }
                        }
                        Text("地点提醒需要定位权限，可能因信号较弱或省电设置而延迟。").font(.footnote).foregroundColor(Paper.secondary)
                    }
                    if let error { PaperErrorBanner(message: error) }
                    GeofencePermissionView(service: model.geofences)
                    Button("用这个地点提醒") { save() }.buttonStyle(PaperPrimaryButton()).disabled(selected == nil)
                    if card.place != nil { Button("移除地点提醒", role: .destructive) { card.place = nil; if card.schedule == nil && card.birthday == nil { card.reminders.isEnabled = false }; dismiss() }.frame(maxWidth: .infinity) }
                }.padding(18)
            }.background(Paper.background).navigationTitle("地点提醒").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onAppear {
                    if let place = card.place { selected = place; name = place.name; trigger = place.trigger; radius = place.radiusMeters; insidePolicy = place.alreadyInsidePolicy; limitsTime = place.startAt != nil || place.endAt != nil; starts = place.startAt ?? Date(); ends = place.endAt ?? Date().addingTimeInterval(86_400); region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)) }
                }
        }
    }
    private func search() {
        busy = true; error = nil
        Task {
            let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
            if selected != nil { request.region = region }
            do { results = try await MKLocalSearch(request: request).start().mapItems; if results.isEmpty { error = "没有找到这个地点，可以换个名称或在地图上选择。" } }
            catch { self.error = "地图搜索暂不可用。可以重试，或手动选择地图中心。" }
            busy = false
        }
    }
    private func select(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        name = item.name ?? "地图地点"
        selected = PlaceRule(name: name, address: item.placemark.title ?? name, latitude: coordinate.latitude, longitude: coordinate.longitude, radiusMeters: radius, trigger: trigger)
        region = MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)); results = []
    }
    private func save() {
        guard var place = selected else { return }
        place.name = name; place.radiusMeters = radius; place.trigger = trigger; place.alreadyInsidePolicy = insidePolicy
        place.startAt = limitsTime ? starts : nil; place.endAt = limitsTime ? ends : nil
        do {
            try place.validate()
            if trigger == .enter && insidePolicy == .ask { throw ShiriError.validation("请选择已经在地点内时如何处理") }
            card.place = place; card.reminders.isEnabled = true; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct GeofencePermissionView: View {
    @ObservedObject var service: GeofenceService
    var body: some View {
        PaperFieldSection("此设备的定位权限") {
            Text(service.authorization == .authorizedAlways ? "已允许后台地点提醒" : service.authorization == .authorizedWhenInUse ? "仅使用期间允许，后台提醒还需要始终允许定位" : service.authorization == .notDetermined ? "尚未请求定位权限" : "定位未允许，可以在系统设置中调整")
                .font(.footnote).foregroundColor(Paper.secondary)
            if service.authorization == .notDetermined || service.authorization == .authorizedWhenInUse { Button("允许后台地点提醒") { service.requestBackgroundPermission() } }
        }
    }
}
