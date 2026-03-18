import Foundation

struct ReminderSchedulePlanner {
    struct RecurringNotificationPlan: Sendable, Equatable {
        let identifier: String
        let title: String
        let body: String
        let threadIdentifier: String
        let weekday: Int
        let hour: Int
        let minute: Int
    }

    struct CalendarNotificationPlan: Sendable, Equatable {
        let identifier: String
        let title: String
        let body: String
        let dateComponents: DateComponents
    }

    private let calendar: Calendar
    private let identifierPrefix = "standup-reminder-"
    private let calendarIdentifierPrefix = "standup-reminder-calendar-"
    private let weekdayMap = [2, 3, 4, 5, 6, 7, 1]

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func recurringNotificationPlans(settings: ReminderSettings) -> [RecurringNotificationPlan] {
        var plans: [RecurringNotificationPlan] = []
        let standSlots = dailyStandSlots(settings: settings)

        for (dayIndex, weekday) in weekdayMap.enumerated() {
            guard settings.activeDays.indices.contains(dayIndex), settings.activeDays[dayIndex] else { continue }

            for minute in standSlots {
                let hour = minute / 60
                let min = minute % 60
                plans.append(
                    RecurringNotificationPlan(
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
                    RecurringNotificationPlan(
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

    func upcomingCalendarNotificationPlans(
        items: [CalendarNotificationItem],
        leadMinutes: Int,
        now: Date = .now
    ) -> [CalendarNotificationPlan] {
        let validLeadMinutes = max(1, leadMinutes)

        return items.compactMap { item in
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
                guard item.startDate > now else { return nil }
                fireDate = now.addingTimeInterval(5)
            }

            var dateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            dateComponents.timeZone = .autoupdatingCurrent

            let body = item.isAllDay
                ? "All-day event today."
                : "Starting soon in \(validLeadMinutes) minutes."

            return CalendarNotificationPlan(
                identifier: "\(calendarIdentifierPrefix)\(sanitizedIdentifierFragment(for: item.eventID))-\(Int(item.startDate.timeIntervalSince1970))",
                title: item.title,
                body: body,
                dateComponents: dateComponents
            )
        }
    }

    func dailyStandSlots(settings: ReminderSettings) -> [Int] {
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

    func nextStandReminderDate(
        from date: Date,
        settings: ReminderSettings,
        inCurrentWindowOnly: Bool = false,
        searchDays: Int = 14
    ) -> Date? {
        guard settings.intervalMinutes > 0 else {
            return nil
        }

        let dayStart = calendar.startOfDay(for: date)
        let slots = dailyStandSlots(settings: settings)
        guard !slots.isEmpty else {
            return nil
        }

        for offset in 0...max(searchDays, 0) {
            if inCurrentWindowOnly && offset > 0 {
                break
            }

            guard let targetDay = calendar.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            guard isActiveDay(targetDay, settings: settings) else { continue }

            for minute in slots {
                let hour = minute / 60
                let min = minute % 60
                guard let reminderDate = calendar.date(bySettingHour: hour, minute: min, second: 0, of: targetDay) else {
                    continue
                }

                if inCurrentWindowOnly {
                    guard isInSameActiveWindow(reminderMinute: minute, currentDate: date, settings: settings) else {
                        continue
                    }
                }

                if reminderDate > date {
                    return reminderDate
                }
            }
        }

        return nil
    }

    func isActiveDay(_ date: Date, settings: ReminderSettings) -> Bool {
        let mondayIndex = weekdayIndex(for: date)
        return settings.activeDays.indices.contains(mondayIndex) && settings.activeDays[mondayIndex]
    }

    func isInActiveWindow(_ date: Date, settings: ReminderSettings) -> Bool {
        guard isActiveDay(date, settings: settings) else {
            return false
        }

        let minute = minuteOfDay(for: date)
        return settings.periods.contains { period in
            period.isValid && minute >= period.startMinutes && minute <= period.endMinutes
        }
    }

    func standReminderProgress(at date: Date, settings: ReminderSettings) -> (done: Int, total: Int) {
        let slots = dailyStandSlots(settings: settings)
        guard isActiveDay(date, settings: settings) else {
            return (0, slots.count)
        }

        let minuteNow = minuteOfDay(for: date)
        let done = slots.filter { $0 <= minuteNow }.count
        return (done, slots.count)
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

    private func minuteOfDay(for date: Date) -> Int {
        (calendar.component(.hour, from: date) * 60) + calendar.component(.minute, from: date)
    }

    private func weekdayIndex(for date: Date) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday + 5) % 7
    }

    private func isInSameActiveWindow(reminderMinute: Int, currentDate: Date, settings: ReminderSettings) -> Bool {
        let currentMinute = minuteOfDay(for: currentDate)
        return settings.periods.contains { period in
            period.isValid &&
                currentMinute >= period.startMinutes &&
                currentMinute <= period.endMinutes &&
                reminderMinute >= period.startMinutes &&
                reminderMinute <= period.endMinutes
        }
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

    private func sanitizedIdentifierFragment(for value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }

        let fragment = String(mapped.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return fragment.isEmpty ? "event" : fragment
    }
}
