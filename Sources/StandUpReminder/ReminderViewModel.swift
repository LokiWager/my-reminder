import Foundation
import EventKit
import SwiftUI
import UserNotifications
import WidgetKit

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

    private let scheduler = ReminderScheduler()
    private let eventStore = EKEventStore()
    private let appGroupID = "group.com.haotingyi.standupreminder"
    private let settingsKey = "standup.settings.v1"
    private let todosKey = "assistant.todos.v1"
    private let shoppingKey = "assistant.shopping.v1"
    private let notificationPermissionPromptedKey = "standup.notifications.prompted.v1"
    private let calendarNotificationLeadMinutes = 5
    private let defaults: UserDefaults
    private let standardDefaults = UserDefaults.standard

    private var lastKnownSettingsData: Data?
    private var lastKnownTodosData: Data?
    private var lastKnownShoppingData: Data?
    private var syncTask: Task<Void, Never>?

    init() {
        let groupDefaults = UserDefaults(suiteName: appGroupID) ?? .standard
        defaults = groupDefaults

        if groupDefaults.data(forKey: settingsKey) == nil,
           let legacyData = standardDefaults.data(forKey: settingsKey) {
            groupDefaults.set(legacyData, forKey: settingsKey)
        }
        if groupDefaults.data(forKey: todosKey) == nil,
           let legacyData = standardDefaults.data(forKey: todosKey) {
            groupDefaults.set(legacyData, forKey: todosKey)
        }
        if groupDefaults.data(forKey: shoppingKey) == nil,
           let legacyData = standardDefaults.data(forKey: shoppingKey) {
            groupDefaults.set(legacyData, forKey: shoppingKey)
        }
        if !groupDefaults.bool(forKey: notificationPermissionPromptedKey),
           standardDefaults.bool(forKey: notificationPermissionPromptedKey) {
            groupDefaults.set(true, forKey: notificationPermissionPromptedKey)
        }

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

        applySettings()
        startSettingsSyncPolling()
    }

    deinit {
        syncTask?.cancel()
    }

    var pendingTodoCount: Int {
        todoItems.filter { !$0.isCompleted }.count
    }

    var pendingShoppingCount: Int {
        shoppingItems.filter { !$0.isCompleted }.count
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

    func refreshFromStore() {
        reloadFromStoreIfNeeded(force: true)
        if calendarAccessState == .granted {
            refreshCalendarEvents(for: calendarEventsDate, requestAccessIfNeeded: false)
        }
    }

    func periodSummary() -> String {
        let periodSummary = settings.periods
            .enumerated()
            .map { index, period in
                "Period \(index + 1): \(ReminderScheduler.formatRange(period))"
            }
            .joined(separator: "   ")

        let customSummary = settings.extraReminders
            .filter(\.isEnabled)
            .map { "\($0.title): \(ReminderScheduler.formatMinutes($0.timeMinutes))" }
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
                    self.loadCalendarEvents(for: dayStart)
                    self.syncCalendarEventNotificationsIfNeeded()
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

        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
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
            calendarStatusMessage = "No events for selected date."
        } else {
            let dateLabel = dayStart.formatted(date: .abbreviated, time: .omitted)
            calendarStatusMessage = "\(calendarEvents.count) events on \(dateLabel)."
        }
    }

    private func applySettings() {
        persistSettings()

        guard settings.isEnabled else {
            scheduler.clearAll { [weak self] in
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Reminders are off."
                }
            }
            return
        }

        let settingsSnapshot = settings
        scheduler.notificationAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.scheduleNotifications(settingsSnapshot)
                case .denied:
                    self.statusMessage = "Notification permission denied in System Settings."
                case .notDetermined:
                    if self.notificationPermissionPrompted() {
                        self.statusMessage = "Notification permission not granted. Enable it in System Settings."
                        return
                    }
                    self.markNotificationPermissionPrompted()
                    self.scheduler.requestPermission { [weak self] granted, errorMessage in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard granted else {
                                self.statusMessage = errorMessage ?? "Permission denied."
                                return
                            }
                            self.scheduleNotifications(settingsSnapshot)
                        }
                    }
                @unknown default:
                    self.statusMessage = "Unknown notification permission status."
                }
            }
        }
    }

    private func scheduleNotifications(_ settingsSnapshot: ReminderSettings) {
        scheduler.apply(settings: settingsSnapshot) { status in
            Task { @MainActor [weak self] in
                self?.syncCalendarEventNotificationsIfNeeded(baseStatus: status)
            }
        }
    }

    private func syncCalendarEventNotificationsIfNeeded(baseStatus: String? = nil) {
        guard settings.isEnabled else {
            scheduler.clearCalendarNotifications { [weak self] in
                Task { @MainActor [weak self] in
                    if let baseStatus {
                        self?.statusMessage = baseStatus
                    }
                }
            }
            return
        }

        let authStatus = EKEventStore.authorizationStatus(for: .event)
        guard authStatus == .fullAccess else {
            if let baseStatus {
                statusMessage = baseStatus
            }
            return
        }

        let items = upcomingCalendarNotificationItems()
        scheduler.replaceCalendarNotifications(items: items, leadMinutes: calendarNotificationLeadMinutes) { [weak self] calendarStatus in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let baseStatus else { return }
                if items.isEmpty {
                    self.statusMessage = baseStatus
                } else {
                    self.statusMessage = "\(baseStatus) | \(calendarStatus)"
                }
            }
        }
    }

    private func upcomingCalendarNotificationItems(days: Int = 7) -> [CalendarNotificationItem] {
        let now = Date()
        let calendar = Calendar.current
        guard let endDate = calendar.date(byAdding: .day, value: max(days, 1), to: now) else {
            return []
        }

        let predicate = eventStore.predicateForEvents(withStart: now, end: endDate, calendars: nil)
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

    private func notificationPermissionPrompted() -> Bool {
        defaults.bool(forKey: notificationPermissionPromptedKey) ||
            standardDefaults.bool(forKey: notificationPermissionPromptedKey)
    }

    private func markNotificationPermissionPrompted() {
        defaults.set(true, forKey: notificationPermissionPromptedKey)
        standardDefaults.set(true, forKey: notificationPermissionPromptedKey)
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
            lastKnownSettingsData = data
            WidgetCenter.shared.reloadAllTimelines()
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
        statusMessage = normalizedDecoded.isEnabled ? "Notifications are active." : "Reminders are off."
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
}
