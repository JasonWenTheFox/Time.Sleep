import Foundation

/// Resolves a wall-clock selection to its next occurrence in the user's current calendar.
/// The returned `Date` is converted to a continuous countdown by `TimerModel` when started.
enum ScheduleResolver {
    static func nextOccurrence(hour: Int,
                               minute: Int,
                               after now: Date = Date(),
                               calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0

        // `.nextTime` advances a nonexistent daylight-saving time to the first valid local time.
        // `.first` chooses the first occurrence when a local time repeats as DST ends.
        return calendar.nextDate(after: now,
                                 matching: components,
                                 matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first,
                                 direction: .forward)
    }
}
