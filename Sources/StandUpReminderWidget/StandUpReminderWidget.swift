import SwiftUI
import WidgetKit

private let appGroupID = "group.com.haotingyi.standupreminder"
private let settingsKey = "standup.settings.v1"
private let defaultActiveDays = [true, true, true, true, true, false, false]

private struct SharedTimeRange: Codable, Sendable {
    var startMinutes: Int
    var endMinutes: Int

    var isValid: Bool {
        startMinutes <= endMinutes
    }
}

private struct SharedTimedReminder: Codable, Sendable {
    var id: UUID
    var title: String
    var timeMinutes: Int
    var activeDays: [Bool]
    var isEnabled: Bool

    init(id: UUID = UUID(), title: String, timeMinutes: Int, activeDays: [Bool] = defaultActiveDays, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.timeMinutes = timeMinutes
        self.activeDays = activeDays.count == 7 ? activeDays : defaultActiveDays
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case timeMinutes
        case activeDays
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        timeMinutes = try container.decode(Int.self, forKey: .timeMinutes)
        activeDays = try container.decodeIfPresent([Bool].self, forKey: .activeDays) ?? defaultActiveDays
        if activeDays.count != 7 {
            activeDays = defaultActiveDays
        }
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

private struct SharedReminderSettings: Codable, Sendable {
    var isEnabled: Bool
    var intervalMinutes: Int
    var standMinutes: Int
    var periods: [SharedTimeRange]
    var activeDays: [Bool]
    var extraReminders: [SharedTimedReminder]

    static let defaultExtraReminders: [SharedTimedReminder] = [
        SharedTimedReminder(title: "Study Time", timeMinutes: 16 * 60),
        SharedTimedReminder(title: "Dinner Time", timeMinutes: 17 * 60),
        SharedTimedReminder(title: "Study Time", timeMinutes: 20 * 60)
    ]

    static let `default` = SharedReminderSettings(
        isEnabled: true,
        intervalMinutes: 45,
        standMinutes: 15,
        periods: [
            SharedTimeRange(startMinutes: 13 * 60, endMinutes: 17 * 60),
            SharedTimeRange(startMinutes: 19 * 60, endMinutes: 21 * 60)
        ],
        activeDays: defaultActiveDays,
        extraReminders: defaultExtraReminders
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case intervalMinutes
        case standMinutes
        case periods
        case activeDays
        case extraReminders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        standMinutes = try container.decode(Int.self, forKey: .standMinutes)
        periods = try container.decode([SharedTimeRange].self, forKey: .periods)
        activeDays = try container.decodeIfPresent([Bool].self, forKey: .activeDays) ?? defaultActiveDays
        if activeDays.count != 7 {
            activeDays = defaultActiveDays
        }
        extraReminders = try container.decodeIfPresent([SharedTimedReminder].self, forKey: .extraReminders) ?? Self.defaultExtraReminders
    }

    init(
        isEnabled: Bool,
        intervalMinutes: Int,
        standMinutes: Int,
        periods: [SharedTimeRange],
        activeDays: [Bool],
        extraReminders: [SharedTimedReminder]
    ) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.standMinutes = standMinutes
        self.periods = periods
        self.activeDays = activeDays
        self.extraReminders = extraReminders
    }
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
        return decoded
    }
}

struct StandProgress {
    let done: Int
    let total: Int

    var ratio: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }
}

struct StandUpReminderEntry: TimelineEntry {
    let date: Date
    let inWorkWindow: Bool
    let nextStandMinutes: Int?
    let modeText: String
    let progress: StandProgress
    let todayItems: [String]
}

struct StandUpReminderProvider: TimelineProvider {
    func placeholder(in context: Context) -> StandUpReminderEntry {
        StandUpReminderEntry(
            date: .now,
            inWorkWindow: true,
            nextStandMinutes: 18,
            modeText: "Work window",
            progress: StandProgress(done: 2, total: 5),
            todayItems: ["Study Time · 16:00", "Dinner Time · 17:00"]
        )
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
        let inWindow = isInActiveWindow(date, settings: settings)

        let modeText = inWindow
            ? "Work window"
            : "Off work hours. No extra pay, handle your own plans."

        return StandUpReminderEntry(
            date: date,
            inWorkWindow: inWindow,
            nextStandMinutes: inWindow ? minutesUntilNextStandInCurrentWindow(from: date, settings: settings) : nil,
            modeText: modeText,
            progress: progressSnapshot(for: date, settings: settings),
            todayItems: todayItems(for: date, settings: settings)
        )
    }

