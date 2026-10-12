import AppKit
import DigUpKit

/// When indexing hours are set (`IndexingHours`), whether files may be read now: outside the hours the helper isn't
/// started at all, so nothing is read, embedded or crawled until they begin.
///
/// Event-driven like `PowerPolicy`: one wall-clock timer for the next start or end (it fires on time across sleep),
/// and a fresh look after waking, a clock or time-zone change, or a new day. Nothing polls.
final class HoursPolicy {
    private var hours: IndexingHours
    private let onChange: (String?) -> Void
    private var timer: DispatchSourceTimer?
    nonisolated(unsafe) private var observers: [(NotificationCenter, NSObjectProtocol)] = []   // main thread, and deinit
    private(set) var blocker: String?

    /// `onChange` gets why indexing has to wait ("until 01:00"), or nil when it may run.
    init(hours: IndexingHours, onChange: @escaping (String?) -> Void) {
        self.hours = hours
        self.onChange = onChange
        blocker = Self.blocker(hours, at: Date())

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }))
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append((.default, NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            }))
        }
        schedule()
    }

    deinit {
        timer?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    /// The hours changed in Settings.
    func setHours(_ hours: IndexingHours) {
        self.hours = hours
        reevaluate()
    }

    private func reevaluate() {
        schedule()
        let now = Self.blocker(hours, at: Date())
        guard now != blocker else { return }
        blocker = now
        log("hours: indexing \(now.map { "waits (\($0))" } ?? "may run")")
        onChange(now)
    }

    /// One timer, for the next start or end; a second after it, so the minute has surely turned.
    private func schedule() {
        timer?.cancel()
        timer = nil
        guard let next = hours.nextChange(after: Date()) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(1, next.timeIntervalSinceNow + 1), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        timer.resume()
        self.timer = timer
    }

    nonisolated static func blocker(_ hours: IndexingHours, at date: Date) -> String? {
        hours.isOpen(at: date) ? nil : "until \(IndexingHours.timeText(hours.start))"
    }
}
