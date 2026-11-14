import Foundation
import SwiftUI
import CoreData
import CloudKit
import WidgetKit
import UserNotifications
import ShiriCore

struct ReminderResponseRequest: Identifiable {
    let id = UUID()
    let payload: NotificationPayload
    let deliveredAt: Date
    var selectsNewTime = false
}
enum ReminderResponseAction { case complete, snooze, reschedule(Date) }

@MainActor
final class AppModel: ObservableObject {
    @Published var library = LibrarySnapshot()
    @Published var isLoading = true
    @Published var fatalError: String?
    @Published var message: String?
    @Published var lastFailureCode: String?
    @Published var systemCapabilities = DeviceCapabilitySnapshot()
    @Published var selectedTab = MainTab.today
    @Published var selectedCard: Card? {
        didSet {
            if selectedCard == nil || selectedCard?.id != oldValue?.id { selectedOccurrence = nil }
        }
    }
    @Published private(set) var selectedOccurrence: Occurrence?
    @Published var pendingMemory: MemoryCandidate?
    @Published var lastSavedMemory: Card?
    @Published var reminderResponse: ReminderResponseRequest?
    @Published var composer: CardDraft?
    @Published var preferences = AppPreferences()
    @Published var shareSessions: [ShareSession] = []
    @Published var receivedCloudSessions: [ShareSession] = []
    @Published var pendingMigrations: [ScopeMigrationJournal] = []
    @Published var importPackage: SharePackage?
    @Published var reminderLedger: [ReminderLedgerEntry] = []
    @Published var reminderIssues: [SchedulingIssue] = []
    @Published var deferredReminders = 0
    @Published var reminderCoverageEnd: Date?
    @Published var startsWithSpeech = false
    @Published private(set) var pendingComposerInput: ComposerInputMode?
    @Published private(set) var pendingVoiceDraftID: UUID?
    private var isOpeningVoiceDraft = false
    private var externalComposerCardID: UUID?
    private var externalComposerMode: ComposerInputMode?
    var startsOccasionEditor = false
    let geofences = GeofenceService()
    let liveActivities = LiveActivityService()
    private var historyConsumer: PersistentHistoryConsumer?
    private var isRefreshing = false
    private var refreshRequested = false
    private var remoteRefreshRequested = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var timeObserver: NSObjectProtocol?
    @Published var cloudStatus = "尚未启用"
    @Published var isConnectingCloud = false
    private(set) var cloudCoordinator: CloudSharingCoordinator?
    private var cloudAccountKey: String?
    private var cloudAccountObserver: NSObjectProtocol?
    private var cloudEventObserver: NSObjectProtocol?
    private(set) var repository: ShiriRepository?
    private(set) var commands: CardCommands?
    private var started = false
    private var isStarting = false
    private var startupStoreToDetach: PersistenceController?
    private var remoteObserver: NSObjectProtocol?
    #if DEBUG
    var startsBirthdayEditor = false
    var startsEditor: String?
    private var fixedDate: Date?
    private var injectedStartupFailure = false
    private var refreshTestEffect: (@MainActor () async throws -> Void)?
    private(set) var completedRefreshPassesForTesting = 0
    #endif
    var now: Date {
        #if DEBUG
        if let fixedDate { return fixedDate }
        #endif
        return Date()
    }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c }
    @Published var projections: [CardProjection] = []
    @Published private(set) var snapshotRevision = 0
    private var lastRefreshDate: Date?
    private var lastRefreshCalendar: Calendar?
    nonisolated static func project(_ library: LibrarySnapshot, now: Date, calendar: Calendar) -> [CardProjection] {
        let engine = OccurrenceEngine(calendar: calendar)
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let groupedEvents = Dictionary(grouping: library.events, by: \.occurrenceID)
        let historic = Dictionary(grouping: library.occurrences, by: \.cardID)
        let overrides = Dictionary(grouping: library.overrides, by: \.cardID)
        return library.cards.map { card in
            let exceptions = overrides[card.id] ?? []
            let today = engine.occurrences(for: card, in: DateInterval(start: startOfDay, end: endOfDay), overrides: exceptions)
            let pending = today.first { EventReducer.state(events: groupedEvents[$0.id] ?? []) == .pending }
            // Resolve later candidates only when today's instance cannot answer the query.
            let occurrence = pending ?? today.last
                ?? engine.next(for: card, after: endOfDay, overrides: exceptions)
                ?? (card.schedule?.frequency == .never ? engine.relevantOccurrence(for: card, at: now, overrides: exceptions) : nil)
                ?? historic[card.id]?.sorted { ($0.plannedAt ?? .distantPast) < ($1.plannedAt ?? .distantPast) }.last
            return CardProjection(card: card, occurrence: occurrence, events: occurrence.map { groupedEvents[$0.id] ?? [] } ?? [], reminderState: occurrence.flatMap { library.personalStates[$0.id] }, hasConflict: library.conflicts[card.id] != nil)
        }
    }
    /// Date browsing keeps each occurrence, including two repetitions moved onto the same day.
    nonisolated static func projectDay(_ library: LibrarySnapshot, on date: Date, calendar: Calendar) -> [CardProjection] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let interval = DateInterval(start: start, end: end)
        let engine = OccurrenceEngine(calendar: calendar)
        let overridesByCard = Dictionary(grouping: library.overrides, by: \.cardID)
        let historicByCard = Dictionary(grouping: library.occurrences, by: \.cardID)
        let eventsByOccurrence = Dictionary(grouping: library.events, by: \.occurrenceID)
        return library.cards.filter { $0.lifecycle == .active }.flatMap { card -> [CardProjection] in
            guard !Task.isCancelled else { return [] }
            let overrides = overridesByCard[card.id] ?? []
            let overrideByID = Dictionary(overrides.map { ($0.occurrenceID, $0) }, uniquingKeysWith: { _, last in last })
            var occurrences = engine.occurrences(for: card, in: interval, overrides: overrides)
            var seenIDs = Set(occurrences.map(\.id))
            // Committed history still belongs to its original date after a series is edited.
            for var historic in historicByCard[card.id] ?? [] where !seenIDs.contains(historic.id) {
                if let override = overrideByID[historic.id], override.kind == .rescheduled, let moved = override.newDate {
                    historic.plannedAt = moved; historic.snapshot.plannedAt = moved
                }
                if let planned = historic.plannedAt, interval.containsHalfOpen(planned) {
                    occurrences.append(historic); seenIDs.insert(historic.id)
                }
            }
            if occurrences.isEmpty && card.schedule == nil && card.birthday == nil {
                return [CardProjection(card: card, occurrence: nil, hasConflict: library.conflicts[card.id] != nil)]
            }
            return occurrences.map { occurrence in
                var result = CardProjection(card: card, occurrence: occurrence, events: eventsByOccurrence[occurrence.id] ?? [], reminderState: library.personalStates[occurrence.id], hasConflict: library.conflicts[card.id] != nil)
                if overrideByID[occurrence.id]?.kind == .canceled { result.state = .canceled }
                else if overrideByID[occurrence.id]?.kind == .skipped && result.state == .pending { result.state = .skipped }
                return result
            }
        }
    }

    func openCard(_ projection: CardProjection) {
        openCard(projection.card, occurrence: projection.occurrence)
    }

    /// An explicit navigation action replaces the previous instance even for the same card.
    /// Saving edits can still update selectedCard directly to retain the current browsing context.
    func openCard(_ card: Card, occurrence: Occurrence? = nil) {
        selectedCard = card
        selectedOccurrence = occurrence?.cardID == card.id ? occurrence : nil
    }

    func detailProjection(cardID: UUID, occurrence: Occurrence? = nil) -> CardProjection? {
        guard let occurrence else { return projections.first { $0.id == cardID } }
        return Self.detailProjection(cardID: cardID, in: library, occurrence: occurrence, now: now, calendar: calendar)
    }

    nonisolated static func detailProjection(cardID: UUID, in library: LibrarySnapshot, occurrence: Occurrence, now: Date, calendar: Calendar) -> CardProjection? {
        guard let card = library.cards.first(where: { $0.id == cardID }) else { return nil }
        guard occurrence.cardID == cardID else { return project(library, now: now, calendar: calendar).first { $0.id == cardID } }
        if occurrence.scheduleID == card.schedulingID || library.occurrences.contains(where: { $0.id == occurrence.id }) {
            return projectOccurrence(card, occurrence: occurrence, in: library)
        }
        // A saved change to “this and following” creates a new rule. Resolve that rule at
        // the date the user was viewing, never silently jump back to today's instance.
        let selectedDate = occurrence.plannedAt ?? now
        let onDate = projectDay(library, on: selectedDate, calendar: calendar).filter { $0.id == cardID && $0.occurrence?.scheduleID == card.schedulingID }
        if let current = onDate.first(where: { $0.state == .pending }) ?? onDate.last { return current }
        if let next = OccurrenceEngine(calendar: calendar).next(for: card, after: calendar.startOfDay(for: selectedDate), overrides: library.overrides.filter { $0.cardID == cardID }) {
            return projectOccurrence(card, occurrence: next, in: library)
        }
        return CardProjection(card: card, occurrence: nil, hasConflict: library.conflicts[cardID] != nil)
    }

    nonisolated private static func projectOccurrence(_ card: Card, occurrence: Occurrence, in library: LibrarySnapshot) -> CardProjection {
        var current = library.occurrences.first { $0.id == occurrence.id } ?? occurrence
        let override = library.overrides.first { $0.occurrenceID == current.id }
        if override?.kind == .rescheduled, let date = override?.newDate {
            current.plannedAt = date
            current.snapshot.plannedAt = date
        }
        var result = CardProjection(card: card, occurrence: current, events: library.events(for: current.id), reminderState: library.personalStates[current.id], hasConflict: library.conflicts[card.id] != nil)
        if override?.kind == .canceled { result.state = .canceled }
        else if override?.kind == .skipped && result.state == .pending { result.state = .skipped }
        return result
    }

    func start() async {
        guard !isStarting, !started || fatalError != nil else { return }
        isStarting = true; started = false; isLoading = true; fatalError = nil
        defer { isStarting = false; isLoading = false }
        #if DEBUG
        // Hosted unit tests provide their own isolated repositories and system scheduling lifecycle.
        if NSClassFromString("XCTestCase") != nil { started = true; return }
        #endif
        do {
            // A failed cloud rollback can also reach the recovery page after initial startup.
            if repository != nil || startupStoreToDetach != nil { try await releaseStartupResources() }
            let group = Bundle.main.object(forInfoDictionaryKey: "ShiriAppGroup") as? String ?? "group.com.jianmutianyi.nianyi"
            let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var directory = base.appendingPathComponent("NianYi", isDirectory: true)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting"), let testID = ProcessInfo.processInfo.environment["NIANYI_TEST_STORE_ID"], UUID(uuidString: testID) != nil {
                directory = base.appendingPathComponent("ShiriUITests/" + testID, isDirectory: true)
            }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting"), let testID = ProcessInfo.processInfo.environment["NIANYI_TEST_STORE_ID"], UUID(uuidString: testID) != nil,
               let clock = ProcessInfo.processInfo.environment["NIANYI_FIXED_NOW"] { fixedDate = ISO8601DateFormatter().date(from: clock) }
            #endif
            let persistence = try await PersistenceController.open(PersistenceConfiguration(directory: directory))
            let actor = UserDefaults.standard.string(forKey: "NianYiActorID") ?? UUID().uuidString
            UserDefaults.standard.set(actor, forKey: "NianYiActorID")
            let repo = ShiriRepository(persistence: persistence, actorID: actor)
            repository = repo; commands = CardCommands(repository: repo)
            historyConsumer = PersistentHistoryConsumer(repository: repo, consumer: "main-app")
            do { try await repo.resumeMigrations() } catch { message = "保存位置切换尚未完成：\(error.localizedDescription)" }
            _ = try await repo.purgeExpiredTrash(now: now, calendar: calendar)
            try ExtensionStore.publish(ExtensionBootstrap(), at: directory)
            preferences = try await repo.deviceValue(AppPreferences.self, key: "preferences") ?? AppPreferences()
            if preferences.excludesSystemBackup == true { try repo.setSystemBackupExcluded(true) }
            if let pendingError = try await repo.deviceValue(String.self, key: "pending-action-error") { message = pendingError; try await repo.deleteDeviceRecord(entity: "DeviceValueRecord", id: "pending-action-error") }
            #if DEBUG
            try await DevelopmentFixtures.prepare(model: self)
            #endif
            // Local storage is sufficient to enter the app; cloud never gates the first screen.
            library = try await libraryPreservingMemories(repo); shareSessions = try await readShareSessions(repo)
            let initialSnapshot = library, initialDate = now, initialCalendar = calendar
            projections = await Task.detached(priority: .userInitiated) {
                Self.project(initialSnapshot, now: initialDate, calendar: initialCalendar)
            }.value
            lastRefreshDate = initialDate; lastRefreshCalendar = initialCalendar
            #if DEBUG
            if !injectedStartupFailure, ProcessInfo.processInfo.arguments.contains("--uitesting"),
               let testID = ProcessInfo.processInfo.environment["NIANYI_TEST_STORE_ID"], UUID(uuidString: testID) != nil,
               ProcessInfo.processInfo.environment["NIANYI_FAIL_STARTUP_ONCE"] == "1" {
                injectedStartupFailure = true
                throw ShiriError.storage("本次打开未能完成，请重试。已有卡片仍保留在原来的位置。")
            }
            #endif
            started = true
            remoteObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: persistence.container.persistentStoreCoordinator, queue: .main) { [weak self] _ in Task { @MainActor in await self?.handleRemoteChange() } }
            isLoading = false
            presentPendingComposer()
            AppNotificationRouter.shared.onResponse = { [weak self] response in await self?.handleNotification(response) }
            if let response = AppNotificationRouter.shared.pending { AppNotificationRouter.shared.pending = nil; await handleNotification(response) }
            timeObserver = NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
            await refresh()
            AppInvitationRouter.shared.onInvitation = { [weak self] metadata in Task { @MainActor in await self?.acceptInvitation(metadata) } }
            if let metadata = AppInvitationRouter.shared.pending { AppInvitationRouter.shared.pending = nil; await acceptInvitation(metadata) }
            if UserDefaults.standard.bool(forKey: "NianYiCloudBootstrap") { do { try await connectCloud(automatically: true) } catch { cloudStatus = error.localizedDescription } }
        } catch {
            started = false
            recordFailure(error)
            let openingError = error.localizedDescription
            do {
                try await releaseStartupResources()
                fatalError = openingError
            } catch {
                recordFailure(error)
                fatalError = openingError + "\n暂时无法重新打开卡片，请稍后重试。原有数据仍然保留。"
            }
        }
    }
    private func releaseStartupResources() async throws {
        // Disable new work before waiting for any read already using this store.
        started = false
        for observer in [remoteObserver, timeObserver, cloudAccountObserver, cloudEventObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        remoteObserver = nil; timeObserver = nil; cloudAccountObserver = nil; cloudEventObserver = nil
        AppNotificationRouter.shared.onResponse = nil
        AppInvitationRouter.shared.onInvitation = nil
        historyConsumer = nil
        if isRefreshing { await withCheckedContinuation { refreshWaiters.append($0) } }
        await geofences.releaseRepository()
        cloudCoordinator = nil; cloudAccountKey = nil
        commands = nil
        if let repository { startupStoreToDetach = repository.persistence }
        repository = nil
        // Keep a failed handle so the next retry must detach it before opening another store.
        if let startupStoreToDetach { try await startupStoreToDetach.detachStores() }
        startupStoreToDetach = nil
    }
    private func readShareSessions(_ repository: ShiriRepository) async throws -> [ShareSession] {
        #if DEBUG
        if !DevelopmentFixtures.sharingSessions.isEmpty { return DevelopmentFixtures.sharingSessions }
        #endif
        return try await repository.localShareSessions()
    }
    private func handleRemoteChange() async {
        guard started else { return }
        // A store notification can describe our own ledger write. Consume its history before
        // deciding to reconcile, otherwise each refresh causes another refresh indefinitely.
        remoteRefreshRequested = true
        startRefreshDrainIfNeeded()
    }
    func refresh() async {
        guard started else { return }
        refreshRequested = true
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
            startRefreshDrainIfNeeded()
        }
    }
    private func startRefreshDrainIfNeeded() {
        guard started, !isRefreshing else { return }
        isRefreshing = true
        Task { await drainRefreshRequests() }
    }
    private func drainRefreshRequests() async {
        defer {
            isRefreshing = false
            remoteRefreshRequested = false; refreshRequested = false
            let remaining = refreshWaiters; refreshWaiters.removeAll()
            remaining.forEach { $0.resume() }
        }
        while started && (refreshRequested || remoteRefreshRequested) {
            let explicitlyRequested = refreshRequested
            let callers = refreshWaiters; refreshWaiters.removeAll()
            refreshRequested = false; remoteRefreshRequested = false
            do {
                let changes = try await historyConsumer?.consume()
                if explicitlyRequested || (changes?.transactions ?? 0) > 0 {
                    try await performRefreshPass()
                }
            } catch { recordFailure(error); message = error.localizedDescription }
            // Callers only wait for a complete pass that began after their request. Later store
            // notifications and later callers belong to the next batch and cannot hold this UI.
            callers.forEach { $0.resume() }
        }
    }
    private func performRefreshPass() async throws {
        guard started, let repository else { return }
        let snapshot = try await libraryPreservingMemories(repository)
        let date = now; let cal = calendar
        let previousSnapshot = library, previousProjections = projections
        let needsDateProjection = lastRefreshCalendar != cal || lastRefreshDate.map { !cal.isDate($0, inSameDayAs: date) } != false
        let (projected, snapshotChanged, projectionsChanged) = await Task.detached(priority: .userInitiated) {
            let snapshotChanged = previousSnapshot != snapshot
            if !snapshotChanged && !needsDateProjection { return (previousProjections, false, false) }
            let projected = Self.project(snapshot, now: date, calendar: cal)
            return (projected, snapshotChanged,
                    previousProjections.sorted { $0.id.uuidString < $1.id.uuidString } != projected.sorted { $0.id.uuidString < $1.id.uuidString })
        }.value
        let calendarChanged = lastRefreshCalendar.map { $0 != cal } ?? false
        let dayChanged = lastRefreshDate.map { !cal.isDate($0, inSameDayAs: date) } ?? false
        let eventVisibilityChanged = lastRefreshDate.map { previous in
            snapshot.events.contains { event in
                (previous < event.happenedAt && event.happenedAt <= date) || (date < event.happenedAt && event.happenedAt <= previous)
            }
        } ?? false
        if snapshotChanged { library = snapshot }
        if projectionsChanged { projections = projected }
        if snapshotChanged || projectionsChanged || calendarChanged || dayChanged || eventVisibilityChanged { snapshotRevision += 1 }
        lastRefreshDate = date; lastRefreshCalendar = cal
        if let requestDate = try await repository.deviceValue(Date.self, key: "open-composer-request") {
            try await repository.deleteDeviceRecord(entity: "DeviceValueRecord", id: "open-composer-request")
            if (0..<120).contains(now.timeIntervalSince(requestDate)) { requestComposer(.text) }
        }
        let sessions = try await readShareSessions(repository)
        if shareSessions != sessions { shareSessions = sessions }
        pendingMigrations = try await repository.migrationJournals().filter { $0.phase != "complete" && $0.accountKey == repository.persistence.configuration.cloudAccountKey }
        if let cloudCoordinator {
            do { receivedCloudSessions = try await cloudCoordinator.sessions(received: true); try await cloudCoordinator.flushReceipts(now: now) }
            catch { cloudStatus = "同步等待重试：" + error.localizedDescription; recordFailure(error) }
        }
        #if DEBUG
        if let refreshTestEffect {
            try await refreshTestEffect()
            completedRefreshPassesForTesting += 1
            return
        }
        #endif
        await reconcileReminders()
        let widgetLibrary = library, widgetPreferences = preferences, widgetDate = now, widgetCalendar = calendar
        let directory = repository.persistence.configuration.directory
        try await Task.detached(priority: .utility) {
            try WidgetSnapshot.make(library: widgetLibrary, preferences: widgetPreferences, now: widgetDate, calendar: widgetCalendar).write(at: directory)
        }.value
        WidgetCenter.shared.reloadTimelines(ofKind: "NianYiToday")
    }
    #if DEBUG
    func prepareRefreshForTesting(repository: ShiriRepository, effect: @escaping @MainActor () async throws -> Void) {
        precondition(NSClassFromString("XCTestCase") != nil)
        self.repository = repository; commands = CardCommands(repository: repository)
        historyConsumer = PersistentHistoryConsumer(repository: repository, consumer: "main-app")
        refreshTestEffect = effect; started = true
        remoteObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: repository.persistence.container.persistentStoreCoordinator, queue: .main) { [weak self] _ in Task { @MainActor in await self?.handleRemoteChange() } }
    }
    func receiveStoreChangeForTesting() async { await handleRemoteChange() }
    func finishRefreshForTesting() async throws {
        try await releaseStartupResources()
        refreshTestEffect = nil
    }
    #endif
    func reconcileReminders() async {
        guard let repository else { return }
        let speechResources = systemCapabilities.enhancedSpeech
        var updatedCapabilities = await CapabilityProvider.read(locationAuthorization: geofences.authorization)
        updatedCapabilities.enhancedSpeech = speechResources
        if systemCapabilities != updatedCapabilities { systemCapabilities = updatedCapabilities }
        let snapshot = library, prefs = preferences, date = now, cal = calendar
        let capabilities = systemCapabilities.reminders
        let desired = await Task.detached(priority: .utility) { ReminderPlanner(calendar: cal).plan(library: snapshot, preferences: prefs, now: date, capabilities: capabilities) }.value
        var failures: [String] = []
        var ledger: [ReminderLedgerEntry] = []
        do { ledger += try await NotificationAdapter.shared.reconcile(desired, library: library, repository: repository, now: now) }
        catch { recordFailure(error); failures.append("普通通知：" + error.localizedDescription) }
        do { try await NotificationAdapter.shared.reconcileReviewReminder(enabled: preferences.showReviewReminder) }
        catch { recordFailure(error); failures.append("回顾提醒：" + error.localizedDescription) }
        if #available(iOS 26.0, *) {
            do { ledger += try await AlarmAdapter.reconcile(desired, repository: repository, now: now) }
            catch { recordFailure(error); failures.append("系统闹钟：" + error.localizedDescription) }
        }
        if reminderLedger != ledger { reminderLedger = ledger }
        if deferredReminders != desired.deferred.count { deferredReminders = desired.deferred.count }
        if reminderCoverageEnd != desired.coverageEnd { reminderCoverageEnd = desired.coverageEnd }
        await geofences.reconcile(library: library, preferences: preferences, repository: repository, now: now)
        let issues = desired.issues + geofences.messages
        if reminderIssues != issues { reminderIssues = issues }
        failures += await liveActivities.reconcile(library: library, privacy: preferences.notificationPrivacy, now: now).map { "锁屏与灵动岛：" + $0 }
        if !failures.isEmpty { message = "卡片已保存，部分提醒尚未设置完成：\n" + failures.joined(separator: "\n") }
    }
    func recordFailure(_ error: Error) {
        let ns = error as NSError
        lastFailureCode = "\(String(describing: type(of: error)))-\(ns.code)"
    }

    func create(kind: CardKind = .task, speech: Bool = false) {
        var card = Card(title: "", kind: kind, now: now)
        card.reminders.enablesLiveActivity = true
        card.scope = preferences.cloudEnabled && cloudCoordinator != nil ? preferences.defaultScope : .local
        startsWithSpeech = speech; composer = CardDraft(card: card)
    }
    func requestComposer(_ mode: ComposerInputMode) {
        if let composer, composer.card.id == externalComposerCardID, externalComposerMode == mode { return }
        pendingComposerInput = mode
        presentPendingComposer()
    }
    func cancelPendingComposer() { pendingComposerInput = nil; pendingVoiceDraftID = nil }
    func presentPendingComposer() {
        guard !isLoading, fatalError == nil, composer == nil, importPackage == nil else { return }
        if let id = pendingVoiceDraftID {
            guard !isOpeningVoiceDraft, let repository else { return }
            isOpeningVoiceDraft = true
            Task {
                defer {
                    isOpeningVoiceDraft = false
                    if let pendingVoiceDraftID, pendingVoiceDraftID != id { presentPendingComposer() }
                }
                do {
                    let draft = try await repository.drafts().first { $0.id == id }
                    guard pendingVoiceDraftID == id, composer == nil, importPackage == nil else { return }
                    pendingVoiceDraftID = nil
                    if let draft { startsWithSpeech = false; startsOccasionEditor = false; composer = draft }
                    else { message = "这份草稿已处理，可以在卡片库查看。" }
                } catch { message = error.localizedDescription }
            }
            return
        }
        guard let mode = pendingComposerInput else { return }
        pendingComposerInput = nil
        startsOccasionEditor = false
        create(speech: mode == .voice)
        externalComposerCardID = composer?.card.id
        externalComposerMode = mode
    }
    func createOccasion() {
        startsOccasionEditor = true
        create(kind: .note)
    }
    func handleNotification(_ response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo["nianyiRoute"] as? String == "review" { selectedTab = .review; return }
        guard let payload = NotificationAdapter.payload(response.notification.request.content.userInfo), let repository else { return }
        do {
            let snapshot = try await repository.library()
            let occurrence = try payload.resolve(in: snapshot, deliveredAt: response.notification.date, calendar: calendar)
            switch response.actionIdentifier {
            case "COMPLETE": try await commands?.complete(occurrence, now: now)
            case "SNOOZE": try await commands?.snooze(occurrence, until: now.addingTimeInterval(600), now: now)
            case "STOP": try await commands?.stopReminder(occurrence, now: now)
            case "RESCHEDULE":
                reminderResponse = ReminderResponseRequest(payload: payload, deliveredAt: response.notification.date, selectsNewTime: true)
            default:
                if let card = snapshot.cards.first(where: { $0.id == payload.cardID }) {
                    if card.kind == .task, EventReducer.state(events: snapshot.events(for: occurrence.id)) == .pending,
                       response.notification.request.content.userInfo["nianyiCompletionConfirmation"] as? Bool == true || (occurrence.plannedAt ?? .distantFuture) <= now {
                        reminderResponse = ReminderResponseRequest(payload: payload, deliveredAt: response.notification.date)
                    } else { openCard(card, occurrence: occurrence) }
                }
            }
            await refresh()
        } catch { message = error.localizedDescription; await refresh() }
    }
    func respondToReminder(_ request: ReminderResponseRequest, action: ReminderResponseAction) async throws {
        guard let repository, let commands else { throw ShiriError.unavailable("正在读取卡片，请稍后再试") }
        let snapshot = try await repository.library()
        let occurrence = try request.payload.resolve(in: snapshot, deliveredAt: request.deliveredAt, calendar: calendar)
        switch action {
        case .complete: try await commands.complete(occurrence, now: now)
        case .snooze: try await commands.snooze(occurrence, until: now.addingTimeInterval(600), now: now)
        case .reschedule(let date):
            guard date > now else { throw ShiriError.validation("请选择未来的时间") }
            try await commands.rescheduleOccurrence(occurrence, to: date, now: now)
        }
        await refresh()
        if reminderResponse?.id == request.id { reminderResponse = nil }
    }
    func edit(_ card: Card, from occurrence: Occurrence? = nil) {
        Task {
            do {
                var draft = CardDraft(card: card, isEditing: true)
                draft.attachments = try await repository?.attachments(cardID: card.id).filter { card.attachmentIDs.contains($0.id) } ?? []
                if let occurrence, card.isRepeating {
                    draft.editingFrom = occurrence; draft.card.recurrenceClosedAt = nil
                    if let date = occurrence.plannedAt, let schedule = card.schedule {
                        draft.card.schedule?.start = CivilDate(date, calendar: schedule.calendar(fallback: calendar))
                    }
                }
                composer = draft
            }
            catch { message = error.localizedDescription }
        }
    }
    func save(_ draft: CardDraft) async throws {
        guard let commands else { throw ShiriError.unavailable("正在读取卡片，请稍后再试") }
        let card = try await commands.save(draft, now: now)
        if card.reminders.isEnabled {
            if card.reminders.channel == .notification || (card.kind == .task && preferences.completionConfirmationMinutes > 0) {
                let authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                if authorization == .notDetermined { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.badge,.sound]) }
            }
            if card.reminders.channel == .alarm, #available(iOS 26.0, *), AlarmAdapter.needsPermission {
                try? await AlarmAdapter.requestPermission()
            }
        }
        if card.scope == .privateCloud { preferences.enabledCloudCardIDs.insert(card.id); try await savePreferences() }
        await refresh()
        let issues = reminderIssues.filter { $0.cardID == card.id }
        if card.reminders.isEnabled && !issues.isEmpty { message = "卡片已保存。" + issues.map(\.message).joined(separator: "\n") }
        do { try await liveActivities.activateSavedCard(card, library: library, privacy: preferences.notificationPrivacy, now: now) }
        catch { recordFailure(error); message = "卡片已保存。锁屏与灵动岛暂未开启：" + error.localizedDescription }
        composer = nil
        if selectedCard?.id == card.id { selectedCard = card }
    }
    func complete(_ projection: CardProjection) {
        guard let occurrence = projection.occurrence else { return }
        perform {
            if projection.state == .completed {
                try await self.commands?.undo(occurrence, now: self.now)
                if self.pendingMemory?.occurrence?.id == occurrence.id { self.pendingMemory = nil }
            } else {
                guard let commands = self.commands else { throw ShiriError.notFound }
                try await commands.complete(occurrence, now: self.now)
                let candidate = MemoryCandidate(card: projection.card, occurrence: occurrence, date: self.now)
                if MemoryCollection.savedMemory(for: candidate, in: self.library.cards) == nil { self.pendingMemory = candidate }
            }
        }
    }
    func perform(_ work: @escaping () async throws -> Void) {
        Task { do { try await work(); await refresh() } catch { recordFailure(error); message = error.localizedDescription; await refresh() } }
    }
    private func libraryPreservingMemories(_ repository: ShiriRepository) async throws -> LibrarySnapshot {
        let snapshot = try await repository.library()
        guard snapshot.cards.contains(where: { $0.memoryDate != nil && $0.memory == nil && $0.lifecycle != .deleted && snapshot.conflicts[$0.id] == nil }) else { return snapshot }
        do {
            _ = try await repository.migrateLegacyMemories(now: now)
            return try await repository.library()
        } catch {
            message = "旧回忆暂未整理完成，原记录仍保留。" + error.localizedDescription
            return snapshot
        }
    }

    func savePreferences() async throws {
        if let repository {
            let previous = try await repository.deviceValue(AppPreferences.self, key: "preferences")
            if previous?.excludesSystemBackup != preferences.excludesSystemBackup { try repository.setSystemBackupExcluded(preferences.excludesSystemBackup == true) }
            try await repository.setDeviceValue(preferences, key: "preferences")
        }
        await refresh()
    }
    var cloudFeedbackAvailable: Bool { cloudCoordinator != nil }
    var cloudConfigured: Bool { (Bundle.main.object(forInfoDictionaryKey: "ShiriCloudConfigured") as? NSString)?.boolValue == true }
    var cloudContainerID: String { Bundle.main.object(forInfoDictionaryKey: "ShiriCloudContainer") as? String ?? "iCloud.com.jianmutianyi.nianyi" }
    func canAcceptFeedback(_ sessionID: UUID) -> Bool { receivedCloudSessions.contains { $0.id == sessionID } && cloudCoordinator != nil }
    private func useRepository(_ repo: ShiriRepository) {
        repository = repo; commands = CardCommands(repository: repo)
        historyConsumer = PersistentHistoryConsumer(repository: repo, consumer: "main-app")
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        remoteObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: repo.persistence.container.persistentStoreCoordinator, queue: .main) { [weak self] _ in Task { @MainActor in await self?.handleRemoteChange() } }
    }
    func connectCloud(automatically: Bool = false) async throws {
        guard cloudConfigured else { throw ShiriError.unavailable("iCloud 同步暂不可用，你仍可以在本机保存、备份和分享卡片。") }
        guard var old = repository else { throw ShiriError.unavailable("正在读取卡片，请稍后再试") }
        guard !isConnectingCloud else { return }
        isConnectingCloud = true; defer { isConnectingCloud = false }
        cloudStatus = "正在检查 iCloud 账户…"
        let key = try await CloudSharingCoordinator.availableAccount(containerID: cloudContainerID)
        if automatically, let previous = UserDefaults.standard.string(forKey: "NianYiCloudAccountKey"), previous != key {
            await isolateCloudAccount()
            throw ShiriError.unavailable("iCloud 账户已变化，旧账户数据已隔离。确认当前账户后可重新连接。")
        }
        if cloudCoordinator != nil && cloudAccountKey == key { cloudStatus = "已连接 iCloud"; return }
        if let previous = cloudAccountKey, previous != key {
            await isolateCloudAccount()
            guard let local = repository else { throw ShiriError.unavailable("卡片尚未恢复，请稍后再试") }
            old = local
        }
        let configuration = PersistenceConfiguration(directory: old.persistence.configuration.directory, cloudContainerID: cloudContainerID, enablesCloudMirroring: true, loadsCloudStores: true, cloudAccountKey: key)
        try ExtensionStore.publish(ExtensionBootstrap(), at: configuration.directory)
        geofences.suspend()
        try await old.persistence.detachStores()
        let persistence: PersistenceController
        do { persistence = try await PersistenceController.open(configuration) }
        catch {
            let cloudError = error
            cloudCoordinator = nil; cloudAccountKey = nil; preferences.cloudEnabled = false
            do {
                let local = try await PersistenceController.open(PersistenceConfiguration(directory: configuration.directory))
                useRepository(ShiriRepository(persistence: local, actorID: old.actorID))
                try await savePreferences()
            } catch { fatalError = "暂时无法打开本机记录，原有文件仍保留：\(error.localizedDescription)" }
            throw cloudError
        }
        let repo = ShiriRepository(persistence: persistence, actorID: old.actorID)
        useRepository(repo); cloudAccountKey = key
        do { try await repo.resumeMigrations() } catch { message = "保存位置切换尚未完成：\(error.localizedDescription)" }
        try ExtensionStore.publish(ExtensionBootstrap(cloudAccountKey: key, cloudContainerID: cloudContainerID), at: configuration.directory)
        cloudCoordinator = CloudSharingCoordinator(repository: repo, containerID: cloudContainerID)
        if cloudAccountObserver == nil {
            cloudAccountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.isolateCloudAccount() } }
        }
        if let cloudEventObserver { NotificationCenter.default.removeObserver(cloudEventObserver) }
        cloudEventObserver = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: persistence.container, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                if let error = event.error { self?.recordFailure(error); self?.cloudStatus = "同步暂未完成：\(error.localizedDescription)" }
                else { self?.cloudStatus = event.endDate == nil ? "iCloud 正在处理变更…" : "上次同步处理：\(event.endDate!.formatted(date: .omitted, time: .shortened))" }
                await self?.refresh()
            }
        }
        preferences.cloudEnabled = true; try await savePreferences()
        UserDefaults.standard.set(true, forKey: "NianYiCloudBootstrap")
        UserDefaults.standard.set(key, forKey: "NianYiCloudAccountKey")
        cloudStatus = "已连接 iCloud"; await refresh()
    }
    func pauseCloudSync() async throws {
        guard let repository else { return }
        for card in library.cards where card.scope == .privateCloud {
            try await repository.migrateCard(card.id, to: .local, now: now, retainCloudCopy: true)
        }
        await isolateCloudAccount()
        cloudStatus = "此设备已停止云同步。已下载的卡片保存在本机，云端副本与已发出的邀请保留。"
    }
    func isolateCloudAccount() async {
        // Stop exposing the previous identity before any asynchronous account lookup.
        let oldCloudIDs = Set(library.cards.filter { $0.scope == .privateCloud }.map(\.id))
        cloudCoordinator = nil; cloudAccountKey = nil; receivedCloudSessions = []; shareSessions = []; selectedCard = nil; importPackage = nil
        library.cards.removeAll { $0.scope == .privateCloud }
        projections.removeAll { $0.card.scope == .privateCloud }
        geofences.suspend()
        await NotificationAdapter.shared.clearCloud(cardIDs: oldCloudIDs)
        if #available(iOS 26.0, *), let repository { await AlarmAdapter.clearCloud(cardIDs: oldCloudIDs, repository: repository) }
        await liveActivities.reconcile(library: library, privacy: preferences.notificationPrivacy, now: now)
        cloudStatus = "iCloud 账户已变化，旧账户数据已隔离。请重新连接。"
        UserDefaults.standard.set(false, forKey: "NianYiCloudBootstrap")
        guard let old = repository else { return }
        do {
            try ExtensionStore.publish(ExtensionBootstrap(), at: old.persistence.configuration.directory)
            try WidgetSnapshot.make(library: library, preferences: preferences, now: now, calendar: calendar).write(at: old.persistence.configuration.directory)
            WidgetCenter.shared.reloadAllTimelines()
            if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
            if let cloudEventObserver { NotificationCenter.default.removeObserver(cloudEventObserver) }
            try await old.persistence.detachStores()
            let persistence = try await PersistenceController.open(PersistenceConfiguration(directory: old.persistence.configuration.directory))
            let repo = ShiriRepository(persistence: persistence, actorID: old.actorID)
            useRepository(repo); preferences.cloudEnabled = false
            try await savePreferences(); await refresh()
        } catch { message = error.localizedDescription }
    }
    func prepareCloudShare(_ session: ShareSession, participantAddress: String) async throws -> ShareSession {
        guard let cloudCoordinator else { throw ShiriError.unavailable("请先连接 iCloud") }
        return try await cloudCoordinator.create(session, participantAddress: participantAddress)
    }
    func revokeCloudShare(_ session: ShareSession) async throws {
        guard let cloudCoordinator else { throw ShiriError.unavailable("请先连接 iCloud") }
        try await cloudCoordinator.leaveOrRevoke(sessionID: session.id, received: false)
        var updated = session; updated.status = .revoked; updated.updatedAt = now
        try await repository?.saveLocalShareSession(updated)
    }
    func acceptInvitation(_ metadata: CKShare.Metadata) async {
        do {
            if cloudCoordinator == nil { try await connectCloud() }
            guard let cloudCoordinator else { return }
            try await cloudCoordinator.accept(metadata); await refresh()
            selectedTab = .sharing
            message = "邀请已接受，分享内容正在同步。收到后可预览并决定是否添加。"
        } catch { message = error.localizedDescription }
    }
    func openFile(_ url: URL) async {
        if let mode = ComposerInputMode.from(url) { requestComposer(mode); return }
        if url.scheme == "nianyi", url.host == "draft", let id = UUID(uuidString: url.lastPathComponent) {
            pendingVoiceDraftID = id; presentPendingComposer(); return
        }
        if url.scheme == "nianyi", url.host == "today" { selectedTab = .today; return }
        if url.scheme == "nianyi", url.host == "card", let id = UUID(uuidString: url.lastPathComponent) {
            if let card = library.cards.first(where: { $0.id == id }) { openCard(card) }
            else { selectedCard = nil }
            return
        }
        guard url.isFileURL else { message = "请打开拾日日程文件或有效的私有邀请。"; return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { let data = try FileTransport.read(url, limit: AppLimits.shareBytes); importPackage = try FileTransport.decodeShare(data) }
        catch { message = error.localizedDescription }
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case today, cards, review, sharing, settings
    var id: String { rawValue }
    var title: String { switch self { case .today: return "今天"; case .cards: return "卡片"; case .review: return "回顾"; case .sharing: return "分享"; case .settings: return "设置" } }
    var symbol: String { switch self { case .today: return "calendar"; case .cards: return "note.text"; case .review: return "clock"; case .sharing: return "paperplane"; case .settings: return "gearshape" } }
}
