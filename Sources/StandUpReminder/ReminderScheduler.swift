import Foundation
@preconcurrency import UserNotifications

final class ReminderScheduler: @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "standup-reminder-"
    private let calendar = Calendar.current

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

    func clearAll(completion: (@Sendable () -> Void)? = nil) {
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(self.identifierPrefix) }
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
            completion?()
        }
    }

    func apply(settings: ReminderSettings, completion: @escaping @Sendable (String) -> Void) {
        clearAll { [weak self] in
            guard let self else { return }

            guard settings.isEnabled else {
                completion("Reminders are off.")
                return
            }

            let schedule = self.buildWeekdaySchedule(settings: settings)
            guard !schedule.isEmpty else {
                completion("No reminders scheduled. Check period settings.")
                return
            }

            if schedule.count > 64 {
                completion("Too many reminders (\(schedule.count)). Reduce periods or increase interval.")
                return
            }

            let group = DispatchGroup()
            let counter = FailureCounter()

            for (index, item) in schedule.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = "Stand Up Reminder"
                content.body = "Stand up now and take a \(settings.standMinutes)-minute break."
                content.subtitle = "Healthy Break"
                content.threadIdentifier = "standup-reminders"
                content.categoryIdentifier = "standup.category"
                content.sound = .default

                var components = DateComponents()
                components.weekday = item.weekday
                components.hour = item.hour
                components.minute = item.minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let identifier = "\(identifierPrefix)\(index)-w\(item.weekday)-\(item.hour)-\(item.minute)"
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

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
                    completion("Scheduled \(schedule.count) weekly reminders.")
                } else {
                    completion("Scheduled \(schedule.count - failures)/\(schedule.count) reminders.")
                }
            }
        }
    }

    private func buildWeekdaySchedule(settings: ReminderSettings) -> [(weekday: Int, hour: Int, minute: Int)] {
        // App day index 0...6 is Mon...Sun mapped to Calendar weekday values.
        let weekdayMap = [2, 3, 4, 5, 6, 7, 1]
        let weekdays = weekdayMap.enumerated().compactMap { index, weekday -> Int? in
            guard settings.activeDays.indices.contains(index), settings.activeDays[index] else {
                return nil
            }
            return weekday
        }
        var daySlots: [(hour: Int, minute: Int)] = []

        for period in settings.periods where period.isValid {
            var cursor = period.startMinutes
            while cursor <= period.endMinutes {
                daySlots.append((hour: cursor / 60, minute: cursor % 60))
                cursor += settings.intervalMinutes
            }
        }

        let uniqueSlots = Dictionary(grouping: daySlots, by: { "\($0.hour):\($0.minute)" })
            .compactMap { $0.value.first }
            .sorted { lhs, rhs in
                (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
            }

        var output: [(weekday: Int, hour: Int, minute: Int)] = []
        for weekday in weekdays {
            for slot in uniqueSlots {
                output.append((weekday: weekday, hour: slot.hour, minute: slot.minute))
            }
        }
        return output
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: minutesToDate(range.startMinutes))
        let end = formatter.string(from: minutesToDate(range.endMinutes))
        return "\(start)-\(end)"
    }
}
