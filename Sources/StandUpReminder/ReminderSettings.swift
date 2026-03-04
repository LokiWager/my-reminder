import Foundation

struct TimeRange: Codable, Equatable {
    var startMinutes: Int
    var endMinutes: Int

    static let afternoon = TimeRange(startMinutes: 13 * 60, endMinutes: 17 * 60)
    static let evening = TimeRange(startMinutes: 19 * 60, endMinutes: 21 * 60)

    var isValid: Bool {
        startMinutes <= endMinutes
    }
}

struct TimedReminder: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var timeMinutes: Int
    var activeDays: [Bool]
    var isEnabled: Bool

    private static let defaultDays = [true, true, true, true, true, false, false]

    init(id: UUID = UUID(), title: String, timeMinutes: Int, activeDays: [Bool] = TimedReminder.defaultDays, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.timeMinutes = timeMinutes
        self.activeDays = activeDays.count == 7 ? activeDays : TimedReminder.defaultDays
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
        activeDays = try container.decodeIfPresent([Bool].self, forKey: .activeDays) ?? TimedReminder.defaultDays
        if activeDays.count != 7 {
            activeDays = TimedReminder.defaultDays
        }
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct ReminderSettings: Codable, Equatable {
    var isEnabled: Bool
    var isMouseMoverEnabled: Bool
    var mouseMoverIdleThresholdMinutes: Int
    var mouseMoverMoveIntervalMinutes: Int
    var intervalMinutes: Int
    var standMinutes: Int
    var periods: [TimeRange]
    var activeDays: [Bool]
    var extraReminders: [TimedReminder]

    static let defaultExtraReminders: [TimedReminder] = [
        TimedReminder(title: "Study Time", timeMinutes: 16 * 60),
        TimedReminder(title: "Dinner Time", timeMinutes: 17 * 60),
        TimedReminder(title: "Study Time", timeMinutes: 20 * 60)
    ]

    static let defaultMouseMoverIdleThresholdMinutes = 2
    static let defaultMouseMoverMoveIntervalMinutes = 1

    static let `default` = ReminderSettings(
        isEnabled: true,
        isMouseMoverEnabled: false,
        mouseMoverIdleThresholdMinutes: ReminderSettings.defaultMouseMoverIdleThresholdMinutes,
        mouseMoverMoveIntervalMinutes: ReminderSettings.defaultMouseMoverMoveIntervalMinutes,
        intervalMinutes: 45,
        standMinutes: 15,
        periods: [.afternoon, .evening],
        activeDays: [true, true, true, true, true, false, false],
        extraReminders: ReminderSettings.defaultExtraReminders
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case isMouseMoverEnabled
        case mouseMoverIdleThresholdMinutes
        case mouseMoverMoveIntervalMinutes
        case intervalMinutes
        case standMinutes
        case periods
        case activeDays
        case extraReminders
    }

    init(
        isEnabled: Bool,
        isMouseMoverEnabled: Bool,
        mouseMoverIdleThresholdMinutes: Int,
        mouseMoverMoveIntervalMinutes: Int,
        intervalMinutes: Int,
        standMinutes: Int,
        periods: [TimeRange],
        activeDays: [Bool],
        extraReminders: [TimedReminder]
    ) {
        self.isEnabled = isEnabled
        self.isMouseMoverEnabled = isMouseMoverEnabled
        self.mouseMoverIdleThresholdMinutes = mouseMoverIdleThresholdMinutes
        self.mouseMoverMoveIntervalMinutes = mouseMoverMoveIntervalMinutes
        self.intervalMinutes = intervalMinutes
        self.standMinutes = standMinutes
        self.periods = periods
        self.activeDays = activeDays.count == 7 ? activeDays : ReminderSettings.default.activeDays
        self.extraReminders = extraReminders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isMouseMoverEnabled = try container.decodeIfPresent(Bool.self, forKey: .isMouseMoverEnabled) ?? false
        mouseMoverIdleThresholdMinutes = try container.decodeIfPresent(Int.self, forKey: .mouseMoverIdleThresholdMinutes)
            ?? ReminderSettings.defaultMouseMoverIdleThresholdMinutes
        mouseMoverMoveIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .mouseMoverMoveIntervalMinutes)
            ?? ReminderSettings.defaultMouseMoverMoveIntervalMinutes
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        standMinutes = try container.decode(Int.self, forKey: .standMinutes)
        periods = try container.decode([TimeRange].self, forKey: .periods)
        activeDays = try container.decodeIfPresent([Bool].self, forKey: .activeDays)
            ?? ReminderSettings.default.activeDays
        if activeDays.count != 7 {
            activeDays = ReminderSettings.default.activeDays
        }
        extraReminders = try container.decodeIfPresent([TimedReminder].self, forKey: .extraReminders)
            ?? ReminderSettings.defaultExtraReminders
    }
}