    private func progressSnapshot(for date: Date, settings: SharedReminderSettings) -> StandProgress {
        let slots = dailyStandSlots(settings: settings)
        guard !slots.isEmpty else { return StandProgress(done: 0, total: 0) }

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7
        guard settings.activeDays.indices.contains(mondayIndex), settings.activeDays[mondayIndex] else {
            return StandProgress(done: 0, total: slots.count)
        }

        let nowMinute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let done = slots.filter { $0 <= nowMinute }.count
        return StandProgress(done: done, total: slots.count)
    }

    private func todayItems(for date: Date, settings: SharedReminderSettings) -> [String] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7

        return settings.extraReminders
            .filter { reminder in
                reminder.isEnabled &&
                    reminder.activeDays.indices.contains(mondayIndex) &&
                    reminder.activeDays[mondayIndex]
            }
            .sorted { $0.timeMinutes < $1.timeMinutes }
            .map { "\($0.title) · \(formatMinutes($0.timeMinutes))" }
    }

    private func minutesUntilNextStandInCurrentWindow(from date: Date, settings: SharedReminderSettings) -> Int? {
        let calendar = Calendar.current
        let nowMinute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)

        guard let currentPeriod = settings.periods.first(where: { period in
            period.isValid && nowMinute >= period.startMinutes && nowMinute <= period.endMinutes
        }) else {
            return nil
        }

        let slots = dailyStandSlots(settings: settings)
        guard !slots.isEmpty else { return nil }

        for slot in slots where slot > nowMinute && slot <= currentPeriod.endMinutes {
            let hour = slot / 60
            let min = slot % 60
            guard let reminderDate = calendar.date(bySettingHour: hour, minute: min, second: 0, of: date) else {
                continue
            }
            return max(Int(ceil(reminderDate.timeIntervalSince(date) / 60.0)), 1)
        }

        return nil
    }

    private func dailyStandSlots(settings: SharedReminderSettings) -> [Int] {
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

    private func isInActiveWindow(_ date: Date, settings: SharedReminderSettings) -> Bool {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7
        guard settings.activeDays.indices.contains(mondayIndex), settings.activeDays[mondayIndex] else { return false }

        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return settings.periods.contains { $0.isValid && minute >= $0.startMinutes && minute <= $0.endMinutes }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let hour = max(0, min(23, minutes / 60))
        let min = max(0, min(59, minutes % 60))
        return String(format: "%02d:%02d", hour, min)
    }
}

struct StandUpReminderWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StandUpReminderProvider.Entry

    var body: some View {
        if family == .systemMedium {
            mediumView
        } else {
            smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                logo
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    if !entry.inWorkWindow {
                        Text("Off Hours")
                            .font(.headline)
                    } else if let minutes = entry.nextStandMinutes {
                        Text("Next stand: \(minutes) min")
                            .font(.headline)
                    } else {
                        Text("No More Stand Reminders")
                            .font(.headline)
                    }
                    Text(entry.modeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if entry.inWorkWindow, let firstItem = entry.todayItems.first {
                Text("Today: \(firstItem)")
                    .font(.caption2)
                    .lineLimit(1)
            } else if entry.inWorkWindow {
                Text("Today: No extra items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var mediumView: some View {
        HStack(spacing: 12) {
            logo
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                if !entry.inWorkWindow {
                    Text("Off work hours")
                        .font(.title3.weight(.semibold))
                } else if let minutes = entry.nextStandMinutes {
                    Text("Next stand in \(minutes) min")
                        .font(.title3.weight(.semibold))
                } else {
                    Text("No more stand reminders this window")
                        .font(.title3.weight(.semibold))
                }

                Text(entry.modeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if entry.inWorkWindow {
                    ProgressView(value: entry.progress.ratio)
                        .progressViewStyle(.linear)

                    Text("Stand progress: \(entry.progress.done)/\(entry.progress.total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if entry.todayItems.isEmpty {
                        Text("No extra items today")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Today: \(entry.todayItems.prefix(2).joined(separator: "  |  "))")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
    }

    private var logo: some View {
        Image("logo_chibi")
            .resizable()
            .scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
        .description("Shows today's items and next stand-up time during work windows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct StandUpReminderWidgetBundle: WidgetBundle {
    var body: some Widget {
        StandUpReminderWidget()
    }
}
