import Foundation
@preconcurrency import UserNotifications

struct CalendarNotificationItem: Sendable {
    let eventID: String
    let title: String
    let startDate: Date
    let isAllDay: Bool
}

final class ReminderScheduler: @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let runtimeQueue = DispatchQueue(label: "com.haotingyi.standupreminder.runtime-scheduler")
    private let identifierPrefix = "standup-reminder-"
    private let calendarIdentifierPrefix = "standup-reminder-calendar-"
    private let clearRetryDelay: TimeInterval = 0.2
    private let clearRetryAttempts = 40
    private let runtimeTimerLeeway: DispatchTimeInterval = .milliseconds(400)
    private let runtimeDueTolerance: TimeInterval = 0.8

    private struct NotificationPlan {
        let identifier: String
        let title: String
        let body: String
        let threadIdentifier: String
        let weekday: Int
        let hour: Int
        let minute: Int
    }

    private struct ScheduledOccurrence {
        let fireDate: Date
        let plan: NotificationPlan
        let sequence: UInt64
    }

    private struct CalendarScheduledOccurrence {
        let fireDate: Date
        let identifier: String
        let title: String
        let body: String
        let sequence: UInt64
    }

    private struct OccurrenceHeap {
        private(set) var storage: [ScheduledOccurrence] = []

        var count: Int { storage.count }

        func peek() -> ScheduledOccurrence? { storage.first }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
        }

        mutating func push(_ value: ScheduledOccurrence) {
            storage.append(value)
            siftUp(from: storage.count - 1)
        }

        mutating func popMin() -> ScheduledOccurrence? {
            guard !storage.isEmpty else { return nil }
            if storage.count == 1 {
                return storage.removeLast()
            }

            let first = storage[0]
            storage[0] = storage.removeLast()
            siftDown(from: 0)
            return first
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.isHigherPriority(storage[child], than: storage[parent]) else { return }
                storage.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = (parent * 2) + 1
                let right = left + 1
                var best = parent

                if left < storage.count, Self.isHigherPriority(storage[left], than: storage[best]) {
                    best = left
                }
                if right < storage.count, Self.isHigherPriority(storage[right], than: storage[best]) {
                    best = right
                }

                guard best != parent else { return }
                storage.swapAt(parent, best)
                parent = best
            }
        }

        private static func isHigherPriority(_ lhs: ScheduledOccurrence, than rhs: ScheduledOccurrence) -> Bool {
            if lhs.fireDate != rhs.fireDate {
                return lhs.fireDate < rhs.fireDate
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private struct CalendarOccurrenceHeap {
        private(set) var storage: [CalendarScheduledOccurrence] = []

        func peek() -> CalendarScheduledOccurrence? { storage.first }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
        }

        mutating func push(_ value: CalendarScheduledOccurrence) {
            storage.append(value)
            siftUp(from: storage.count - 1)
        }

        mutating func popMin() -> CalendarScheduledOccurrence? {
            guard !storage.isEmpty else { return nil }
            if storage.count == 1 {
                return storage.removeLast()
            }

            let first = storage[0]
            storage[0] = storage.removeLast()
            siftDown(from: 0)
            return first
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.isHigherPriority(storage[child], than: storage[parent]) else { return }
                storage.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = (parent * 2) + 1
                let right = left + 1
                var best = parent

                if left < storage.count, Self.isHigherPriority(storage[left], than: storage[best]) {
                    best = left
                }
                if right < storage.count, Self.isHigherPriority(storage[right], than: storage[best]) {
                    best = right
                }

                guard best != parent else { return }
                storage.swapAt(parent, best)
                parent = best
            }
        }

        private static func isHigherPriority(_ lhs: CalendarScheduledOccurrence, than rhs: CalendarScheduledOccurrence) -> Bool {
            if lhs.fireDate != rhs.fireDate {
                return lhs.fireDate < rhs.fireDate
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private var runtimeHeap = OccurrenceHeap()
    private var runtimeTimer: DispatchSourceTimer?
    private var nextRuntimeSequence: UInt64 = 0
    private var calendarHeap = CalendarOccurrenceHeap()
    private var calendarTimer: DispatchSourceTimer?
    private var nextCalendarSequence: UInt64 = 0

    func requestPermission(completion: @escaping @Sendable (Bool, String?) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                completion(false, "Permission request failed: \(error.localizedDescription)")
                return
            }
            completion(granted, granted ? nil : "Notification permission denied in System Settings.")
        }
    }

    func notificationAuthorizationStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    func clearAll(completion: (@Sendable () -> Void)? = nil) {
        stopAllInProcessSchedulers()
        // Remove every pending request for this app to prevent duplicate alerts
        // from older identifier formats or previously built app variants.
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        waitForPendingRequestsToClear(
            attemptsLeft: clearRetryAttempts,
            filter: { _ in true }
        ) {
            completion?()
        }
    }

    func replaceCalendarNotifications(
        items: [CalendarNotificationItem],
        leadMinutes: Int = 5,
        completion: @escaping @Sendable (String) -> Void
    ) {
        clearCalendarNotifications { [weak self] in
            guard let self else { return }
            // Calendar reminders are always 5 minutes before the event.
            _ = leadMinutes
            let validLeadMinutes = 5
            self.armCalendarInProcessScheduler(items: items, leadMinutes: validLeadMinutes) { armedCount in
                if armedCount == 0 {
                    completion("No upcoming calendar reminders to arm.")
                } else {
                    completion("Armed \(armedCount) calendar reminders (\(validLeadMinutes)-minute lead).")
                }
            }
        }
    }

    func clearCalendarNotifications(completion: (@Sendable () -> Void)? = nil) {
        runtimeQueue.sync {
            cancelCalendarTimerLocked()
            calendarHeap.removeAll()
        }
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(self.calendarIdentifierPrefix) }
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
            self.center.removeDeliveredNotifications(withIdentifiers: ids)
            self.waitForPendingRequestsToClear(
                attemptsLeft: self.clearRetryAttempts,
                filter: { $0.identifier.hasPrefix(self.calendarIdentifierPrefix) }
            ) {
                completion?()
            }
        }
    }

    private func waitForPendingRequestsToClear(
        attemptsLeft: Int,
        filter: @escaping @Sendable (UNNotificationRequest) -> Bool,
        completion: @escaping @Sendable () -> Void
    ) {
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let remaining = requests.filter(filter)
            if remaining.isEmpty || attemptsLeft <= 0 {
                completion()
                return
            }
            self.center.removePendingNotificationRequests(withIdentifiers: remaining.map(\.identifier))
            DispatchQueue.global().asyncAfter(deadline: .now() + self.clearRetryDelay) { [weak self] in
                self?.waitForPendingRequestsToClear(
                    attemptsLeft: attemptsLeft - 1,
                    filter: filter,
                    completion: completion
                )
            }
        }
    }

    func sendTestNotification(
        title: String = "StandUpReminder Test",
        body: String = "If you can see this alert, notifications are working.",
        delaySeconds: Int = 1,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        let sanitizedDelay = max(1, min(30, delaySeconds))
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "standup-test"
        content.categoryIdentifier = "standup.category"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(sanitizedDelay),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)test-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                completion("Failed to schedule test notification: \(error.localizedDescription)")
            } else {
                completion(nil)
            }
        }
    }

    func apply(settings: ReminderSettings, completion: @escaping @Sendable (String) -> Void) {
        clearAll { [weak self] in
            guard let self else { return }

            guard settings.isEnabled else {
                completion("Reminders are off.")
                return
            }

            let plans = self.buildWeeklyNotificationPlans(settings: settings)
            guard !plans.isEmpty else {
                completion("No reminders scheduled. Check periods or custom reminders.")
                return
            }

            if plans.count > 256 {
                completion("Too many reminders (\(plans.count)). Reduce periods or custom reminders.")
                return
            }
            self.armInProcessScheduler(with: plans) { armedCount in
                if armedCount == 0 {
                    completion("No upcoming reminders found in current schedule.")
                } else {
                    completion("Armed \(armedCount) in-process reminders.")
                }
            }
        }
    }

    private func armInProcessScheduler(
        with plans: [NotificationPlan],
        completion: @escaping @Sendable (Int) -> Void
    ) {
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.cancelRuntimeTimerLocked()
            self.runtimeHeap.removeAll()

            let now = Date()
            var armedCount = 0

            for plan in plans {
                guard let fireDate = self.nextTriggerDate(for: plan, now: now.addingTimeInterval(-1)) else {
                    continue
                }
                self.runtimeHeap.push(
                    ScheduledOccurrence(
                        fireDate: fireDate,
                        plan: plan,
                        sequence: self.nextSequenceLocked()
                    )
                )
                armedCount += 1
            }

            self.scheduleNextRuntimeTimerLocked()
            DispatchQueue.main.async {
                completion(armedCount)
            }
        }
    }

    private func stopAllInProcessSchedulers() {
        runtimeQueue.sync {
            cancelRuntimeTimerLocked()
            runtimeHeap.removeAll()
            cancelCalendarTimerLocked()
            calendarHeap.removeAll()
        }
    }

    private func nextSequenceLocked() -> UInt64 {
        defer { nextRuntimeSequence &+= 1 }
        return nextRuntimeSequence
    }

    private func cancelRuntimeTimerLocked() {
        runtimeTimer?.setEventHandler {}
        runtimeTimer?.cancel()
        runtimeTimer = nil
    }

    private func cancelCalendarTimerLocked() {
        calendarTimer?.setEventHandler {}
        calendarTimer?.cancel()
        calendarTimer = nil
    }

    private func scheduleNextRuntimeTimerLocked() {
        cancelRuntimeTimerLocked()
        guard let next = runtimeHeap.peek() else { return }

        let delay = max(0, next.fireDate.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: runtimeQueue)
        timer.schedule(
            deadline: .now() + delay,
            repeating: .never,
            leeway: runtimeTimerLeeway
        )
        timer.setEventHandler { [weak self] in
            self?.processDueOccurrencesLocked()
        }
        runtimeTimer = timer
        timer.resume()
    }

    private func processDueOccurrencesLocked() {
        let now = Date()
        let dueDeadline = now.addingTimeInterval(runtimeDueTolerance)

        while let next = runtimeHeap.peek(), next.fireDate <= dueDeadline {
            _ = runtimeHeap.popMin()
            deliverImmediateNotification(plan: next.plan, scheduledAt: next.fireDate)

            // Re-arm from "now" so wake-from-sleep does not spam every missed slot.
            if let following = nextTriggerDate(for: next.plan, now: now) {
                runtimeHeap.push(
                    ScheduledOccurrence(
                        fireDate: following,
                        plan: next.plan,
                        sequence: nextSequenceLocked()
                    )
                )
            }
        }

        scheduleNextRuntimeTimerLocked()
    }

    private func armCalendarInProcessScheduler(
        items: [CalendarNotificationItem],
        leadMinutes: Int,
        completion: @escaping @Sendable (Int) -> Void
    ) {
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.cancelCalendarTimerLocked()
            self.calendarHeap.removeAll()

            let now = Date()
            let calendar = Calendar.current
            var armedCount = 0

            for item in items {
                let targetFireDate: Date
                if item.isAllDay {
                    let dayStart = calendar.startOfDay(for: item.startDate)
                    targetFireDate = calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? dayStart
                } else {
                    targetFireDate = item.startDate.addingTimeInterval(TimeInterval(-60 * leadMinutes))
                }

                let fireDate: Date
                if targetFireDate > now {
                    fireDate = targetFireDate
                } else {
                    // If already inside the lead window but event has not started,
                    // fire quickly instead of dropping this reminder.
                    guard item.startDate > now else { continue }
                    fireDate = now.addingTimeInterval(5)
                }

                let occurrence = CalendarScheduledOccurrence(
                    fireDate: fireDate,
                    identifier: "\(self.calendarIdentifierPrefix)\(abs(item.eventID.hashValue))-\(Int(item.startDate.timeIntervalSince1970))",
                    title: item.title,
                    body: "Starting soon in \(leadMinutes) minutes.",
                    sequence: self.nextCalendarSequenceLocked()
                )
                self.calendarHeap.push(occurrence)
                armedCount += 1
            }

            self.scheduleNextCalendarTimerLocked()
            DispatchQueue.main.async {
                completion(armedCount)
            }
        }
    }

    private func nextCalendarSequenceLocked() -> UInt64 {
        defer { nextCalendarSequence &+= 1 }
        return nextCalendarSequence
    }

    private func scheduleNextCalendarTimerLocked() {
        cancelCalendarTimerLocked()
        guard let next = calendarHeap.peek() else { return }

        let delay = max(0, next.fireDate.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: runtimeQueue)
        timer.schedule(
            deadline: .now() + delay,
            repeating: .never,
            leeway: runtimeTimerLeeway
        )
        timer.setEventHandler { [weak self] in
            self?.processDueCalendarOccurrencesLocked()
        }
        calendarTimer = timer
        timer.resume()
    }

    private func processDueCalendarOccurrencesLocked() {
        let now = Date()
        let dueDeadline = now.addingTimeInterval(runtimeDueTolerance)

        while let next = calendarHeap.peek(), next.fireDate <= dueDeadline {
            _ = calendarHeap.popMin()
            deliverImmediateCalendarNotification(occurrence: next)
        }

        scheduleNextCalendarTimerLocked()
    }

    private func deliverImmediateNotification(plan: NotificationPlan, scheduledAt: Date) {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.threadIdentifier = plan.threadIdentifier
        content.categoryIdentifier = "standup.category"
        content.sound = .default

        let requestIdentifier = "\(plan.identifier)-fired-\(Int(scheduledAt.timeIntervalSince1970))"
        enqueueImmediateNotification(
            identifier: requestIdentifier,
            content: content,
            dedupeDeliveredThread: plan.threadIdentifier == "standup-reminders" ? plan.threadIdentifier : nil
        )
    }

    private func deliverImmediateCalendarNotification(occurrence: CalendarScheduledOccurrence) {
        let content = UNMutableNotificationContent()
        content.title = occurrence.title
        content.body = occurrence.body
        content.threadIdentifier = "calendar-reminders"
        content.categoryIdentifier = "standup.category"
        content.sound = .default

        let requestIdentifier = "\(occurrence.identifier)-fired-\(Int(occurrence.fireDate.timeIntervalSince1970))"
        enqueueImmediateNotification(
            identifier: requestIdentifier,
            content: content,
            dedupeDeliveredThread: nil
        )
    }

    private func enqueueImmediateNotification(
        identifier: String,
        content: UNMutableNotificationContent,
        dedupeDeliveredThread: String?
    ) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        guard let dedupeDeliveredThread else {
            center.add(request)
            return
        }

        center.getDeliveredNotifications { [center] delivered in
            let staleIDs = delivered
                .filter { $0.request.content.threadIdentifier == dedupeDeliveredThread }
                .map(\.request.identifier)

            if !staleIDs.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: staleIDs)
            }
            center.add(request)
        }
    }

    private func buildWeeklyNotificationPlans(settings: ReminderSettings) -> [NotificationPlan] {
        var plans: [NotificationPlan] = []
        let standSlots = dailyStandSlots(settings: settings)

        // App day index 0...6 is Mon...Sun mapped to Calendar weekday values.
        let weekdayMap = [2, 3, 4, 5, 6, 7, 1]

        for (dayIndex, weekday) in weekdayMap.enumerated() {
            guard settings.activeDays.indices.contains(dayIndex), settings.activeDays[dayIndex] else { continue }

            for minute in standSlots {
                let hour = minute / 60
                let min = minute % 60
                plans.append(
                    NotificationPlan(
                        // Keep identifiers stable for the same weekday/time slot so repeated
                        // scheduling from different app states cannot create duplicate requests.
                        identifier: "\(identifierPrefix)stand-\(dayIndex)-\(hour)-\(min)",
                        title: "Stand Up Reminder",
                        body: "Time to stand up and take a \(settings.standMinutes)-minute break.",
                        threadIdentifier: "standup-reminders",
                        weekday: weekday,
                        hour: hour,
                        minute: min
                    )
                )
            }
        }

        for reminder in settings.extraReminders where reminder.isEnabled {
            let trimmedTitle = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { continue }
            let reminderDays = reminder.activeDays.count == 7 ? reminder.activeDays : ReminderSettings.default.activeDays

            for (dayIndex, weekday) in weekdayMap.enumerated() {
                guard reminderDays[dayIndex] else { continue }
                let hour = max(0, min(23, reminder.timeMinutes / 60))
                let minute = max(0, min(59, reminder.timeMinutes % 60))

                plans.append(
                    NotificationPlan(
                        // Use reminder UUID rather than array index to keep IDs stable if the
                        // list order changes or reminders are inserted.
                        identifier: "\(identifierPrefix)custom-\(reminder.id.uuidString)-\(dayIndex)-\(hour)-\(minute)",
                        title: trimmedTitle,
                        body: customReminderBody(for: trimmedTitle),
                        threadIdentifier: "custom-reminders",
                        weekday: weekday,
                        hour: hour,
                        minute: minute
                    )
                )
            }
        }

        return plans
    }

    private func dailyStandSlots(settings: ReminderSettings) -> [Int] {
        var slots: Set<Int> = []
        let sitInterval = max(settings.intervalMinutes, 1)
        let standBreak = max(settings.standMinutes, 1)
        let cycle = sitInterval + standBreak

        for period in settings.periods where period.isValid {
            var cursor = period.startMinutes + sitInterval
            while cursor <= period.endMinutes {
                slots.insert(cursor)
                cursor += cycle
            }
        }

        return slots.sorted()
    }

    private func customReminderBody(for title: String) -> String {
        if title.localizedCaseInsensitiveContains("dinner") {
            return "Dinner time. Refuel and recharge."
        }
        if title.localizedCaseInsensitiveContains("study") {
            return "Study time. Stay focused."
        }
        return "It is time for \(title)."
    }

    private func nextTriggerDate(for plan: NotificationPlan, now: Date) -> Date? {
        var components = DateComponents()
        components.weekday = plan.weekday
        components.hour = plan.hour
        components.minute = plan.minute
        return Calendar.current.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    static func minutesToDate(_ minutes: Int) -> Date {
        var components = DateComponents()
        components.hour = max(0, min(23, minutes / 60))
        components.minute = max(0, min(59, minutes % 60))
        return Calendar.current.date(from: components) ?? Date()
    }

    static func dateToMinutes(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return (hour * 60) + minute
    }

    static func formatRange(_ range: TimeRange) -> String {
        "\(formatMinutes(range.startMinutes)) - \(formatMinutes(range.endMinutes))"
    }

    static func formatMinutes(_ minutes: Int) -> String {
        let hour = max(0, min(23, minutes / 60))
        let min = max(0, min(59, minutes % 60))
        return String(format: "%02d:%02d", hour, min)
    }
}
