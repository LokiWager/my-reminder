import AppIntents
import SwiftUI
import UserNotifications
import WidgetKit

private let appGroupID = "group.com.haotingyi.standupreminder"
private let settingsKey = "standup.settings.v1"
private let identifierPrefix = "standup-reminder-"

private struct SharedTimeRange: Codable, Sendable {
    var startMinutes: Int
    var endMinutes: Int

    var isValid: Bool {
        startMinutes <= endMinutes
    }
}

private struct SharedReminderSettings: Codable, Sendable {
    var isEnabled: Bool
    var intervalMinutes: Int
    var standMinutes: Int
    var periods: [SharedTimeRange]
    var activeDays: [Bool]

    static let `default` = SharedReminderSettings(
        isEnabled: false,
        intervalMinutes: 45,
        standMinutes: 15,
        periods: [
            SharedTimeRange(startMinutes: 13 * 60, endMinutes: 17 * 60),
            SharedTimeRange(startMinutes: 19 * 60, endMinutes: 21 * 60)
        ],
        activeDays: [true, true, true, true, true, false, false]
    )
}

private enum SharedSettingsStore {
    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func load() -> SharedReminderSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(SharedReminderSettings.self, from: data) else {
            return .default
        }

        if decoded.activeDays.count == 7 {
            return decoded
        }

        var fixed = decoded
        fixed.activeDays = SharedReminderSettings.default.activeDays
        return fixed
    }

    static func save(_ settings: SharedReminderSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }
}

private enum WidgetNotificationScheduler {
    static func clearAll() async {
        let center = UNUserNotificationCenter.current()
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                let ids = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
                center.removePendingNotificationRequests(withIdentifiers: ids)
                continuation.resume()
            }
        }
    }

    static func apply(settings: SharedReminderSettings) async {
        await clearAll()
        guard settings.isEnabled else { return }

        let center = UNUserNotificationCenter.current()
        let schedule = buildWeekdaySchedule(settings: settings)
        guard !schedule.isEmpty else { return }

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

            await withCheckedContinuation { continuation in
                center.add(request) { _ in
                    continuation.resume()
                }
            }
        }
    }

    private static func buildWeekdaySchedule(settings: SharedReminderSettings) -> [(weekday: Int, hour: Int, minute: Int)] {
        let weekdayMap = [2, 3, 4, 5, 6, 7, 1]
        let weekdays = weekdayMap.enumerated().compactMap { index, weekday -> Int? in
            guard settings.activeDays.indices.contains(index), settings.activeDays[index] else { return nil }
            return weekday
        }

        let interval = max(settings.intervalMinutes, 1)
        var daySlots: [(hour: Int, minute: Int)] = []

        for period in settings.periods where period.isValid {
            var cursor = period.startMinutes
            while cursor <= period.endMinutes {
                daySlots.append((hour: cursor / 60, minute: cursor % 60))
                cursor += interval
            }
        }

        let uniqueSlots = Dictionary(grouping: daySlots, by: { "\($0.hour):\($0.minute)" })
            .compactMap { $0.value.first }
            .sorted { lhs, rhs in (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute) }

        var output: [(weekday: Int, hour: Int, minute: Int)] = []
        for weekday in weekdays {
            for slot in uniqueSlots {
                output.append((weekday: weekday, hour: slot.hour, minute: slot.minute))
            }
        }
        return output
    }
}

struct ToggleReminderIntent: AppIntent {
    static var title: LocalizedStringResource { "Toggle StandUp Reminder" }
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        var settings = SharedSettingsStore.load()
        settings.isEnabled.toggle()
        SharedSettingsStore.save(settings)

        WidgetCenter.shared.reloadAllTimelines()

        Task(priority: .utility) {
            if settings.isEnabled {
                await WidgetNotificationScheduler.apply(settings: settings)
            } else {
                await WidgetNotificationScheduler.clearAll()
            }
            WidgetCenter.shared.reloadAllTimelines()
        }

        return .result()
    }
}

struct StandUpReminderEntry: TimelineEntry {
    let date: Date
    let isEnabled: Bool
    let minutesLeft: Int?
    let mode: String
    let done: Int
    let total: Int
}

struct StandUpReminderProvider: TimelineProvider {
    func placeholder(in context: Context) -> StandUpReminderEntry {
        StandUpReminderEntry(date: .now, isEnabled: true, minutesLeft: 32, mode: "Sit & Focus", done: 2, total: 5)
    }

