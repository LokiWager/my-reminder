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
    private let planner = ReminderSchedulePlanner()
    private let clearRetryDelay: TimeInterval = 0.2
    private let clearRetryAttempts = 40

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

            let validLeadMinutes = 5
            let plans = self.planner.upcomingCalendarNotificationPlans(
                items: items,
                leadMinutes: validLeadMinutes
            )

            guard !plans.isEmpty else {
                completion("No upcoming calendar reminders to schedule.")
                return
            }

            let requests = plans.map(self.makeCalendarRequest)
            self.scheduleRequests(requests) { result in
                if result.failures == 0 {
                    completion("Scheduled \(result.successes) calendar reminders (\(validLeadMinutes)-minute lead).")
                } else if result.successes > 0 {
                    completion("Scheduled \(result.successes) calendar reminders, \(result.failures) failed.")
                } else {
                    completion("Failed to schedule calendar reminders.")
                }
            }
        }
    }

    func clearCalendarNotifications(completion: (@Sendable () -> Void)? = nil) {
        let group = DispatchGroup()
        let storage = NotificationIdentifierStorage()

        group.enter()
        center.getPendingNotificationRequests { requests in
            storage.setPending(
                requests
                .map(\.identifier)
                .filter { $0.hasPrefix("standup-reminder-calendar-") }
            )
            group.leave()
        }

        group.enter()
        center.getDeliveredNotifications { notifications in
            storage.setDelivered(
                notifications
                .map(\.request.identifier)
                .filter { $0.hasPrefix("standup-reminder-calendar-") }
            )
            group.leave()
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self else { return }
            let identifiers = storage.snapshot()

            if !identifiers.pending.isEmpty {
                self.center.removePendingNotificationRequests(withIdentifiers: identifiers.pending)
            }
            if !identifiers.delivered.isEmpty {
                self.center.removeDeliveredNotifications(withIdentifiers: identifiers.delivered)
            }

            self.waitForPendingRequestsToClear(
                attemptsLeft: self.clearRetryAttempts,
                filter: { $0.identifier.hasPrefix("standup-reminder-calendar-") }
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
            identifier: "standup-reminder-test-\(Int(Date().timeIntervalSince1970))",
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

            let plans = self.planner.recurringNotificationPlans(settings: settings)
            guard !plans.isEmpty else {
                completion("No reminders scheduled. Check periods or custom reminders.")
                return
            }

            let requests = plans.map(self.makeRecurringRequest)
            self.scheduleRequests(requests) { result in
                if result.failures == 0 {
                    completion("Scheduled \(result.successes) recurring reminders.")
                } else if result.successes > 0 {
                    completion("Scheduled \(result.successes) recurring reminders, \(result.failures) failed.")
                } else {
                    completion("Failed to schedule reminders.")
                }
            }
        }
    }

    private func makeRecurringRequest(from plan: ReminderSchedulePlanner.RecurringNotificationPlan) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.threadIdentifier = plan.threadIdentifier
        content.categoryIdentifier = "standup.category"
        content.sound = .default

        var components = DateComponents()
        components.timeZone = .autoupdatingCurrent
        components.weekday = plan.weekday
        components.hour = plan.hour
        components.minute = plan.minute

        return UNNotificationRequest(
            identifier: plan.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
    }

    private func makeCalendarRequest(from plan: ReminderSchedulePlanner.CalendarNotificationPlan) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.threadIdentifier = "calendar-reminders"
        content.categoryIdentifier = "standup.category"
        content.sound = .default

        return UNNotificationRequest(
            identifier: plan.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: plan.dateComponents, repeats: false)
        )
    }

    private func scheduleRequests(
        _ requests: [UNNotificationRequest],
        completion: @escaping @Sendable (ScheduleResult) -> Void
    ) {
        guard !requests.isEmpty else {
            completion(ScheduleResult(successes: 0, failures: 0))
            return
        }

        let group = DispatchGroup()
        let resultStorage = ScheduleResultStorage()

        for request in requests {
            group.enter()
            center.add(request) { error in
                resultStorage.record(error: error)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(resultStorage.snapshot())
        }
    }

    private struct ScheduleResult: Sendable {
        let successes: Int
        let failures: Int
    }

    private final class NotificationIdentifierStorage: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.haotingyi.standupreminder.notification-identifiers")
        private var pending: [String] = []
        private var delivered: [String] = []

        func setPending(_ value: [String]) {
            queue.sync {
                pending = value
            }
        }

        func setDelivered(_ value: [String]) {
            queue.sync {
                delivered = value
            }
        }

        func snapshot() -> (pending: [String], delivered: [String]) {
            queue.sync {
                (pending, delivered)
            }
        }
    }

    private final class ScheduleResultStorage: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.haotingyi.standupreminder.schedule-results")
        private var successes = 0
        private var failures = 0

        func record(error: (any Error)?) {
            queue.sync {
                if error == nil {
                    successes += 1
                } else {
                    failures += 1
                }
            }
        }

        func snapshot() -> ScheduleResult {
            queue.sync {
                ScheduleResult(successes: successes, failures: failures)
            }
        }
    }
}
