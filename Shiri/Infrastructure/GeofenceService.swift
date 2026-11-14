@preconcurrency import CoreLocation
import UserNotifications
import ShiriCore

@MainActor
final class GeofenceService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var messages: [SchedulingIssue] = []
    @Published private(set) var authorization = CLAuthorizationStatus.notDetermined
    private let manager = CLLocationManager()
    private var repository: ShiriRepository?
    private var repositoryPaused = false
    private var triggerTasks: [UUID: Task<Void, Never>] = [:]
    private var active: [PlannedGeofence] = []
    private var library = LibrarySnapshot()
    private var preferences = AppPreferences()
    override init() { super.init(); manager.delegate = self; authorization = manager.authorizationStatus }
    func suspend() {
        for region in manager.monitoredRegions where region.identifier.hasPrefix("ny.place.") { manager.stopMonitoring(for: region) }
        active = []; repository = nil; library = LibrarySnapshot()
    }
    /// Release only in-process storage references; registered system regions remain intact.
    func releaseRepository() async {
        repositoryPaused = true
        let pending = Array(triggerTasks.values)
        for task in pending { await task.value }
        repository = nil; active = []; library = LibrarySnapshot()
    }
    private func trackTrigger(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        triggerTasks[id] = Task { [weak self] in
            defer { self?.triggerTasks[id] = nil }
            await operation()
        }
    }
    func requestBackgroundPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }
    func registrationStatus(cardID: UUID) -> String {
        if let issue = messages.first(where: { $0.cardID == cardID }) { return issue.message }
        guard let target = active.first(where: { $0.cardIDs.contains(cardID) }) else { return "地点提醒尚未开启" }
        return manager.monitoredRegions.contains(where: { $0.identifier == target.id }) ? "地点提醒已开启 · 到达或离开时提醒" : "正在开启地点提醒"
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if let repository, !repositoryPaused {
            trackTrigger { [self] in
                guard !repositoryPaused else { return }
                await reconcile(library: library, preferences: preferences, repository: repository, now: Date())
            }
        }
    }
    func reconcile(library: LibrarySnapshot, preferences: AppPreferences, repository: ShiriRepository, now: Date) async {
        repositoryPaused = false
        self.repository = repository; self.library = library; self.preferences = preferences
        var cards = library.cards.filter { card in
            card.place != nil && card.reminders.isEnabled && card.lifecycle == .active && card.recurrenceClosedAt == nil &&
                (card.scope == .local || preferences.remindsForPrivateCloudCards || preferences.enabledCloudCardIDs.contains(card.id))
        }
        cards.removeAll { card in
            let occurrence = OccurrenceEngine(calendar: .current).relevantOccurrence(for: card, at: now, overrides: library.overrides)
            return occurrence.map { EventReducer.state(events: library.events(for: $0.id)) != .pending || library.personalStates[$0.id]?.isStopped == true } ?? false
        }
        let plan = GeofencePlanner.plan(cards: cards, now: now)
        messages = plan.deferred.map { SchedulingIssue(cardID: $0, message: "地点提醒数量已达上限，请关闭部分地点提醒后重试") }
        let permitted = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) && manager.authorizationStatus == .authorizedAlways
        if !permitted { messages += plan.active.flatMap(\.cardIDs).map { SchedulingIssue(cardID: $0, message: "后台地点提醒需要始终允许定位") } }
        if manager.accuracyAuthorization == .reducedAccuracy { messages += plan.active.flatMap(\.cardIDs).map { SchedulingIssue(cardID: $0, message: "精确位置已关闭，地点触发可能更迟或不可用") } }
        active = permitted ? plan.active : []
        let desiredIDs = Set(active.map(\.id))
        for region in manager.monitoredRegions where region.identifier.hasPrefix("ny.place.") && !desiredIDs.contains(region.identifier) { manager.stopMonitoring(for: region) }
        let monitoredIDs = Set(manager.monitoredRegions.map(\.identifier))
        for target in active {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: target.place.latitude, longitude: target.place.longitude), radius: min(target.place.radiusMeters, manager.maximumRegionMonitoringDistance), identifier: target.id)
            region.notifyOnEntry = true; region.notifyOnExit = true
            if !monitoredIDs.contains(target.id) { manager.startMonitoring(for: region) }
            manager.requestState(for: region)
        }
    }
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { trigger(region, transition: .enter, initial: false) }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { trigger(region, transition: .exit, initial: false) }
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        if state == .inside { trigger(region, transition: .enter, initial: true) }
    }
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        for id in active.first(where: { $0.id == region?.identifier })?.cardIDs ?? [] { messages.append(SchedulingIssue(cardID: id, message: "地点提醒未能开启：\(error.localizedDescription)")) }
    }
    private func trigger(_ region: CLRegion, transition: PlaceTrigger, initial: Bool) {
        guard !repositoryPaused else { return }
        guard let repository else {
            trackTrigger { [self] in
                do {
                    let repo = try await ExtensionStore.open(author: "LocationWake")
                    repository = repo
                    preferences = try await repo.deviceValue(AppPreferences.self, key: "preferences") ?? AppPreferences()
                    trigger(region, transition: transition, initial: initial)
                } catch { messages.append(SchedulingIssue(cardID: UUID(), message: error.localizedDescription)) }
            }
            return
        }
        trackTrigger { [self] in
            do {
                let current = try await repository.library(); let now = Date()
                let linked = current.cards.filter { $0.lifecycle == .active && $0.recurrenceClosedAt == nil && $0.reminders.isEnabled && $0.place.map { "ny.place." + $0.geofenceKey == region.identifier } == true }
                for card in linked {
                    guard card.scope == .local || preferences.remindsForPrivateCloudCards || preferences.enabledCloudCardIDs.contains(card.id) else { continue }
                    guard let place = card.place else { continue }
                    let initialKey = "place-initial/\(place.id)"
                    if initial {
                        if place.alreadyInsidePolicy == .ask { messages.append(SchedulingIssue(cardID: card.id, message: "你已在地点范围内，请选择现在提醒或下次进入")); continue }
                        guard place.alreadyInsidePolicy == .notifyNow, try await repository.deviceValue(Bool.self, key: initialKey) != true else { continue }
                    }
                    let key = "place-cooldown/\(card.id)/\(place.id)"
                    let previous = try await repository.deviceValue(Date.self, key: key)
                    guard GeofencePlanner.shouldNotify(place: place, transition: transition, now: now, lastTrigger: previous), await NotificationAdapter.shared.allowed() else { continue }
                    let occurrence = OccurrenceEngine(calendar: .current).relevantOccurrence(for: card, at: now, overrides: current.overrides)
                    guard let occurrence, EventReducer.state(events: current.events(for: occurrence.id)) == .pending, current.personalStates[occurrence.id]?.isStopped != true else { continue }
                    let content = UNMutableNotificationContent(); content.title = preferences.notificationPrivacy == .hidden ? (transition == .enter ? "到达了提醒地点" : "离开了提醒地点") : card.title
                    content.body = preferences.notificationPrivacy == .hidden ? "打开拾日查看" : "\(transition.title) · \(place.name)"; content.sound = .default; content.categoryIdentifier = NotificationAdapter.category
                    content.userInfo = ["nianyiPayload": try ValueCodec.encode(NotificationPayload(card: card, occurrence: occurrence, scope: .occurrence, offset: 0))]
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ny.location.\(occurrence.id)", content: content, trigger: nil))
                    try await repository.setDeviceValue(now, key: key)
                    let state = current.personalStates[occurrence.id] ?? PersonalReminderState(occurrenceID: occurrence.id, now: now)
                    try await repository.savePersonalState(state, event: PersonalReminderEvent(operationID: UUID(), occurrenceID: occurrence.id, kind: .locationTriggered, now: now))
                    if initial { try await repository.setDeviceValue(true, key: initialKey) }
                }
            } catch { messages.append(SchedulingIssue(cardID: UUID(), message: error.localizedDescription)) }
        }
    }
}
