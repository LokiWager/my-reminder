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
    private let identifierPrefix = "standup-reminder-"
    private let calendarIdentifierPrefix = "standup-reminder-calendar-"
    // Keep request volume safely below usernotificationsd limits to avoid silent drops.
    private let maxPendingBudget = 64
    private let calendarRequestBudget = 8
    private let reservedRequestSlots = 2

    private struct NotificationPlan {
        let identifier: String
        let title: String
        let body: String
        let threadIdentifier: String
        let weekday: Int
        let hour: Int
        let minute: Int
    }

    private final class FailureCounter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func current() -> Int {
            lock.lock()
            let v = value
            lock.unlock()
            return v
        }
    }

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
        center.getPendingNotificationRequests { [weak self] _ in
            guard let self else { return }
            // Remove every pending request for this app to prevent duplicate alerts
            // from older identifier formats or previously built app variants.
            self.center.removeAllPendingNotificationRequests()
            self.center.removeAllDeliveredNotifications()
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

            let now = Date()
            let validLeadMinutes = max(0, leadMinutes)
            let calendar = Calendar.current
            let requests: [UNNotificationRequest] = items.compactMap { item in
                let targetFireDate: Date
                if item.isAllDay {
                    let dayStart = calendar.startOfDay(for: item.startDate)
                    targetFireDate = calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? dayStart
                } else {
                    targetFireDate = item.startDate.addingTimeInterval(TimeInterval(-60 * validLeadMinutes))
                }
                let fireDate: Date
                if targetFireDate > now {
                    fireDate = targetFireDate
                } else {
                    // If already inside the lead window but event has not started,
                    // fire quickly instead of dropping this reminder.
                    guard item.startDate > now else { return nil }
                    fireDate = now.addingTimeInterval(5)
                }

                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = "Starting soon in \(validLeadMinutes) minutes."
                content.threadIdentifier = "calendar-reminders"
                content.categoryIdentifier = "standup.category"
                content.sound = .default

                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                components.second = 0
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(
                    identifier: "\(self.calendarIdentifierPrefix)\(abs(item.eventID.hashValue))-\(Int(item.startDate.timeIntervalSince1970))",
                    content: content,
                    trigger: trigger
                )
                return request
            }

            guard !requests.isEmpty else {
                completion("No upcoming calendar notifications to schedule.")
                return
            }

            let cappedRequests = Array(requests.prefix(calendarRequestBudget))
            let group = DispatchGroup()
            let counter = FailureCounter()

            for request in cappedRequests {
                group.enter()
                self.center.add(request) { error in
                    if error != nil {
                        counter.increment()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                let failures = counter.current()
                if failures == 0 {
                    if requests.count > cappedRequests.count {
                        completion("Scheduled \(cappedRequests.count)/\(requests.count) calendar reminders (system limit).")
                    } else {
                        completion("Scheduled \(cappedRequests.count) calendar reminders.")
                    }
                } else {
                    completion("Scheduled \(cappedRequests.count - failures)/\(cappedRequests.count) calendar reminders.")
                }
            }
        }
    }

    func clearCalendarNotifications(completion: (@Sendable () -> Void)? = nil) {
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(self.calendarIdentifierPrefix) }
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
            self.center.removeDeliveredNotifications(withIdentifiers: ids)
            completion?()
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

            let weeklyRequestBudget = max(1, maxPendingBudget - calendarRequestBudget - reservedRequestSlots)
            let now = Date()
            let prioritizedPlans = plans.sorted { lhs, rhs in
                let leftDate = self.nextTriggerDate(for: lhs, now: now) ?? .distantFuture
                let rightDate = self.nextTriggerDate(for: rhs, now: now) ?? .distantFuture
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                if lhs.threadIdentifier != rhs.threadIdentifier {
                    return lhs.threadIdentifier == "custom-reminders"
                }
                return lhs.identifier < rhs.identifier
            }
            let selectedPlans = Array(prioritizedPlans.prefix(weeklyRequestBudget))

            let group = DispatchGroup()
            let counter = FailureCounter()

            for plan in selectedPlans {
                let content = UNMutableNotificationContent()
                content.title = plan.title
                content.body = plan.body
                content.threadIdentifier = plan.threadIdentifier
                content.categoryIdentifier = "standup.category"
                content.sound = .default

                var components = DateComponents()
                components.weekday = plan.weekday
                components.hour = plan.hour
                components.minute = plan.minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: trigger)

                group.enter()
                center.add(request) { error in
                    if error != nil {
                        counter.increment()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                let failures = counter.current()
                if failures == 0 {
                    if selectedPlans.count < plans.count {
                        completion("Scheduled \(selectedPlans.count)/\(plans.count) weekly reminders (system limit).")
                    } else {
                        completion("Scheduled \(selectedPlans.count) weekly reminders.")
                    }
                } else {
                    completion("Scheduled \(selectedPlans.count - failures)/\(selectedPlans.count) reminders.")
                }
            }
        }
    }

    private func buildWeeklyNotificationPlans(settings: ReminderSettings) -> [NotificationPlan] {
        var plans: [NotificationPlan] = []
        let standSlots = dailyStandSlots(settings: settings)

        // App day index 0...6 is Mon...Sun mapped to Calendar weekday values.
        let weekdayMap = [2, 3, 4, 5, 6, 7, 1]

        for (dayIndex, weekday) in weekdayMap.enumerated() {
            guard settings.activeDays.indices.contains(dayIndex), settings.activeDays[dayIndex] else { continue }

            for (slotIndex, minute) in standSlots.enumerated() {
                let hour = minute / 60
                let min = minute % 60
                plans.append(
                    NotificationPlan(
                        identifier: "\(identifierPrefix)stand-\(dayIndex)-\(slotIndex)-\(hour)-\(min)",
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

        for (reminderIndex, reminder) in settings.extraReminders.enumerated() where reminder.isEnabled {
            let trimmedTitle = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { continue }
            let reminderDays = reminder.activeDays.count == 7 ? reminder.activeDays : ReminderSettings.default.activeDays

            for (dayIndex, weekday) in weekdayMap.enumerated() {
                guard reminderDays[dayIndex] else { continue }
                let hour = max(0, min(23, reminder.timeMinutes / 60))
                let minute = max(0, min(59, reminder.timeMinutes % 60))

                plans.append(
                    NotificationPlan(
                        identifier: "\(identifierPrefix)custom-\(reminderIndex)-\(dayIndex)-\(hour)-\(minute)",
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
