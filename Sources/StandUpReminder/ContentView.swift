import SwiftUI

private enum AppSection: String, CaseIterable, Hashable {
    case home
    case insights
    case preferences

    var title: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .preferences: return "Preferences"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .insights: return "chart.bar"
        case .preferences: return "gearshape"
        }
    }
}

private struct TimerSnapshot {
    let headline: String?
    let subtitle: String
}

private struct DailyProgressSnapshot {
    let done: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }
}

private struct PeriodDraft: Identifiable {
    let id = UUID()
    var startMinutes: Int
    var endMinutes: Int

    init(range: TimeRange) {
        startMinutes = range.startMinutes
        endMinutes = range.endMinutes
    }

    var timeRange: TimeRange {
        TimeRange(startMinutes: startMinutes, endMinutes: endMinutes)
    }
}

private struct ExtraReminderDraft: Identifiable {
    var id: UUID
    var title: String
    var timeMinutes: Int
    var activeDays: [Bool]
    var isEnabled: Bool

    init(reminder: TimedReminder) {
        id = reminder.id
        title = reminder.title
        timeMinutes = reminder.timeMinutes
        activeDays = reminder.activeDays.count == 7 ? reminder.activeDays : ReminderSettings.default.activeDays
        isEnabled = reminder.isEnabled
    }

    init(title: String = "New Item", timeMinutes: Int = 9 * 60) {
        id = UUID()
        self.title = title
        self.timeMinutes = timeMinutes
        activeDays = ReminderSettings.default.activeDays
        isEnabled = true
    }

