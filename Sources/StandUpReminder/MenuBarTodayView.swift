import AppKit
import SwiftUI

struct MenuBarTodayView: View {
    @EnvironmentObject private var viewModel: ReminderViewModel
    private let buildInfo = AppBuildInfo.current

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let nextStand = minutesUntilNextStand(from: context.date)
            let todayItems = todayReminderItems(for: context.date)
            let todayEvents = todayCalendarEvents(for: context.date)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image("logo_chibi")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today")
                            .font(.headline)
                        if let nextStand {
                            Text("Next stand in \(nextStand) min")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No upcoming stand reminder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                Divider()

                Text("Reminder Items")
                    .font(.subheadline.weight(.semibold))
                if todayItems.isEmpty {
                    Text("No items today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todayItems.prefix(4), id: \.self) { item in
                        Text("• \(item)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Divider()

                Text("Calendar")
                    .font(.subheadline.weight(.semibold))
                if todayEvents.isEmpty {
                    Text("No events today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todayEvents.prefix(3)) { event in
                        Text("• \(event.title)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text(buildInfo.summaryLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(buildInfo.detailLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider()

                HStack {
                    Text("Todo \(pendingTodoCount()) | Shopping \(pendingShoppingCount())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open App") {
                        openMainWindow()
                    }
                    .buttonStyle(.bordered)
                    Button("Exit") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .frame(width: 330)
        }
        .onAppear {
            viewModel.refreshCalendarEvents(for: .now, requestAccessIfNeeded: false)
        }
    }

    private func pendingTodoCount() -> Int {
        viewModel.todoItems.filter { !$0.isCompleted }.count
    }

    private func pendingShoppingCount() -> Int {
        viewModel.shoppingItems.filter { !$0.isCompleted }.count
    }

    private func todayReminderItems(for date: Date) -> [String] {
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
            .map { "\($0.title) · \(ReminderScheduler.formatMinutes($0.timeMinutes))" }
    }

    private func todayCalendarEvents(for date: Date) -> [CalendarEventItem] {
        let calendar = Calendar.current
        guard calendar.isDate(viewModel.calendarEventsDate, inSameDayAs: date) else {
            return []
        }
        return viewModel.calendarEvents
    }

    private func minutesUntilNextStand(from date: Date) -> Int? {
        guard viewModel.settings.isEnabled else { return nil }

        let calendar = Calendar.current
        let minuteNow = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let mondayIndex = (weekday + 5) % 7

        guard viewModel.settings.activeDays.indices.contains(mondayIndex),
              viewModel.settings.activeDays[mondayIndex] else { return nil }

        let slots = dailyStandSlots()
        for slot in slots where slot > minuteNow {
            let inSamePeriod = viewModel.settings.periods.contains { period in
                period.isValid &&
                    minuteNow >= period.startMinutes &&
                    minuteNow <= period.endMinutes &&
                    slot <= period.endMinutes
            }
            guard inSamePeriod else { continue }
            let hour = slot / 60
            let minute = slot % 60
            guard let fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) else {
                continue
            }
            return max(Int(ceil(fireDate.timeIntervalSince(date) / 60.0)), 1)
        }
        return nil
    }

    private func dailyStandSlots() -> [Int] {
        var slots = Set<Int>()
        let sitInterval = max(viewModel.settings.intervalMinutes, 1)
        let standBreak = max(viewModel.settings.standMinutes, 1)
        let cycle = sitInterval + standBreak

        for period in viewModel.settings.periods where period.isValid {
            var cursor = period.startMinutes + sitInterval
            while cursor <= period.endMinutes {
                slots.insert(cursor)
                cursor += cycle
            }
        }
        return slots.sorted()
    }

    private func openMainWindow() {
        AppDelegate.presentMainWindow()
    }
}
