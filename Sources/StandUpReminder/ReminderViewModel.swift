import Foundation
import EventKit
import SwiftUI
@preconcurrency import UserNotifications
import Darwin

struct NotificationDebugItem: Identifiable, Equatable {
    let id: String
    let identifier: String
    let sourceLabel: String
    let title: String
    let body: String
    let threadIdentifier: String
    let categoryIdentifier: String
    let triggerSummary: String
    let nextTriggerDate: Date?
    let deliveredAt: Date?
    let repeats: Bool
    let scheduledWeekday: Int?
    let scheduledHour: Int?
    let scheduledMinute: Int?
}

@MainActor
final class ReminderViewModel: ObservableObject {
    @Published var settings: ReminderSettings
    @Published var todoItems: [AssistantItem]
    @Published var shoppingItems: [AssistantItem]
    @Published var calendarAccessState: CalendarAccessState = .unknown
    @Published var calendarEvents: [CalendarEventItem] = []
    @Published var calendarEventsDate: Date = Calendar.current.startOfDay(for: .now)
    @Published var calendarStatusMessage: String = "Calendar not loaded."
    @Published var statusMessage: String = "Ready."
    @Published var schedulesNotificationsOnThisMac: Bool
    @Published var notificationAuthorizationDebugLabel: String = "Unknown"
    @Published var pendingNotificationDebugItems: [NotificationDebugItem] = []
    @Published var deliveredNotificationDebugItems: [NotificationDebugItem] = []
    @Published var notificationDebugStatusMessage: String = "Notification debug info not loaded."
    @Published var notificationDebugLastRefresh: Date?

    private let scheduler = ReminderScheduler()
    private let mouseMover = MouseMoverService()
    private var eventStore: EKEventStore
    private let settingsKey = "standup.settings.v1"
    private let localSchedulingKey = "standup.localSchedulingEnabled.v1"
    private let todosKey = "assistant.todos.v1"
    private let shoppingKey = "assistant.shopping.v1"
    private let calendarNotificationLeadMinutes = 5
    private let defaults: UserDefaults
    private let calendarAppDefaults = UserDefaults(suiteName: "com.apple.iCal")
    private let shouldManageScheduling: Bool
    private let schedulingLockFD: Int32?
    let machineDisplayName: String

    private var lastKnownSettingsData: Data?
    private var lastKnownTodosData: Data?
    private var lastKnownShoppingData: Data?
    private var syncTask: Task<Void, Never>?
    private var calendarStoreRefreshTask: Task<Void, Never>?
    nonisolated(unsafe) private var calendarStoreObserver: NSObjectProtocol?
    private var applySettingsGeneration = 0
    private var pendingApplySettingsGeneration: Int?
    private var isApplySettingsInFlight = false

    init() {
        defaults = .standard
        eventStore = EKEventStore()
        machineDisplayName = Self.currentMachineName()
        schedulesNotificationsOnThisMac = defaults.object(forKey: localSchedulingKey) as? Bool ?? true
        schedulingLockFD = Self.acquireSchedulingLock()
        shouldManageScheduling = schedulingLockFD != nil

        let initialSettings: ReminderSettings
        let initialSettingsData: Data?
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(ReminderSettings.self, from: data) {
            initialSettings = Self.normalized(decoded)
            initialSettingsData = data
        } else {
            initialSettings = Self.normalized(.default)
            if let encodedDefault = try? JSONEncoder().encode(initialSettings) {
                defaults.set(encodedDefault, forKey: settingsKey)
                initialSettingsData = encodedDefault
            } else {
                initialSettingsData = nil
            }
        }
        settings = initialSettings
        lastKnownSettingsData = initialSettingsData

        let loadedTodos = Self.loadItems(from: defaults, forKey: todosKey, kind: .todo)
        todoItems = loadedTodos.items
        lastKnownTodosData = loadedTodos.data

        let loadedShopping = Self.loadItems(from: defaults, forKey: shoppingKey, kind: .shopping)
        shoppingItems = loadedShopping.items
        lastKnownShoppingData = loadedShopping.data
        applyMouseMoverSettings()
        observeCalendarStoreChanges()

        if shouldManageScheduling {
            applySettings()
            startSettingsSyncPolling()
        } else {
            statusMessage = "Secondary instance detected. Scheduling is handled by the primary app instance."
        }
    }

