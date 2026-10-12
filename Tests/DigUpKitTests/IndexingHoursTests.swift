import Foundation
import Testing
@testable import DigUpKit

/// Indexing hours: when the window is open, and when it next opens or closes.
@Suite struct IndexingHoursTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    @Test func offOrAllDayIsAlwaysOpen() {
        #expect(IndexingHours(enabled: false).isOpen(at: at(10, 14), calendar: calendar))
        #expect(IndexingHours(enabled: true, start: 120, end: 120).isOpen(at: at(10, 14), calendar: calendar))
        #expect(IndexingHours(enabled: false).nextChange(after: at(10, 14), calendar: calendar) == nil)
        #expect(IndexingHours(enabled: true, start: 120, end: 120).nextChange(after: at(10, 14), calendar: calendar) == nil)
    }

    @Test func windowWithinADay() {
        let hours = IndexingHours(enabled: true, start: 9 * 60, end: 17 * 60)
        #expect(!hours.isOpen(at: at(10, 8, 59), calendar: calendar))
        #expect(hours.isOpen(at: at(10, 9), calendar: calendar))      // the start minute is in
        #expect(hours.isOpen(at: at(10, 16, 59), calendar: calendar))
        #expect(!hours.isOpen(at: at(10, 17), calendar: calendar))    // the end minute is out
    }

    @Test func windowAcrossMidnight() {
        let hours = IndexingHours(enabled: true, start: 23 * 60, end: 7 * 60)
        #expect(hours.isOpen(at: at(10, 23, 30), calendar: calendar))
        #expect(hours.isOpen(at: at(11, 0, 30), calendar: calendar))
        #expect(hours.isOpen(at: at(11, 6, 59), calendar: calendar))
        #expect(!hours.isOpen(at: at(11, 7), calendar: calendar))
        #expect(!hours.isOpen(at: at(11, 14), calendar: calendar))
    }

    @Test func nextChangeIsTheNearestEdge() {
        let hours = IndexingHours(enabled: true, start: 1 * 60, end: 7 * 60)
        #expect(hours.nextChange(after: at(10, 14), calendar: calendar) == at(11, 1))   // opens tonight
        #expect(hours.nextChange(after: at(11, 3), calendar: calendar) == at(11, 7))    // closes this morning
        #expect(hours.nextChange(after: at(11, 1), calendar: calendar) == at(11, 7))    // exactly at the start
    }

    @Test func daylightSavingGapStillOpens() {
        // 2026-03-29 in Berlin: 02:00 doesn't exist (clocks jump to 03:00). A 02:30 start opens at the next time.
        let hours = IndexingHours(enabled: true, start: 2 * 60 + 30, end: 6 * 60)
        let next = hours.nextChange(after: at(29, 0), calendar: calendar)
        #expect(next != nil)
        #expect(next.map { hours.isOpen(at: $0, calendar: calendar) } == true)
    }

    @Test func outOfRangeMinutesAreClamped() {
        let hours = IndexingHours(enabled: true, start: -5, end: 99_999)
        #expect(hours.start == 0)
        #expect(hours.end == 24 * 60 - 1)
    }
}
