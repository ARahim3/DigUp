import AppKit
import DigUpKit

/// "Index only at set hours" (Settings → Folders): tells the engine whether indexing has to wait now, and until when.
/// A desktop Mac is always on AC and rarely warm, so `PowerPolicy` never holds it back; this keeps the reading and
/// embedding to hours when the Mac isn't in use. Search works at any hour.
///
/// Event-driven like `PowerPolicy`: one timer for the next start or end, set again when the Mac wakes, the clock or the
/// time zone changes, or the day turns. Nothing polls.
final class IndexSchedule {
    private var hours: IndexHours?
    private let onChange: (Date?) -> Void
    private var timer: Timer?
    nonisolated(unsafe) private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// When indexing may run again (outside the hours), or nil (inside them, or no hours set).
    private(set) var waitsUntil: Date?

    /// `hours`: nil when indexing may run at any hour. `onChange` gets when indexing may run again, or nil.
    init(hours: IndexHours?, onChange: @escaping (Date?) -> Void) {
        self.hours = hours
        self.onChange = onChange
        waitsUntil = Self.waitsUntil(hours, at: Date())
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(workspace, NSWorkspace.didWakeNotification),
                               (NotificationCenter.default, Notification.Name.NSSystemClockDidChange),
                               (NotificationCenter.default, Notification.Name.NSSystemTimeZoneDidChange),
                               (NotificationCenter.default, Notification.Name.NSCalendarDayChanged)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            }))
        }
        schedule()
    }

    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    /// The setting changed (nil: any hour).
    func setHours(_ hours: IndexHours?) {
        self.hours = hours
        reevaluate()
    }

    private func reevaluate() {
        let now = Self.waitsUntil(hours, at: Date())
        schedule()
        guard now != waitsUntil else { return }
        waitsUntil = now
        log("schedule: " + (now.map { "indexing waits until \($0.formatted(date: .omitted, time: .shortened))" }
                            ?? "indexing may run"))
        onChange(now)
    }

    /// A timer for the next start or end (a moment after it, so the hour has turned).
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let hours, let next = hours.nextChange(after: Date()) else { return }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Outside the hours: their next start. Inside them, or with none: nil.
    nonisolated static func waitsUntil(_ hours: IndexHours?, at date: Date) -> Date? {
        guard let hours, !hours.contains(date) else { return nil }
        return hours.nextChange(after: date)
    }
}
