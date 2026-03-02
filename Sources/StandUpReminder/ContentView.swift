import SwiftUI

private enum AppSection: String, CaseIterable, Hashable {
    case today
    case todo
    case reminders
    case shopping
    case calendar
    case weather
    case preferences

    var title: String {
        switch self {
        case .today: return "Today"
        case .todo: return "Todo"
        case .reminders: return "Reminders"
        case .shopping: return "Shopping"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .preferences: return "Preferences"
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .todo: return "checklist"
        case .reminders: return "bell"
        case .shopping: return "cart"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun"
        case .preferences: return "gearshape"
        }
    }
}

private enum ListSortMode: String, CaseIterable, Identifiable {
    case pendingFirst = "Pending First"
    case alphabetical = "A-Z"
    case newestFirst = "Newest"
    case manual = "Manual"

    var id: String { rawValue }
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

    @State private var selection: AppSection? = .today
    @State private var periods: [PeriodDraft] = [
        PeriodDraft(range: .afternoon),
        PeriodDraft(range: .evening)
    ]
    @State private var extraReminders: [ExtraReminderDraft] = ReminderSettings.defaultExtraReminders.map(ExtraReminderDraft.init(reminder:))
    @State private var intervalMinutes = 45
    @State private var standMinutes = 15
    @State private var activeDays: [Bool] = [true, true, true, true, true, false, false]
    @State private var newTodoTitle = ""
    @State private var newShoppingTitle = ""
    @State private var todoSortMode: ListSortMode = .pendingFirst
    @State private var shoppingSortMode: ListSortMode = .pendingFirst
    @State private var calendarSelection = Date()

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

    private var hasUnsavedReminderChanges: Bool {
        draftSettings != viewModel.settings
    }

    private var sortedTodos: [AssistantItem] {
        sorted(items: viewModel.todoItems, mode: todoSortMode)
    }

    private var sortedShoppingItems: [AssistantItem] {
        sorted(items: viewModel.shoppingItems, mode: shoppingSortMode)
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
        .navigationTitle("Assistant Hub")
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .today {
        case .today:
            todayView
        case .todo:
            todoView
        case .reminders:
            remindersView
        case .shopping:
            shoppingView
        case .calendar:
            calendarView
        case .weather:
            weatherView
        case .preferences:
            preferencesView
        }
    }