    var model: TimedReminder {
        TimedReminder(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Item Reminder" : title,
            timeMinutes: timeMinutes,
            activeDays: activeDays,
            isEnabled: isEnabled
        )
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: ReminderViewModel

    @State private var selection: AppSection? = .home
    @State private var periods: [PeriodDraft] = [
        PeriodDraft(range: .afternoon),
        PeriodDraft(range: .evening)
    ]
    @State private var extraReminders: [ExtraReminderDraft] = ReminderSettings.defaultExtraReminders.map(ExtraReminderDraft.init(reminder:))
    @State private var intervalMinutes = 45
    @State private var standMinutes = 15
    @State private var activeDays: [Bool] = [true, true, true, true, true, false, false]

    private let timeOptions = Array(stride(from: 0, through: 23 * 60 + 30, by: 30))
    private let daySymbols = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private let shortDaySymbols = ["M", "T", "W", "T", "F", "S", "S"]
    private let standIntervals = [15, 30, 45, 60, 75, 90]
    private let standBreaks = [5, 10, 15, 20, 25, 30]

    private var draftSettings: ReminderSettings {
        ReminderSettings(
            isEnabled: true,
            intervalMinutes: intervalMinutes,
            standMinutes: standMinutes,
            periods: periods.map(\.timeRange),
            activeDays: activeDays,
            extraReminders: extraReminders.map(\.model)
        )
    }

    private var hasUnsavedChanges: Bool {
        draftSettings != viewModel.settings
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear(perform: syncFromModel)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(AppSection.allCases, id: \.self) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
        }
        .navigationTitle("StandUpReminder")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home:
            homeView
        case .insights:
            insightsView
        case .preferences:
            preferencesView
        }
    }

    private var homeView: some View {
        ScrollView {
            VStack(spacing: 18) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let timer = timerSnapshot(for: context.date)
                    let progress = progressSnapshot(for: context.date)
                    let todayItems = todayItemLines(for: context.date)
                    let inWorkWindow = timer.headline != nil

                    VStack(spacing: 14) {
                        Image("logo_chibi")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 20))

                        if let headline = timer.headline {
                            Text(headline)
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                        }
                        Text(timer.subtitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        if inWorkWindow {
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 360)

                            Text("Today's stand reminders: \(progress.done)/\(progress.total)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Today's Items")
                                    .font(.headline)
                                if todayItems.isEmpty {
                                    Text("No extra items today.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(todayItems.prefix(4), id: \.self) { item in
                                        Text("• \(item)")
                                            .font(.callout)
                                    }
                                }
                            }
                            .frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Text(viewModel.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
    }

    private var insightsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let progress = progressSnapshot(for: context.date)

                    VStack(alignment: .leading, spacing: 12) {
                        insightRow("Status", value: "Active")
                        insightRow("Interval", value: "\(viewModel.settings.intervalMinutes) min")
                        insightRow("Break Length", value: "\(viewModel.settings.standMinutes) min")
                        insightRow("Today", value: "\(progress.done)/\(progress.total)")
                        insightRow("Custom Items", value: "\(viewModel.settings.extraReminders.filter { $0.isEnabled }.count)")
                    }
                }

                Divider()

                Text("Configured Schedule")
                    .font(.headline)
                Text(viewModel.periodSummary())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle("Insights")
    }

    private var preferencesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Stand-up")
                    .font(.title.weight(.bold))
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(periods.indices), id: \.self) { idx in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Period \(idx + 1)")
                                    .font(.subheadline.weight(.semibold))

                                HStack {
                                    LabeledTimePicker(
                                        title: "Start",
                                        selection: $periods[idx].startMinutes,
                                        options: timeOptions
                                    )
                                    LabeledTimePicker(
                                        title: "End",
                                        selection: $periods[idx].endMinutes,
                                        options: timeOptions
                                    )
                                }

                                HStack {
                                    Spacer()
                                    Button("Remove Period", role: .destructive) {
                                        removePeriod(at: idx)
                                    }
                                    .disabled(periods.count <= 1)
                                }
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Button {
                            addPeriod()
                        } label: {
                            Label("Add Period", systemImage: "plus.circle.fill")
                        }

                        Divider()

                        HStack(spacing: 12) {
                            ForEach(daySymbols.indices, id: \.self) { idx in
                                Toggle(daySymbols[idx], isOn: $activeDays[idx])
                                    .toggleStyle(.checkbox)
                            }
                        }

                        Divider()

                        HStack {
                            Picker("Sit Interval", selection: $intervalMinutes) {
                                ForEach(standIntervals, id: \.self) { value in
                                    Text("\(value) min").tag(value)
                                }
                            }
                            Picker("Stand Break", selection: $standMinutes) {
                                ForEach(standBreaks, id: \.self) { value in
                                    Text("\(value) min").tag(value)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                Text("Reminder Items")
                    .font(.title.weight(.bold))
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(extraReminders.indices), id: \.self) { idx in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Enable", isOn: $extraReminders[idx].isEnabled)

                                TextField("Title", text: $extraReminders[idx].title)

                                LabeledTimePicker(
                                    title: "Time",
                                    selection: $extraReminders[idx].timeMinutes,
                                    options: timeOptions
                                )

                                HStack(spacing: 8) {
                                    ForEach(shortDaySymbols.indices, id: \.self) { dayIndex in
                                        Toggle(shortDaySymbols[dayIndex], isOn: reminderDayBinding(reminderIndex: idx, dayIndex: dayIndex))
                                            .toggleStyle(.checkbox)
                                    }
                                }

                                HStack {
                                    Spacer()
                                    Button("Remove Item", role: .destructive) {
                                        removeExtraReminder(at: idx)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        Button {
                            addExtraReminder()
                        } label: {
                            Label("Add Item Reminder", systemImage: "plus.circle.fill")
                        }
                    }
                    .padding(.top, 4)
                }

                HStack {
                    Spacer()
                    Image("logo_chibi")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Button("Save Settings") {
                    saveToModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasUnsavedChanges)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Preferences")
    }

    private func reminderDayBinding(reminderIndex: Int, dayIndex: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard extraReminders.indices.contains(reminderIndex),
                      extraReminders[reminderIndex].activeDays.indices.contains(dayIndex) else {
                    return false
                }
                return extraReminders[reminderIndex].activeDays[dayIndex]
            },
            set: { newValue in
                guard extraReminders.indices.contains(reminderIndex) else { return }
                if extraReminders[reminderIndex].activeDays.count != 7 {
                    extraReminders[reminderIndex].activeDays = ReminderSettings.default.activeDays
                }
                extraReminders[reminderIndex].activeDays[dayIndex] = newValue
            }
        )
    }

    private func addPeriod() {
        periods.append(PeriodDraft(range: .afternoon))
    }

    private func removePeriod(at index: Int) {
        guard periods.indices.contains(index), periods.count > 1 else { return }
        periods.remove(at: index)
    }

    private func addExtraReminder() {
        extraReminders.append(ExtraReminderDraft())
    }

    private func removeExtraReminder(at index: Int) {
        guard extraReminders.indices.contains(index) else { return }
        extraReminders.remove(at: index)
    }

    private func syncFromModel() {
        let sourcePeriods = viewModel.settings.periods.isEmpty
            ? ReminderSettings.default.periods
            : viewModel.settings.periods

        periods = sourcePeriods.map(PeriodDraft.init(range:))
        intervalMinutes = viewModel.settings.intervalMinutes
        standMinutes = viewModel.settings.standMinutes
        activeDays = viewModel.settings.activeDays
        extraReminders = viewModel.settings.extraReminders.map(ExtraReminderDraft.init(reminder:))
        if extraReminders.isEmpty {
            extraReminders = ReminderSettings.defaultExtraReminders.map(ExtraReminderDraft.init(reminder:))
        }
    }

    private func saveToModel() {
        _ = viewModel.saveSettings(draftSettings)
    }

    private func timerSnapshot(for date: Date) -> TimerSnapshot {
        guard isInActiveWindow(date) else {
            return TimerSnapshot(
                headline: nil,
                subtitle: "Off work hours. No extra pay, handle your own plans."
            )
        }

        guard let minutes = minutesUntilNextStandReminder(from: date, inCurrentWindowOnly: true) else {
            return TimerSnapshot(headline: nil, subtitle: "No upcoming stand reminder in this window.")
        }

        return TimerSnapshot(headline: "\(minutes) min", subtitle: "Until next stand-up reminder")
    }

    private func progressSnapshot(for date: Date) -> DailyProgressSnapshot {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7

        guard viewModel.settings.activeDays.indices.contains(mondayIndex),
              viewModel.settings.activeDays[mondayIndex] else {
            return DailyProgressSnapshot(done: 0, total: dailyStandReminderSlots().count)
        }

        let slots = dailyStandReminderSlots()
        let nowMinute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let done = slots.filter { $0 <= nowMinute }.count
        return DailyProgressSnapshot(done: done, total: slots.count)
    }

    private func minutesUntilNextStandReminder(from date: Date, inCurrentWindowOnly: Bool = false) -> Int? {
        guard viewModel.settings.intervalMinutes > 0 else {
            return nil
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let slots = dailyStandReminderSlots()
        guard !slots.isEmpty else {
            return nil
        }

        for offset in 0...13 {
            if inCurrentWindowOnly && offset > 0 {
                break
            }
            guard let targetDay = calendar.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            let weekday = calendar.component(.weekday, from: targetDay)
            let mondayIndex = (weekday + 5) % 7

            guard viewModel.settings.activeDays.indices.contains(mondayIndex),
                  viewModel.settings.activeDays[mondayIndex] else {
                continue
            }

            for minute in slots {
                let hour = minute / 60
                let min = minute % 60
                guard let reminderDate = calendar.date(bySettingHour: hour, minute: min, second: 0, of: targetDay) else {
                    continue
                }

                if inCurrentWindowOnly {
                    let currentMinute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
                    let activeInThisWindow = viewModel.settings.periods.contains { period in
                        period.isValid && currentMinute >= period.startMinutes && currentMinute <= period.endMinutes &&
                            minute >= period.startMinutes && minute <= period.endMinutes
                    }
                    guard activeInThisWindow else { continue }
                }

                if reminderDate > date {
                    return max(Int(ceil(reminderDate.timeIntervalSince(date) / 60.0)), 1)
                }
            }
        }
        return nil
    }

    private func todayItemLines(for date: Date) -> [String] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7

        return viewModel.settings.extraReminders
            .filter { reminder in
                reminder.isEnabled &&
                    reminder.activeDays.indices.contains(mondayIndex) &&
                    reminder.activeDays[mondayIndex]
            }
            .sorted { $0.timeMinutes < $1.timeMinutes }
            .map { reminder in
                "\(reminder.title) · \(ReminderScheduler.formatMinutes(reminder.timeMinutes))"
            }
    }

    private func dailyStandReminderSlots() -> [Int] {
        var slots: Set<Int> = []
        let interval = max(viewModel.settings.intervalMinutes, 1)

        for period in viewModel.settings.periods where period.isValid {
            var cursor = period.startMinutes
            while cursor <= period.endMinutes {
                slots.insert(cursor)
                cursor += interval
            }
        }

        return slots.sorted()
    }

    private func isInActiveWindow(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7
        guard viewModel.settings.activeDays.indices.contains(mondayIndex),
              viewModel.settings.activeDays[mondayIndex] else {
            return false
        }

        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return viewModel.settings.periods.contains { $0.isValid && minute >= $0.startMinutes && minute <= $0.endMinutes }
    }

    private func insightRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LabeledTimePicker: View {
    let title: String
    @Binding var selection: Int
    let options: [Int]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { value in
                Text(Self.format(value)).tag(value)
            }
        }
    }

    private static func format(_ minutes: Int) -> String {
        let hour = minutes / 60
        let min = minutes % 60
        return String(format: "%02d:%02d", hour, min)
    }
}
