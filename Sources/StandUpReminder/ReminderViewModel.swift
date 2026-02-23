import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class ReminderViewModel: ObservableObject {
    @Published var settings: ReminderSettings
    @Published var statusMessage: String = "Ready."

    private let scheduler = ReminderScheduler()
    private let defaultsKey = "standup.settings.v1"
    private let appGroupID = "group.com.haotingyi.standupreminder"
    private let defaults: UserDefaults

    init() {
        let groupDefaults = UserDefaults(suiteName: appGroupID) ?? .standard
        self.defaults = groupDefaults

        // Migrate existing local settings into the app group once.
        if groupDefaults.data(forKey: defaultsKey) == nil,
           let legacyData = UserDefaults.standard.data(forKey: defaultsKey) {
            groupDefaults.set(legacyData, forKey: defaultsKey)
        }

        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(ReminderSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }

        if settings.isEnabled {
            applySettings()
        }
    }

    func toggleEnabled() {
        settings.isEnabled.toggle()
        applySettings()
    }

    func saveSettings() {
        guard settings.intervalMinutes > 0 else {
            statusMessage = "Interval must be greater than 0."
            return
        }
        guard settings.standMinutes > 0 else {
            statusMessage = "Stand duration must be greater than 0."
            return
        }
        guard !settings.periods.isEmpty else {
            statusMessage = "Add at least one period."
            return
        }
        guard settings.periods.allSatisfy({ $0.isValid }) else {
            statusMessage = "Each period must end after it starts."
            return
        }
        guard settings.activeDays.contains(true) else {
            statusMessage = "Select at least one active day."
            return
        }
        applySettings()
    }

    func periodSummary() -> String {
        settings.periods
            .enumerated()
            .map { index, period in
                "Period \(index + 1): \(ReminderScheduler.formatRange(period))"
            }
            .joined(separator: "   ")
    }

    private func applySettings() {
        persist()

        if settings.isEnabled {
            let settingsSnapshot = settings
            scheduler.requestPermission { [weak self] granted, errorMessage in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    guard granted else {
                        self.settings.isEnabled = false
                        self.persist()
                        self.statusMessage = errorMessage ?? "Permission denied."
                        return
                    }

                    self.scheduler.apply(settings: settingsSnapshot) { status in
                        Task { @MainActor [weak self] in
                            self?.statusMessage = status
                        }
                    }
                }
            }
        } else {
            scheduler.clearAll { [weak self] in
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Reminders are off."
                }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: defaultsKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
