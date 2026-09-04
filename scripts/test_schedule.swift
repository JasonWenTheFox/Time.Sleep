import Foundation

@main
enum ScheduleResolverTests {
    static func main() {
        testFutureTimeUsesToday()
        testPastTimeUsesTomorrow()
        testCurrentMinuteUsesTomorrow()
        testInvalidValuesAreRejected()
        testDaylightSavingGapUsesNextValidTime()
        testRepeatedTimeUsesFirstOccurrence()
        print("schedule resolver tests: passed")
    }

    private static func testFutureTimeUsesToday() {
        let calendar = makeCalendar(timeZone: "Asia/Singapore")
        let now = date(2026, 9, 4, 12, 42, 15, calendar: calendar)
        let result = requireResult(hour: 23, minute: 10, now: now, calendar: calendar)
        assertComponents(result, [2026, 9, 4, 23, 10], calendar: calendar)
    }

    private static func testPastTimeUsesTomorrow() {
        let calendar = makeCalendar(timeZone: "Asia/Singapore")
        let now = date(2026, 9, 4, 12, 42, 15, calendar: calendar)
        let result = requireResult(hour: 8, minute: 30, now: now, calendar: calendar)
        assertComponents(result, [2026, 9, 5, 8, 30], calendar: calendar)
    }

    private static func testCurrentMinuteUsesTomorrow() {
        let calendar = makeCalendar(timeZone: "Asia/Singapore")
        let now = date(2026, 9, 4, 12, 42, 15, calendar: calendar)
        let result = requireResult(hour: 12, minute: 42, now: now, calendar: calendar)
        assertComponents(result, [2026, 9, 5, 12, 42], calendar: calendar)
    }

    private static func testInvalidValuesAreRejected() {
        let calendar = makeCalendar(timeZone: "UTC")
        let now = date(2026, 9, 4, 12, 0, 0, calendar: calendar)
        precondition(ScheduleResolver.nextOccurrence(hour: -1, minute: 0, after: now, calendar: calendar) == nil)
        precondition(ScheduleResolver.nextOccurrence(hour: 24, minute: 0, after: now, calendar: calendar) == nil)
        precondition(ScheduleResolver.nextOccurrence(hour: 12, minute: 60, after: now, calendar: calendar) == nil)
    }

    private static func testDaylightSavingGapUsesNextValidTime() {
        let calendar = makeCalendar(timeZone: "America/Los_Angeles")
        let now = date(2026, 3, 8, 1, 30, 0, calendar: calendar)
        let result = requireResult(hour: 2, minute: 30, now: now, calendar: calendar)
        // 02:30 does not exist on this date; the next valid local time is 03:00.
        assertComponents(result, [2026, 3, 8, 3, 0], calendar: calendar)
    }

    private static func testRepeatedTimeUsesFirstOccurrence() {
        let calendar = makeCalendar(timeZone: "America/Los_Angeles")
        let now = date(2026, 11, 1, 0, 30, 0, calendar: calendar)
        let result = requireResult(hour: 1, minute: 30, now: now, calendar: calendar)
        assertComponents(result, [2026, 11, 1, 1, 30], calendar: calendar)
        precondition(calendar.timeZone.secondsFromGMT(for: result) == -7 * 3600,
                     "Expected the first 01:30 occurrence before the DST fallback")
    }

    private static func makeCalendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: identifier) else {
            preconditionFailure("Missing test time zone: \(identifier)")
        }
        calendar.timeZone = timeZone
        return calendar
    }

    private static func date(_ year: Int,
                             _ month: Int,
                             _ day: Int,
                             _ hour: Int,
                             _ minute: Int,
                             _ second: Int,
                             calendar: Calendar) -> Date {
        guard let result = calendar.date(from: DateComponents(year: year,
                                                               month: month,
                                                               day: day,
                                                               hour: hour,
                                                               minute: minute,
                                                               second: second)) else {
            preconditionFailure("Could not create test date")
        }
        return result
    }

    private static func requireResult(hour: Int,
                                      minute: Int,
                                      now: Date,
                                      calendar: Calendar) -> Date {
        guard let result = ScheduleResolver.nextOccurrence(hour: hour,
                                                            minute: minute,
                                                            after: now,
                                                            calendar: calendar) else {
            preconditionFailure("Expected a schedule result")
        }
        return result
    }

    private static func assertComponents(_ date: Date,
                                         _ expected: [Int],
                                         calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let actual = [components.year, components.month, components.day, components.hour, components.minute]
        precondition(actual.elementsEqual(expected.map(Optional.some)),
                     "Expected \(expected), got \(actual)")
    }
}
