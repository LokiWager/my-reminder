import XCTest
@testable import StandUpReminder

final class ReminderSchedulePlannerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    func testDailyStandSlotsInclude1430ForThirtyMinuteCycle() {
        let planner = ReminderSchedulePlanner(calendar: calendar)
        let settings = makeSettings(
            intervalMinutes: 30,
            standMinutes: 30,
            periods: [TimeRange(startMinutes: 14 * 60, endMinutes: 15 * 60)]
        )

        XCTAssertEqual(planner.dailyStandSlots(settings: settings), [14 * 60 + 30])
    }

    func testRecurringNotificationPlansCreateWeekday1430Reminder() {
        let planner = ReminderSchedulePlanner(calendar: calendar)
        let settings = makeSettings(
            intervalMinutes: 30,
            standMinutes: 30,
            periods: [TimeRange(startMinutes: 14 * 60, endMinutes: 15 * 60)]
        )

        let plans = planner.recurringNotificationPlans(settings: settings)
        let standup1430Plans = plans.filter {
            $0.threadIdentifier == "standup-reminders" &&
                $0.hour == 14 &&
                $0.minute == 30
        }

        XCTAssertEqual(standup1430Plans.count, 5)
        XCTAssertEqual(Set(standup1430Plans.map(\.weekday)), Set([2, 3, 4, 5, 6]))
    }

    func testNextStandReminderDateRespectsCurrentWindow() {
        let planner = ReminderSchedulePlanner(calendar: calendar)
        let settings = makeSettings(
            intervalMinutes: 30,
            standMinutes: 30,
            periods: [TimeRange(startMinutes: 14 * 60, endMinutes: 15 * 60)]
        )

        let mondayAt1405 = makeDate(year: 2026, month: 3, day: 16, hour: 14, minute: 5)
        let mondayAt1505 = makeDate(year: 2026, month: 3, day: 16, hour: 15, minute: 5)

        XCTAssertEqual(
            planner.nextStandReminderDate(from: mondayAt1405, settings: settings, inCurrentWindowOnly: true),
            makeDate(year: 2026, month: 3, day: 16, hour: 14, minute: 30)
        )
        XCTAssertNil(
            planner.nextStandReminderDate(from: mondayAt1505, settings: settings, inCurrentWindowOnly: true)
        )
    }

    func testUpcomingCalendarPlansFallbackToImmediateDeliveryInsideLeadWindow() {
        let planner = ReminderSchedulePlanner(calendar: calendar)
        let now = makeDate(year: 2026, month: 3, day: 16, hour: 14, minute: 28)
        let eventStart = makeDate(year: 2026, month: 3, day: 16, hour: 14, minute: 30)

        let plans = planner.upcomingCalendarNotificationPlans(
            items: [
                CalendarNotificationItem(
                    eventID: "event/with:unsafe chars",
                    title: "Standup",
                    startDate: eventStart,
                    isAllDay: false
                )
            ],
            leadMinutes: 5,
            now: now
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].body, "Starting soon in 5 minutes.")
        XCTAssertEqual(plans[0].dateComponents.hour, 14)
        XCTAssertEqual(plans[0].dateComponents.minute, 28)
        XCTAssertEqual(plans[0].dateComponents.second, 5)
        XCTAssertTrue(plans[0].identifier.hasPrefix("standup-reminder-calendar-event-with-unsafe-chars-"))
    }

    private func makeSettings(
        intervalMinutes: Int,
        standMinutes: Int,
        periods: [TimeRange],
        activeDays: [Bool] = [true, true, true, true, true, false, false],
        extraReminders: [TimedReminder] = []
    ) -> ReminderSettings {
        ReminderSettings(
            isEnabled: true,
            isMouseMoverEnabled: false,
            mouseMoverIdleThresholdMinutes: ReminderSettings.defaultMouseMoverIdleThresholdMinutes,
            mouseMoverMoveIntervalMinutes: ReminderSettings.defaultMouseMoverMoveIntervalMinutes,
            intervalMinutes: intervalMinutes,
            standMinutes: standMinutes,
            periods: periods,
            activeDays: activeDays,
            extraReminders: extraReminders
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
