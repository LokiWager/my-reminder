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
    let headline: String
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
        self.startMinutes = range.startMinutes
        self.endMinutes = range.endMinutes
    }

    var timeRange: TimeRange {
        TimeRange(startMinutes: startMinutes, endMinutes: endMinutes)
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: ReminderViewModel

    @State private var selection: AppSection? = .home
    @State private var periods: [PeriodDraft] = [
        PeriodDraft(range: .afternoon),
        PeriodDraft(range: .evening)
    ]
    @State private var intervalMinutes = 45
    @State private var standMinutes = 15
    @State private var activeDays: [Bool] = [true, true, true, true, true, false, false]

    private let timeOptions = Array(stride(from: 0, through: 23 * 60 + 30, by: 30))
    private let daySymbols = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

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

                    VStack(spacing: 14) {
                        Image("logo_chibi")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 20))

                        Text(timer.headline)
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                        Text(timer.subtitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 360)

                        Text("Today's reminders: \(progress.done)/\(progress.total)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Button {
                    viewModel.toggleEnabled()
                } label: {
                    Text(viewModel.settings.isEnabled ? "Turn Off" : "Turn On")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

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
                        insightRow("Status", value: viewModel.settings.isEnabled ? "On" : "Off")
                        insightRow("Interval", value: "\(viewModel.settings.intervalMinutes) min")
                        insightRow("Break Length", value: "\(viewModel.settings.standMinutes) min")
                        insightRow("Today", value: "\(progress.done)/\(progress.total)")
                    }
                }

                Divider()

                Text("Periods")
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
                Form {
                    Section("Schedule") {
                        ForEach(Array(periods.indices), id: \.self) { idx in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Period \(idx + 1)")
                                    .font(.subheadline.weight(.semibold))

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

                                HStack {
                                    Spacer()
                                    Button("Remove Period", role: .destructive) {
                                        removePeriod(at: idx)
                                    }
                                    .disabled(periods.count <= 1)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Button {
                            addPeriod()
                        } label: {
                            Label("Add Period", systemImage: "plus.circle.fill")
                        }
                    }

                    Section("Active Days") {
                        HStack(spacing: 12) {
                            ForEach(daySymbols.indices, id: \.self) { idx in
                                Toggle(daySymbols[idx], isOn: $activeDays[idx])
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }

                    Section("Preferences") {
                        Picker("Sit Interval", selection: $intervalMinutes) {
                            ForEach([15, 30, 45, 60, 75, 90], id: \.self) { value in
                                Text("\(value) min").tag(value)
                            }
                        }

                        Picker("Stand Break", selection: $standMinutes) {
                            ForEach([5, 10, 15, 20, 25, 30], id: \.self) { value in
                                Text("\(value) min").tag(value)
                            }
                        }
                    }
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
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Preferences")
    }

    private func addPeriod() {
        periods.append(PeriodDraft(range: .afternoon))
    }

    private func removePeriod(at index: Int) {
        guard periods.indices.contains(index), periods.count > 1 else { return }
        periods.remove(at: index)
    }

    private func syncFromModel() {
        let sourcePeriods = viewModel.settings.periods.isEmpty
            ? ReminderSettings.default.periods
            : viewModel.settings.periods

        periods = sourcePeriods.map(PeriodDraft.init(range:))
        intervalMinutes = viewModel.settings.intervalMinutes
        standMinutes = viewModel.settings.standMinutes
        activeDays = viewModel.settings.activeDays
    }

    private func saveToModel() {
        viewModel.settings.intervalMinutes = intervalMinutes
        viewModel.settings.standMinutes = standMinutes
        viewModel.settings.periods = periods.map(\.timeRange)
        viewModel.settings.activeDays = activeDays
        viewModel.saveSettings()
    }

    private func timerSnapshot(for date: Date) -> TimerSnapshot {
        guard viewModel.settings.isEnabled else {
            return TimerSnapshot(headline: "--", subtitle: "Reminders Off")
        }

        guard let minutes = minutesUntilNextReminder(from: date) else {
            return TimerSnapshot(headline: "--", subtitle: "No upcoming reminder")
        }

        if isInActiveWindow(date) {
            return TimerSnapshot(headline: "\(minutes) min", subtitle: "Next stand-up reminder")
        }

        return TimerSnapshot(headline: "\(minutes) min", subtitle: "Until active period")
    }

    private func progressSnapshot(for date: Date) -> DailyProgressSnapshot {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7

        guard viewModel.settings.activeDays.indices.contains(mondayIndex),
              viewModel.settings.activeDays[mondayIndex] else {
            return DailyProgressSnapshot(done: 0, total: dailyReminderSlots().count)
        }

        let slots = dailyReminderSlots()
        let nowMinute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let done = slots.filter { $0 <= nowMinute }.count
        return DailyProgressSnapshot(done: done, total: slots.count)
    }

    private func minutesUntilNextReminder(from date: Date) -> Int? {
        guard viewModel.settings.isEnabled, viewModel.settings.intervalMinutes > 0 else {
            return nil
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let slots = dailyReminderSlots()
        guard !slots.isEmpty else {
            return nil
        }

        for offset in 0...13 {
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

                if reminderDate > date {
                    return max(Int(ceil(reminderDate.timeIntervalSince(date) / 60.0)), 1)
                }
            }
        }

        return nil
    }

    private func dailyReminderSlots() -> [Int] {
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
