import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @EnvironmentObject private var viewModel: ReminderViewModel

    var body: some View {
        Group {
            Button("Open App") {
                openMainWindow()
            }

            Divider()

            Text("Calendar")
                .font(.headline)

            if todayCalendarEvents.isEmpty {
                Text("   No events today")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(todayCalendarEvents.prefix(8)) { event in
                    Button("   \(calendarEventLabel(event))") {
                        openMainWindow()
                    }
                }
            }

            Divider()

            Text("Todo")
                .font(.headline)

            if pendingTodos.isEmpty {
                Text("   No pending todo")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pendingTodos.prefix(8)) { item in
                    Button("   \(item.title)") {
                        openMainWindow()
                    }
                }
            }

            Divider()

            Toggle("Enable Notifications", isOn: notificationsEnabledBinding)
            Toggle("Enable Mouse Mover", isOn: mouseMoverEnabledBinding)

            Divider()

            Button("Exit") {
                AppDelegate.requestUserQuit()
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            viewModel.refreshCalendarEvents(for: .now, requestAccessIfNeeded: false)
        }
    }

    private var pendingTodos: [AssistantItem] {
        viewModel.todoItems
            .filter { !$0.isCompleted }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    private var todayCalendarEvents: [CalendarEventItem] {
        let calendar = Calendar.current
        guard calendar.isDate(viewModel.calendarEventsDate, inSameDayAs: .now) else {
            return []
        }
        return viewModel.calendarEvents
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.isEnabled },
            set: { viewModel.setNotificationsEnabled($0) }
        )
    }

    private var mouseMoverEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.isMouseMoverEnabled },
            set: { viewModel.setMouseMoverEnabled($0) }
        )
    }

    private func calendarEventLabel(_ event: CalendarEventItem) -> String {
        if event.isAllDay {
            return "All-day  \(event.title)"
        }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        return "\(start)  \(event.title)"
    }

    private func openMainWindow() {
        AppDelegate.presentMainWindow()
    }
}