    private var todayView: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let timer = timerSnapshot(for: context.date)
                let progress = progressSnapshot(for: context.date)
                let reminderItems = todayItemLines(for: context.date)
                let todoPreview = sorted(items: viewModel.todoItems.filter { !$0.isCompleted }, mode: .pendingFirst)
                let shoppingPreview = sorted(items: viewModel.shoppingItems.filter { !$0.isCompleted }, mode: .pendingFirst)
                let inWorkWindow = timer.headline != nil

                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image("logo_chibi")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Today's Command Center")
                                .font(.title2.weight(.semibold))
                            Text("One place for tasks, reminders, and lists.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Stand-up Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let headline = timer.headline {
                                Text(headline)
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                            }
                            Text(timer.subtitle)
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            if inWorkWindow {
                                ProgressView(value: progress.fraction)
                                    .progressViewStyle(.linear)
                                Text("Today's stand reminders: \(progress.done)/\(progress.total)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Today's Reminder Items") {
                        VStack(alignment: .leading, spacing: 6) {
                            if inWorkWindow {
                                if reminderItems.isEmpty {
                                    Text("No extra reminder items today.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(reminderItems.prefix(6), id: \.self) { item in
                                        Text("• \(item)")
                                    }
                                }
                            } else {
                                Text("Off work hours. No extra pay, handle your own plans.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            dashboardListCard(
                                title: "Pending Todo",
                                subtitle: "\(viewModel.pendingTodoCount) remaining",
                                items: todoPreview
                            )
                            dashboardListCard(
                                title: "Shopping Queue",
                                subtitle: "\(viewModel.pendingShoppingCount) remaining",
                                items: shoppingPreview
                            )
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            dashboardListCard(
                                title: "Pending Todo",
                                subtitle: "\(viewModel.pendingTodoCount) remaining",
                                items: todoPreview
                            )
                            dashboardListCard(
                                title: "Shopping Queue",
                                subtitle: "\(viewModel.pendingShoppingCount) remaining",
                                items: shoppingPreview
                            )
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Today")
    }

    private var todoView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Add todo item", text: $newTodoTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTodo)
                Button("Add", action: addTodo)
                    .keyboardShortcut(.return)
            }

            HStack {
                Picker("Sort", selection: $todoSortMode) {
                    ForEach(ListSortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            List {
                if todoSortMode == .manual {
                    ForEach(viewModel.todosByManualOrder) { item in
                        todoRow(item)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { viewModel.todosByManualOrder[$0].id }
                        viewModel.removeTodos(ids: ids)
                    }
                    .onMove(perform: viewModel.moveTodos)
                } else {
                    ForEach(sortedTodos) { item in
                        todoRow(item)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { sortedTodos[$0].id }
                        viewModel.removeTodos(ids: ids)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(24)
        .navigationTitle("Todo")
    }

    private var remindersView: some View {
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

                Button("Save Reminder Settings") {
                    saveReminderSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasUnsavedReminderChanges)

                Text(viewModel.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Reminders")
    }

    private var shoppingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Add shopping item", text: $newShoppingTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addShoppingItem)
                Button("Add", action: addShoppingItem)
                    .keyboardShortcut(.return)
            }

            HStack {
                Picker("Sort", selection: $shoppingSortMode) {
                    ForEach(ListSortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            List {
                if shoppingSortMode == .manual {
                    ForEach(viewModel.shoppingByManualOrder) { item in
                        shoppingRow(item)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { viewModel.shoppingByManualOrder[$0].id }
                        viewModel.removeShoppingItems(ids: ids)
                    }
                    .onMove(perform: viewModel.moveShoppingItems)
                } else {
                    ForEach(sortedShoppingItems) { item in
                        shoppingRow(item)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { sortedShoppingItems[$0].id }
                        viewModel.removeShoppingItems(ids: ids)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(24)
        .navigationTitle("Shopping")
    }

    private var calendarView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Calendar")
                    .font(.title2.weight(.semibold))

                DatePicker("Selected Date", selection: $calendarSelection, displayedComponents: [.date])
                    .datePickerStyle(.graphical)

                GroupBox("Access") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(calendarAccessTitle)
                            .font(.headline)
                        Text(viewModel.calendarStatusMessage)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Refresh Events") {
                                viewModel.refreshCalendarEvents(for: calendarSelection, requestAccessIfNeeded: false)
                            }

                            if viewModel.calendarAccessState == .notDetermined {
                                Button("Grant Calendar Access") {
                                    viewModel.requestCalendarAccessAndRefresh(for: calendarSelection)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.calendarAccessState == .granted {
                    GroupBox("Events") {
                        if viewModel.calendarEvents.isEmpty {
                            Text("No calendar events on this date.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(viewModel.calendarEvents) { event in
                                    calendarEventRow(event)
                                    if event.id != viewModel.calendarEvents.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Calendar")
        .onAppear {
            viewModel.refreshCalendarEvents(for: calendarSelection, requestAccessIfNeeded: false)
        }
        .onChange(of: calendarSelection) { _, newDate in
            viewModel.refreshCalendarEvents(for: newDate, requestAccessIfNeeded: false)
        }
    }

    private var weatherView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Weather")
                    .font(.title2.weight(.semibold))

                HStack(spacing: 10) {
                    Image(systemName: "cloud.sun")
                        .font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text("Weather integration is planned for V2.")
                        Text("Next step: connect WeatherKit and surface current conditions.")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Last updated: \(Date.now.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Weather")
    }

    private var preferencesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Preferences")
                    .font(.title2.weight(.semibold))

                GroupBox("Assistant Overview") {
                    VStack(alignment: .leading, spacing: 8) {
                        insightRow("Todo items", value: "\(viewModel.todoItems.count)")
                        insightRow("Shopping items", value: "\(viewModel.shoppingItems.count)")
                        insightRow("Reminder items", value: "\(viewModel.settings.extraReminders.filter(\.isEnabled).count)")
                        insightRow("Stand-up periods", value: "\(viewModel.settings.periods.count)")
                    }
                }

                GroupBox("Roadmap") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("V2: Calendar + Weather live integrations.")
                        Text("V4: Voice input + LLM execution workflow.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Preferences")
    }

    private func dashboardListCard(title: String, subtitle: String, items: [AssistantItem]) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if items.isEmpty {
                    Text("Nothing pending.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items.prefix(5)) { item in
                        Text("• \(item.title)")
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var calendarAccessTitle: String {
        switch viewModel.calendarAccessState {
        case .unknown:
            return "Unknown"
        case .notDetermined:
            return "Permission Required"
        case .granted:
            return "Connected"
        case .denied:
            return "Access Denied"
        case .restricted:
            return "Restricted"
        case .writeOnly:
            return "Write-Only Access"
        }
    }

    private func calendarEventRow(_ event: CalendarEventItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.title)
                .font(.headline)
            Text(event.isAllDay ? "All day · \(event.calendarTitle)" : "\(formatCalendarEventTimeRange(event)) · \(event.calendarTitle)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let location = event.location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(location)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatCalendarEventTimeRange(_ event: CalendarEventItem) -> String {
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) - \(end)"
    }

    private func todoRow(_ item: AssistantItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: todoCompletionBinding(id: item.id))
                .toggleStyle(.checkbox)
                .labelsHidden()

            TextField("Task title", text: todoTitleBinding(id: item.id))
                .textFieldStyle(.plain)
                .strikethrough(item.isCompleted, color: .secondary)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
        }
    }

    private func shoppingRow(_ item: AssistantItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: shoppingCompletionBinding(id: item.id))
                .toggleStyle(.checkbox)
                .labelsHidden()

            TextField("Shopping item", text: shoppingTitleBinding(id: item.id))
                .textFieldStyle(.plain)
                .strikethrough(item.isCompleted, color: .secondary)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
        }
    }

    private func sorted(items: [AssistantItem], mode: ListSortMode) -> [AssistantItem] {
        switch mode {
        case .pendingFirst:
            return items.sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return lhs.isCompleted == false
                }
                return lhs.sortOrder < rhs.sortOrder
            }
        case .alphabetical:
            return items.sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .newestFirst:
            return items.sorted { lhs, rhs in
                lhs.createdAt > rhs.createdAt
            }
        case .manual:
            return items.sorted { lhs, rhs in
                lhs.sortOrder < rhs.sortOrder
            }
        }
    }

    private func todoTitleBinding(id: UUID) -> Binding<String> {
        Binding(
            get: {
                viewModel.todoItems.first(where: { $0.id == id })?.title ?? ""
            },
            set: { newValue in
                viewModel.updateTodoTitle(id: id, title: newValue)
            }
        )
    }

    private func shoppingTitleBinding(id: UUID) -> Binding<String> {
        Binding(
            get: {
                viewModel.shoppingItems.first(where: { $0.id == id })?.title ?? ""
            },
            set: { newValue in
                viewModel.updateShoppingTitle(id: id, title: newValue)
            }
        )
    }

    private func todoCompletionBinding(id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.todoItems.first(where: { $0.id == id })?.isCompleted ?? false
            },
            set: { newValue in
                let current = viewModel.todoItems.first(where: { $0.id == id })?.isCompleted ?? false
                if current != newValue {
                    viewModel.toggleTodo(id: id)
                }
            }
        )
    }

    private func shoppingCompletionBinding(id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.shoppingItems.first(where: { $0.id == id })?.isCompleted ?? false
            },
            set: { newValue in
                let current = viewModel.shoppingItems.first(where: { $0.id == id })?.isCompleted ?? false
                if current != newValue {
                    viewModel.toggleShopping(id: id)
                }
            }
        )
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

    private func addTodo() {
        viewModel.addTodo(title: newTodoTitle)
        newTodoTitle = ""
    }

    private func addShoppingItem() {
        viewModel.addShoppingItem(title: newShoppingTitle)
        newShoppingTitle = ""
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

    private func saveReminderSettings() {
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

        for offset in 0 ... 13 {
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
