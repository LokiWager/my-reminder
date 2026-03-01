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

    private var lastKnownSettingsData: Data?
    private var syncTask: Task<Void, Never>?

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
            settings = Self.normalized(decoded)
            lastKnownSettingsData = data
        } else {
            settings = Self.normalized(.default)
            if let encodedDefault = try? JSONEncoder().encode(settings) {
                defaults.set(encodedDefault, forKey: defaultsKey)
                lastKnownSettingsData = encodedDefault
            }
        }

        applySettings()

        startSettingsSyncPolling()
    }

    deinit {
        syncTask?.cancel()
    }

    func toggleEnabled() {
        settings.isEnabled.toggle()
        applySettings()
    }

    @discardableResult
    func saveSettings(_ draft: ReminderSettings) -> Bool {
        let normalizedDraft = Self.normalized(draft)
        if let error = validate(normalizedDraft) {
            statusMessage = error
            return false
        }

        settings = normalizedDraft
        applySettings()
        return true
    }

    func refreshFromStore() {
        reloadFromStoreIfNeeded(force: true)
    }

    func periodSummary() -> String {
        let periodSummary = settings.periods
            .enumerated()
            .map { index, period in
                "Period \(index + 1): \(ReminderScheduler.formatRange(period))"
            }
            .joined(separator: "   ")

        let customSummary = settings.extraReminders
            .filter { $0.isEnabled }
            .map { "\($0.title): \(ReminderScheduler.formatMinutes($0.timeMinutes))" }
            .joined(separator: "   ")

        guard !customSummary.isEmpty else {
            return periodSummary
        }
        return "\(periodSummary)   |   \(customSummary)"
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
            lastKnownSettingsData = data
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func startSettingsSyncPolling() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self?.reloadFromStoreIfNeeded(force: false)
                }
            }
        }
    }

    private func reloadFromStoreIfNeeded(force: Bool) {
        let data = defaults.data(forKey: defaultsKey)
        guard force || data != lastKnownSettingsData else {
            return
        }

        guard let data,
              let decoded = try? JSONDecoder().decode(ReminderSettings.self, from: data) else {
            return
        }

        lastKnownSettingsData = data
        guard decoded != settings else { return }

        settings = Self.normalized(decoded)
        statusMessage = "Notifications are active."
    }

    private func validate(_ candidate: ReminderSettings) -> String? {
        guard candidate.intervalMinutes > 0 else {
            return "Interval must be greater than 0."
        }
        guard candidate.standMinutes > 0 else {
            return "Stand duration must be greater than 0."
        }
        guard !candidate.periods.isEmpty else {
            return "Add at least one period."
        }
        guard candidate.periods.allSatisfy({ $0.isValid }) else {
            return "Each period must end after it starts."
        }
        guard candidate.activeDays.contains(true) else {
            return "Select at least one active day."
        }
        return nil
    }

    private static func normalized(_ candidate: ReminderSettings) -> ReminderSettings {
        var normalized = candidate
        normalized.isEnabled = true
        if normalized.extraReminders.isEmpty {
            normalized.extraReminders = ReminderSettings.defaultExtraReminders
        }
        normalized.extraReminders = normalized.extraReminders.map { reminder in
            var mapped = reminder
            let lowered = mapped.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "学习时间" || lowered == "study time" {
                mapped.title = "Study Time"
            } else if lowered == "晚饭时间" || lowered == "dinner time" {
                mapped.title = "Dinner Time"
            } else if lowered == "事项提醒" {
                mapped.title = "Item Reminder"
            }
            return mapped
        }
        return normalized
    }
}