    func getSnapshot(in context: Context, completion: @escaping (StandUpReminderEntry) -> Void) {
        completion(buildEntry(for: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StandUpReminderEntry>) -> Void) {
        let now = Date()
        let next = Calendar.current.date(byAdding: .minute, value: 1, to: now) ?? now.addingTimeInterval(60)
        completion(Timeline(entries: [buildEntry(for: now)], policy: .after(next)))
    }

    private func buildEntry(for date: Date) -> StandUpReminderEntry {
        let settings = SharedSettingsStore.load()
        let progress = progressSnapshot(for: date, settings: settings)

        return StandUpReminderEntry(
            date: date,
            isEnabled: settings.isEnabled,
            minutesLeft: minutesUntilNextReminder(from: date, settings: settings),
            mode: modeText(for: date, settings: settings),
            done: progress.done,
            total: progress.total
        )
    }

    private func modeText(for date: Date, settings: SharedReminderSettings) -> String {
        guard settings.isEnabled else { return "Reminders Off" }
        return isInActiveWindow(date, settings: settings) ? "Next stand-up reminder" : "Until active period"
    }

    private func progressSnapshot(for date: Date, settings: SharedReminderSettings) -> (done: Int, total: Int) {
        let slots = dailyReminderSlots(settings: settings)
        guard !slots.isEmpty else { return (0, 0) }

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7
        guard settings.activeDays.indices.contains(mondayIndex), settings.activeDays[mondayIndex] else {
            return (0, slots.count)
        }

        let nowMinute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let done = slots.filter { $0 <= nowMinute }.count
        return (done, slots.count)
    }

    private func minutesUntilNextReminder(from date: Date, settings: SharedReminderSettings) -> Int? {
        guard settings.isEnabled, settings.intervalMinutes > 0 else { return nil }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let slots = dailyReminderSlots(settings: settings)
        guard !slots.isEmpty else { return nil }

        for offset in 0...13 {
            guard let targetDay = calendar.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            let weekday = calendar.component(.weekday, from: targetDay)
            let mondayIndex = (weekday + 5) % 7
            guard settings.activeDays.indices.contains(mondayIndex), settings.activeDays[mondayIndex] else { continue }

            for minute in slots {
                let hour = minute / 60
                let min = minute % 60
                guard let reminderDate = calendar.date(bySettingHour: hour, minute: min, second: 0, of: targetDay) else {
                    continue
                }
                if reminderDate > date {
                    return max(Int(ceil(reminderDate.timeIntervalSince(date) / 60.0)), 1)
                }
            }
        }

        return nil
    }

    private func dailyReminderSlots(settings: SharedReminderSettings) -> [Int] {
        var slots: Set<Int> = []
        let interval = max(settings.intervalMinutes, 1)

        for period in settings.periods where period.isValid {
            var cursor = period.startMinutes
            while cursor <= period.endMinutes {
                slots.insert(cursor)
                cursor += interval
            }
        }

        return slots.sorted()
    }

    private func isInActiveWindow(_ date: Date, settings: SharedReminderSettings) -> Bool {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7
        guard settings.activeDays.indices.contains(mondayIndex), settings.activeDays[mondayIndex] else { return false }

        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return settings.periods.contains { $0.isValid && minute >= $0.startMinutes && minute <= $0.endMinutes }
    }
}

struct StandUpReminderWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StandUpReminderProvider.Entry

    private var countdownText: String {
        entry.minutesLeft.map { "\($0) min" } ?? "--"
    }

    private var progressValue: Double {
        guard entry.total > 0 else { return 0 }
        return Double(entry.done) / Double(entry.total)
    }

    var body: some View {
        if family == .systemMedium {
            mediumView
        } else {
            smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                logo
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(countdownText)
                        .font(.headline)
                    Text(entry.mode)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ProgressView(value: progressValue)
                .progressViewStyle(.linear)

            Text("Today: \(entry.done)/\(entry.total)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            toggleButton
        }
        .padding(12)
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            logo
                .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 6) {
                Text(countdownText)
                    .font(.title2.weight(.semibold))
                Text(entry.mode)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Today: \(entry.done)/\(entry.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 10) {
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                toggleButton
            }
        }
        .padding(14)
    }

    private var logo: some View {
        Image("logo_chibi")
            .resizable()
            .scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var toggleButton: some View {
        Button(intent: ToggleReminderIntent()) {
            Label(entry.isEnabled ? "Turn Off" : "Turn On", systemImage: entry.isEnabled ? "pause.fill" : "play.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(entry.isEnabled ? .red : .accentColor)
    }
}

struct StandUpReminderWidget: Widget {
    let kind: String = "StandUpReminderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StandUpReminderProvider()) { entry in
            StandUpReminderWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("StandUpReminder")
        .description("Turn reminders on or off and view countdown.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct StandUpReminderWidgetBundle: WidgetBundle {
    var body: some Widget {
        StandUpReminderWidget()
    }
}
