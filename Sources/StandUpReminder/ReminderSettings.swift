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

struct ReminderSettings: Codable, Equatable {
    var isEnabled: Bool
    var intervalMinutes: Int
    var standMinutes: Int
    var periods: [TimeRange]
    var activeDays: [Bool]

    static let `default` = ReminderSettings(
        isEnabled: false,
        intervalMinutes: 45,
        standMinutes: 15,
        periods: [.afternoon, .evening],
        activeDays: [true, true, true, true, true, false, false]
    )

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case intervalMinutes
        case standMinutes
        case periods
        case activeDays
    }

    init(isEnabled: Bool, intervalMinutes: Int, standMinutes: Int, periods: [TimeRange], activeDays: [Bool]) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.standMinutes = standMinutes
        self.periods = periods
        self.activeDays = activeDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        standMinutes = try container.decode(Int.self, forKey: .standMinutes)
        periods = try container.decode([TimeRange].self, forKey: .periods)
        activeDays = try container.decodeIfPresent([Bool].self, forKey: .activeDays)
            ?? [true, true, true, true, true, false, false]
        if activeDays.count != 7 {
            activeDays = [true, true, true, true, true, false, false]
        }
    }
}