    deinit {
        if let schedulingLockFD {
            flock(schedulingLockFD, LOCK_UN)
            close(schedulingLockFD)
        }
        syncTask?.cancel()
        calendarStoreRefreshTask?.cancel()
        if let calendarStoreObserver {
            NotificationCenter.default.removeObserver(calendarStoreObserver)
        }
    }

    var pendingTodoCount: Int {
        todoItems.filter { !$0.isCompleted }.count
    }

    var pendingShoppingCount: Int {
        shoppingItems.filter { !$0.isCompleted }.count
    }

    var isPrimarySchedulingInstance: Bool {
        shouldManageScheduling
    }

    var todosByManualOrder: [AssistantItem] {
        todoItems.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    var shoppingByManualOrder: [AssistantItem] {
        shoppingItems.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    @discardableResult
    func saveSettings(_ draft: ReminderSettings) -> Bool {
        let normalizedDraft = Self.normalized(draft)
        if normalizedDraft.isEnabled, let error = validate(normalizedDraft) {
            statusMessage = error
            return false
        }

        settings = normalizedDraft
        applySettings()
        return true
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        applySettings()
    }

    func setSchedulesNotificationsOnThisMac(_ enabled: Bool) {
        guard schedulesNotificationsOnThisMac != enabled else { return }
        schedulesNotificationsOnThisMac = enabled
        defaults.set(enabled, forKey: localSchedulingKey)

        guard shouldManageScheduling else {
            statusMessage = enabled
                ? "Secondary instance detected. Scheduling is handled by the primary app instance."
                : localSchedulingDisabledMessage
            return
        }

        applySettings()
    }

    func sendTestNotification() {
        guard schedulesNotificationsOnThisMac else {
            statusMessage = "Enable scheduling on this Mac before sending a test notification."
            return
        }

        scheduler.notificationAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .authorized, .provisional, .ephemeral:
                    if self.settings.isEnabled {
                        self.applySettings()
                    }
                    self.scheduleTestNotification()
                case .notDetermined:
                    self.scheduler.requestPermission { [weak self] granted, errorMessage in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard granted else {
                                self.statusMessage = errorMessage ?? "Permission denied."
                                return
                            }
                            if self.settings.isEnabled {
                                self.applySettings()
                            }
                            self.scheduleTestNotification()
                        }
                    }
                case .denied:
                    self.statusMessage = "Notification permission denied in System Settings."
                @unknown default:
                    self.statusMessage = "Unknown notification permission status."
                }
            }
        }
    }

    func setMouseMoverEnabled(_ enabled: Bool) {
        guard settings.isMouseMoverEnabled != enabled else { return }
        settings.isMouseMoverEnabled = enabled
        persistSettings()
        applyMouseMoverSettings()
        statusMessage = enabled
            ? "Mouse mover enabled. Display idle sleep will be prevented."
            : "Mouse mover disabled."
    }

    func setMouseMoverIdleThresholdMinutes(_ minutes: Int) {
        let clamped = max(1, min(60, minutes))
        guard settings.mouseMoverIdleThresholdMinutes != clamped else { return }
        settings.mouseMoverIdleThresholdMinutes = clamped
        persistSettings()
        applyMouseMoverSettings()
        statusMessage = "Mouse mover settings updated."
    }

    func setMouseMoverMoveIntervalMinutes(_ minutes: Int) {
        let clamped = max(1, min(60, minutes))
        guard settings.mouseMoverMoveIntervalMinutes != clamped else { return }
        settings.mouseMoverMoveIntervalMinutes = clamped
        persistSettings()
        applyMouseMoverSettings()
        statusMessage = "Mouse mover settings updated."
    }

    func refreshFromStore() {
        reloadFromStoreIfNeeded(force: true)
        if settings.isEnabled {
            applySettings()
        }
        if calendarAccessState == .granted {
            refreshCalendarEvents(for: calendarEventsDate, requestAccessIfNeeded: false)
        }
    }

    func refreshNotificationDebugInfo() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notificationSettings in
            let authorizationLabel = Self.notificationAuthorizationDescription(notificationSettings.authorizationStatus)

            UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
                let pendingItems = requests
                    .map(Self.pendingNotificationDebugItem(from:))
                    .sorted(by: Self.sortPendingNotificationDebugItems)

                UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] notifications in
                    let deliveredItems = notifications
                        .map(Self.deliveredNotificationDebugItem(from:))
                        .sorted(by: Self.sortDeliveredNotificationDebugItems)

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.notificationAuthorizationDebugLabel = authorizationLabel
                        self.pendingNotificationDebugItems = pendingItems
                        self.deliveredNotificationDebugItems = deliveredItems
                        self.notificationDebugLastRefresh = .now
                        self.notificationDebugStatusMessage = "Loaded \(pendingItems.count) pending and \(deliveredItems.count) delivered notifications."
                    }
                }
            }
        }
    }

    func periodSummary() -> String {
        let periodSummary = settings.periods
            .enumerated()
            .map { index, period in
                "Period \(index + 1): \(ReminderSchedulePlanner.formatRange(period))"
            }
            .joined(separator: "   ")

        let customSummary = settings.extraReminders
            .filter(\.isEnabled)
            .map { "\($0.title): \(ReminderSchedulePlanner.formatMinutes($0.timeMinutes))" }
            .joined(separator: "   ")

        guard !customSummary.isEmpty else {
            return periodSummary
        }
        return "\(periodSummary)   |   \(customSummary)"
    }

    func addTodo(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todoItems.append(
            AssistantItem(
                kind: .todo,
                title: trimmed,
                sortOrder: nextSortOrder(in: todoItems)
            )
        )
        persistTodos()
    }

    func updateTodoTitle(id: UUID, title: String) {
        guard let index = todoItems.firstIndex(where: { $0.id == id }) else { return }
        todoItems[index].title = title
        todoItems[index].updatedAt = .now
        persistTodos()
    }

    func toggleTodo(id: UUID) {
        guard let index = todoItems.firstIndex(where: { $0.id == id }) else { return }
        todoItems[index].isCompleted.toggle()
        todoItems[index].updatedAt = .now
        persistTodos()
    }

    func removeTodos(ids: [UUID]) {
        let toRemove = Set(ids)
        todoItems.removeAll { toRemove.contains($0.id) }
        reindexTodoSortOrder()
        persistTodos()
    }

    func moveTodos(fromOffsets: IndexSet, toOffset: Int) {
        var ordered = todosByManualOrder
        ordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        todoItems = ordered.enumerated().map { index, item in
            var updated = item
            updated.sortOrder = index
            updated.updatedAt = .now
            return updated
        }
        persistTodos()
    }

    func addShoppingItem(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        shoppingItems.append(
            AssistantItem(
                kind: .shopping,
                title: trimmed,
                sortOrder: nextSortOrder(in: shoppingItems)
            )
        )
        persistShopping()
    }

    func updateShoppingTitle(id: UUID, title: String) {
        guard let index = shoppingItems.firstIndex(where: { $0.id == id }) else { return }
        shoppingItems[index].title = title
        shoppingItems[index].updatedAt = .now
        persistShopping()
    }

    func toggleShopping(id: UUID) {
        guard let index = shoppingItems.firstIndex(where: { $0.id == id }) else { return }
        shoppingItems[index].isCompleted.toggle()
        shoppingItems[index].updatedAt = .now
        persistShopping()
    }

    func removeShoppingItems(ids: [UUID]) {
        let toRemove = Set(ids)
        shoppingItems.removeAll { toRemove.contains($0.id) }
        reindexShoppingSortOrder()
        persistShopping()
    }

    func moveShoppingItems(fromOffsets: IndexSet, toOffset: Int) {
        var ordered = shoppingByManualOrder
        ordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        shoppingItems = ordered.enumerated().map { index, item in
            var updated = item
            updated.sortOrder = index
            updated.updatedAt = .now
            return updated
        }
        persistShopping()
    }

    func refreshCalendarEvents(for date: Date, requestAccessIfNeeded: Bool) {
        let dayStart = Calendar.current.startOfDay(for: date)
        calendarEventsDate = dayStart

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            calendarAccessState = .granted
            refreshCalendarStore()
            loadCalendarEvents(for: dayStart)
            syncCalendarEventNotificationsIfNeeded()
        case .writeOnly:
            calendarAccessState = .writeOnly
            calendarEvents = []
            calendarStatusMessage = "Calendar permission is write-only. Please grant full access."
        case .restricted:
            calendarAccessState = .restricted
            calendarEvents = []
            calendarStatusMessage = "Calendar access is restricted by system policy."
        case .denied:
            calendarAccessState = .denied
            calendarEvents = []
            calendarStatusMessage = "Calendar access denied. Allow access in System Settings."
        case .notDetermined:
            calendarAccessState = .notDetermined
            calendarEvents = []
            calendarStatusMessage = "Calendar access not granted yet."
            if requestAccessIfNeeded {
                requestCalendarAccess(for: dayStart)
            }
        @unknown default:
            calendarAccessState = .denied
            calendarEvents = []
            calendarStatusMessage = "Unknown calendar authorization state."
        }
    }

    func requestCalendarAccessAndRefresh(for date: Date) {
        let dayStart = Calendar.current.startOfDay(for: date)
        calendarEventsDate = dayStart
        requestCalendarAccess(for: dayStart)
    }

    private func requestCalendarAccess(for dayStart: Date) {
        calendarStatusMessage = "Requesting calendar permission..."
        eventStore.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.calendarAccessState = .granted
                    self.refreshCalendarStore()
                    self.loadCalendarEvents(for: dayStart)
                    if self.settings.isEnabled {
                        self.applySettings()
                    }
                } else {
                    self.calendarAccessState = .denied
                    self.calendarEvents = []
                    if let error {
                        self.calendarStatusMessage = "Calendar permission failed: \(error.localizedDescription)"
                    } else {
                        self.calendarStatusMessage = "Calendar access denied. Allow access in System Settings."
                    }
                }
            }
        }
    }

    private func loadCalendarEvents(for dayStart: Date) {
        let calendar = Calendar.current
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            calendarEvents = []
            calendarStatusMessage = "Unable to calculate selected day."
            return
        }

        let visibleCalendars = visibleEventCalendars()
        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: visibleCalendars)
        let events = eventStore.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.startDate < rhs.startDate
            }

        calendarEvents = events.map { event in
            CalendarEventItem(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? event.title!
                    : "Untitled Event",
                startDate: event.startDate,
                endDate: event.endDate,
                calendarTitle: event.calendar.title,
                location: event.location,
                isAllDay: event.isAllDay
            )
        }

        if calendarEvents.isEmpty {
            calendarStatusMessage = "No visible events for selected date. Refreshed \(refreshTimestampLabel())."
        } else {
            let dateLabel = dayStart.formatted(date: .abbreviated, time: .omitted)
            calendarStatusMessage = "\(calendarEvents.count) events on \(dateLabel). Refreshed \(refreshTimestampLabel())."
        }
    }

    private func applySettings() {
        guard shouldManageScheduling else { return }
        persistSettings()
        applyMouseMoverSettings()
        applySettingsGeneration &+= 1
        pendingApplySettingsGeneration = applySettingsGeneration
        startNextApplySettingsRunIfNeeded()
    }

    private func startNextApplySettingsRunIfNeeded() {
        guard !isApplySettingsInFlight else { return }
        guard let generation = pendingApplySettingsGeneration else { return }
        pendingApplySettingsGeneration = nil
        isApplySettingsInFlight = true
        runApplySettings(generation: generation)
    }

    private func runApplySettings(generation: Int) {
        let settingsSnapshot = settings

        guard schedulesNotificationsOnThisMac else {
            scheduler.clearAll { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if generation == self.applySettingsGeneration {
                        self.statusMessage = self.localSchedulingDisabledMessage
                    }
                    self.finishApplySettingsRun()
                }
            }
            return
        }

        guard settingsSnapshot.isEnabled else {
            scheduler.clearAll { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if generation == self.applySettingsGeneration {
                        self.statusMessage = "Reminders are off."
                    }
                    self.finishApplySettingsRun()
                }
            }
            return
        }

        scheduler.notificationAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.applySettingsGeneration else {
                    self.finishApplySettingsRun()
                    return
                }

                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.scheduleNotifications(settingsSnapshot, generation: generation) { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.finishApplySettingsRun()
                        }
                    }
                case .denied:
                    self.statusMessage = "Notification permission denied in System Settings."
                    self.finishApplySettingsRun()
                case .notDetermined:
                    // Re-request when status is not determined. This avoids getting stuck after
                    // app rebuild/re-sign where the system permission can reset while local
                    // defaults still indicate a previous prompt.
                    self.scheduler.requestPermission { [weak self] granted, errorMessage in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard generation == self.applySettingsGeneration else {
                                self.finishApplySettingsRun()
                                return
                            }
                            guard granted else {
                                self.statusMessage = errorMessage ?? "Permission denied."
                                self.finishApplySettingsRun()
                                return
                            }
                            self.scheduleNotifications(settingsSnapshot, generation: generation) { [weak self] in
                                Task { @MainActor [weak self] in
                                    self?.finishApplySettingsRun()
                                }
                            }
                        }
                    }
                @unknown default:
                    self.statusMessage = "Unknown notification permission status."
                    self.finishApplySettingsRun()
                }
            }
        }
    }

    private func finishApplySettingsRun() {
        isApplySettingsInFlight = false
        startNextApplySettingsRunIfNeeded()
    }

    private func scheduleTestNotification() {
        scheduler.sendTestNotification { [weak self] errorMessage in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let errorMessage {
                    self.statusMessage = errorMessage
                } else {
                    self.statusMessage = "Test notification scheduled. It should appear in about 1 second."
                }
            }
        }
    }

    private func scheduleNotifications(
        _ settingsSnapshot: ReminderSettings,
        generation: Int,
        completion: @escaping @Sendable () -> Void
    ) {
        scheduler.apply(settings: settingsSnapshot) { status in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion()
                    return
                }
                guard generation == self.applySettingsGeneration else {
                    completion()
                    return
                }
                self.syncCalendarEventNotificationsIfNeeded(baseStatus: status, completion: completion)
            }
        }
    }

    private func syncCalendarEventNotificationsIfNeeded(
        baseStatus: String? = nil,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard shouldManageScheduling else {
            completion?()
            return
        }

        guard schedulesNotificationsOnThisMac else {
            scheduler.clearCalendarNotifications {
                completion?()
            }
            return
        }

        guard settings.isEnabled else {
            scheduler.clearCalendarNotifications { [weak self] in
                Task { @MainActor [weak self] in
                    if let baseStatus {
                        self?.statusMessage = baseStatus
                    }
                    completion?()
                }
            }
            return
        }

        let authStatus = EKEventStore.authorizationStatus(for: .event)
        guard authStatus == .fullAccess else {
            if let baseStatus {
                statusMessage = baseStatus
            }
            completion?()
            return
        }

        let items = upcomingCalendarNotificationItems()
        scheduler.replaceCalendarNotifications(items: items, leadMinutes: calendarNotificationLeadMinutes) { [weak self] calendarStatus in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                if let baseStatus {
                    if items.isEmpty {
                        self.statusMessage = baseStatus
                    } else {
                        self.statusMessage = "\(baseStatus) | \(calendarStatus)"
                    }
                }
                completion?()
            }
        }
    }

    private func upcomingCalendarNotificationItems(days: Int = 7) -> [CalendarNotificationItem] {
        let now = Date()
        let calendar = Calendar.current
        guard let endDate = calendar.date(byAdding: .day, value: max(days, 1), to: now) else {
            return []
        }

        refreshCalendarStore()
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: visibleEventCalendars()
        )
        return eventStore.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    let leftTitle = lhs.title ?? ""
                    let rightTitle = rhs.title ?? ""
                    return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
                }
                return lhs.startDate < rhs.startDate
            }
            .map { event in
                let rawTitle = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = rawTitle.isEmpty ? "Calendar Event" : rawTitle
                return CalendarNotificationItem(
                    eventID: event.eventIdentifier ?? UUID().uuidString,
                    title: title,
                    startDate: event.startDate,
                    isAllDay: event.isAllDay
                )
            }
    }

    private func observeCalendarStoreChanges() {
        calendarStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleCalendarStoreRefresh()
            }
        }
    }

    private func scheduleCalendarStoreRefresh() {
        calendarStoreRefreshTask?.cancel()
        let selectedDate = calendarEventsDate
        calendarStoreRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshCalendarEvents(for: selectedDate, requestAccessIfNeeded: false)
        }
    }

    private func refreshCalendarStore() {
        recreateEventStore()
        eventStore.refreshSourcesIfNecessary()
    }

    private func recreateEventStore() {
        if let calendarStoreObserver {
            NotificationCenter.default.removeObserver(calendarStoreObserver)
            self.calendarStoreObserver = nil
        }
        eventStore = EKEventStore()
        observeCalendarStoreChanges()
    }

    private func refreshTimestampLabel() -> String {
        Date.now.formatted(date: .omitted, time: .shortened)
    }

    private func visibleEventCalendars() -> [EKCalendar]? {
        let calendars = eventStore.calendars(for: .event)
        let disabled = disabledCalendarIdentifiers()

        guard !disabled.isEmpty else {
            return nil
        }

        let filtered = calendars.filter { !disabled.contains($0.calendarIdentifier) }
        return filtered
    }

    private func disabledCalendarIdentifiers() -> Set<String> {
        guard let raw = calendarAppDefaults?.dictionary(forKey: "DisabledCalendars") else {
            return []
        }

        let identifiers = raw.values.flatMap { value -> [String] in
            switch value {
            case let array as [String]:
                return array
            case let array as [Any]:
                return array.compactMap { $0 as? String }
            default:
                return []
            }
        }

        return Set(identifiers)
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
            lastKnownSettingsData = data
        }
    }

    private func persistTodos() {
        let normalized = Self.normalizeItems(todoItems, kind: .todo)
        todoItems = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: todosKey)
            lastKnownTodosData = data
        }
    }

    private func persistShopping() {
        let normalized = Self.normalizeItems(shoppingItems, kind: .shopping)
        shoppingItems = normalized
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: shoppingKey)
            lastKnownShoppingData = data
        }
    }

    private func startSettingsSyncPolling() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.reloadFromStoreIfNeeded(force: false)
                }
            }
        }
    }

    private func reloadFromStoreIfNeeded(force: Bool) {
        reloadSettingsFromStoreIfNeeded(force: force)
        reloadItemsFromStoreIfNeeded(force: force, forKey: todosKey, kind: .todo)
        reloadItemsFromStoreIfNeeded(force: force, forKey: shoppingKey, kind: .shopping)
    }

    private func reloadSettingsFromStoreIfNeeded(force: Bool) {
        let data = defaults.data(forKey: settingsKey)
        guard force || data != lastKnownSettingsData else {
            return
        }

        guard let data,
              let decoded = try? JSONDecoder().decode(ReminderSettings.self, from: data) else {
            return
        }

        lastKnownSettingsData = data
        let normalizedDecoded = Self.normalized(decoded)
        guard normalizedDecoded != settings else { return }

        settings = normalizedDecoded
        applyMouseMoverSettings()
        statusMessage = schedulesNotificationsOnThisMac
            ? (normalizedDecoded.isEnabled ? "Notifications are active." : "Reminders are off.")
            : localSchedulingDisabledMessage
    }

    private func reloadItemsFromStoreIfNeeded(force: Bool, forKey key: String, kind: AssistantItemKind) {
        let data = defaults.data(forKey: key)
        let lastKnown: Data? = switch key {
        case todosKey: lastKnownTodosData
        case shoppingKey: lastKnownShoppingData
        default: nil
        }
        guard force || data != lastKnown else {
            return
        }

        let loaded = Self.loadItems(from: defaults, forKey: key, kind: kind)
        switch key {
        case todosKey:
            lastKnownTodosData = loaded.data
            if loaded.items != todoItems {
                todoItems = loaded.items
            }
        case shoppingKey:
            lastKnownShoppingData = loaded.data
            if loaded.items != shoppingItems {
                shoppingItems = loaded.items
            }
        default:
            break
        }
    }

    private static func loadItems(from defaults: UserDefaults, forKey key: String, kind: AssistantItemKind) -> (items: [AssistantItem], data: Data?) {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AssistantItem].self, from: data) else {
            return ([], nil)
        }
        return (normalizeItems(decoded, kind: kind), data)
    }

    private static func normalizeItems(_ items: [AssistantItem], kind: AssistantItemKind) -> [AssistantItem] {
        items
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sortOrder < rhs.sortOrder
            }
            .enumerated()
            .map { index, item in
                var normalized = item
                normalized.kind = kind
                normalized.sortOrder = index
                if normalized.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    normalized.title = kind == .todo ? "Untitled Task" : "Untitled Item"
                }
                return normalized
            }
    }

    private func nextSortOrder(in items: [AssistantItem]) -> Int {
        (items.map(\.sortOrder).max() ?? -1) + 1
    }

    private func reindexTodoSortOrder() {
        todoItems = Self.normalizeItems(todoItems, kind: .todo)
    }

    private func reindexShoppingSortOrder() {
        shoppingItems = Self.normalizeItems(shoppingItems, kind: .shopping)
    }

    private func validate(_ candidate: ReminderSettings) -> String? {
        guard candidate.intervalMinutes > 0 else {
            return "Interval must be greater than 0."
        }
        guard candidate.standMinutes > 0 else {
            return "Stand duration must be greater than 0."
        }
        guard !candidate.periods.isEmpty else {
            return "Add at least one period."
        }
        guard candidate.periods.allSatisfy(\.isValid) else {
            return "Each period must end after it starts."
        }
        guard candidate.activeDays.contains(true) else {
            return "Select at least one active day."
        }
        return nil
    }

    private static func normalized(_ candidate: ReminderSettings) -> ReminderSettings {
        var normalized = candidate
        normalized.mouseMoverIdleThresholdMinutes = max(1, min(60, normalized.mouseMoverIdleThresholdMinutes))
        normalized.mouseMoverMoveIntervalMinutes = max(1, min(60, normalized.mouseMoverMoveIntervalMinutes))
        if normalized.extraReminders.isEmpty {
            normalized.extraReminders = ReminderSettings.defaultExtraReminders
        }
        normalized.extraReminders = normalized.extraReminders.map { reminder in
            var mapped = reminder
            let lowered = mapped.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "学习时间" || lowered == "study time" {
                mapped.title = "Study Time"
            } else if lowered == "晚饭时间" || lowered == "dinner time" {
                mapped.title = "Dinner Time"
            } else if lowered == "事项提醒" {
                mapped.title = "Item Reminder"
            }
            return mapped
        }
        return normalized
    }

    private func applyMouseMoverSettings() {
        mouseMover.setConfiguration(
            idleThresholdSeconds: TimeInterval(settings.mouseMoverIdleThresholdMinutes * 60),
            minimumMoveGapSeconds: TimeInterval(settings.mouseMoverMoveIntervalMinutes * 60)
        )
        mouseMover.setEnabled(settings.isMouseMoverEnabled)
    }

    private var localSchedulingDisabledMessage: String {
        "This Mac (\(machineDisplayName)) is view-only for reminders. Existing local notifications were cleared and no new ones will be scheduled here."
    }

    nonisolated private static func pendingNotificationDebugItem(from request: UNNotificationRequest) -> NotificationDebugItem {
        let triggerDebug = triggerDebugMetadata(for: request.trigger)
        return NotificationDebugItem(
            id: request.identifier,
            identifier: request.identifier,
            sourceLabel: notificationSourceLabel(for: request.identifier),
            title: request.content.title,
            body: request.content.body,
            threadIdentifier: request.content.threadIdentifier,
            categoryIdentifier: request.content.categoryIdentifier,
            triggerSummary: triggerDebug.summary,
            nextTriggerDate: nextTriggerDate(for: request.trigger),
            deliveredAt: nil,
            repeats: triggerDebug.repeats,
            scheduledWeekday: triggerDebug.weekday,
            scheduledHour: triggerDebug.hour,
            scheduledMinute: triggerDebug.minute
        )
    }

    nonisolated private static func deliveredNotificationDebugItem(from notification: UNNotification) -> NotificationDebugItem {
        let triggerDebug = triggerDebugMetadata(for: notification.request.trigger)
        return NotificationDebugItem(
            id: notification.request.identifier,
            identifier: notification.request.identifier,
            sourceLabel: notificationSourceLabel(for: notification.request.identifier),
            title: notification.request.content.title,
            body: notification.request.content.body,
            threadIdentifier: notification.request.content.threadIdentifier,
            categoryIdentifier: notification.request.content.categoryIdentifier,
            triggerSummary: triggerDebug.summary,
            nextTriggerDate: nextTriggerDate(for: notification.request.trigger),
            deliveredAt: notification.date,
            repeats: triggerDebug.repeats,
            scheduledWeekday: triggerDebug.weekday,
            scheduledHour: triggerDebug.hour,
            scheduledMinute: triggerDebug.minute
        )
    }

    nonisolated private static func sortPendingNotificationDebugItems(_ lhs: NotificationDebugItem, _ rhs: NotificationDebugItem) -> Bool {
        switch (lhs.nextTriggerDate, rhs.nextTriggerDate) {
        case let (left?, right?):
            if left == right {
                return lhs.identifier < rhs.identifier
            }
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.identifier < rhs.identifier
        }
    }

    nonisolated private static func sortDeliveredNotificationDebugItems(_ lhs: NotificationDebugItem, _ rhs: NotificationDebugItem) -> Bool {
        switch (lhs.deliveredAt, rhs.deliveredAt) {
        case let (left?, right?):
            if left == right {
                return lhs.identifier < rhs.identifier
            }
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.identifier < rhs.identifier
        }
    }

    nonisolated private static func notificationSourceLabel(for identifier: String) -> String {
        if identifier.hasPrefix("standup-reminder-stand-") {
            return "Stand-up"
        }
        if identifier.hasPrefix("standup-reminder-custom-") {
            return "Custom Item"
        }
        if identifier.hasPrefix("standup-reminder-calendar-") {
            return "Calendar"
        }
        if identifier.hasPrefix("standup-reminder-test-") {
            return "Test"
        }
        return "Other"
    }

    nonisolated private static func notificationAuthorizationDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Not Determined"
        case .denied:
            return "Denied"
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }

    nonisolated private static func triggerDebugMetadata(for trigger: UNNotificationTrigger?) -> (
        summary: String,
        repeats: Bool,
        weekday: Int?,
        hour: Int?,
        minute: Int?
    ) {
        guard let trigger else {
            return ("No trigger", false, nil, nil, nil)
        }

        if let calendarTrigger = trigger as? UNCalendarNotificationTrigger {
            let components = calendarTrigger.dateComponents
            let timeText = timeText(
                hour: components.hour,
                minute: components.minute,
                fallbackDate: calendarTrigger.nextTriggerDate()
            )
            let weekdayText = weekdayText(components.weekday)
            let summary: String

            if calendarTrigger.repeats {
                let dayPrefix = weekdayText.map { "\($0) " } ?? ""
                summary = "Calendar repeat · \(dayPrefix)\(timeText ?? "unknown time")"
            } else if let nextTriggerDate = calendarTrigger.nextTriggerDate() {
                summary = "Calendar once · \(nextTriggerDate.formatted(date: .abbreviated, time: .shortened))"
            } else {
                summary = "Calendar once"
            }

            return (summary, calendarTrigger.repeats, components.weekday, components.hour, components.minute)
        }

        if let intervalTrigger = trigger as? UNTimeIntervalNotificationTrigger {
            let seconds = Int(intervalTrigger.timeInterval)
            let summary = intervalTrigger.repeats
                ? "Time interval repeat · \(seconds)s"
                : "Time interval once · \(seconds)s"
            return (summary, intervalTrigger.repeats, nil, nil, nil)
        }

        return ("Other trigger", trigger.repeats, nil, nil, nil)
    }

    nonisolated private static func nextTriggerDate(for trigger: UNNotificationTrigger?) -> Date? {
        if let calendarTrigger = trigger as? UNCalendarNotificationTrigger {
            return calendarTrigger.nextTriggerDate()
        }
        if let intervalTrigger = trigger as? UNTimeIntervalNotificationTrigger {
            return intervalTrigger.nextTriggerDate()
        }
        return nil
    }

    nonisolated private static func weekdayText(_ weekday: Int?) -> String? {
        guard let weekday else { return nil }
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return nil }
        return symbols[index]
    }

    nonisolated private static func timeText(hour: Int?, minute: Int?, fallbackDate: Date?) -> String? {
        if let hour, let minute {
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            if let date = Calendar.current.date(from: components) {
                return date.formatted(date: .omitted, time: .shortened)
            }
        }

        if let fallbackDate {
            return fallbackDate.formatted(date: .omitted, time: .shortened)
        }

        return nil
    }

    private static func currentMachineName() -> String {
        let localizedName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !localizedName.isEmpty {
            return localizedName
        }

        let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? "This Mac" : hostName
    }

    private static func acquireSchedulingLock() -> Int32? {
        let lockPath = NSTemporaryDirectory().appending("com.haotingyi.standupreminder.scheduler.lock")
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return fd
        }
        close(fd)
        return nil
    }
}
