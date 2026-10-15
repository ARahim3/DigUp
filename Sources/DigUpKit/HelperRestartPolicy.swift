/// Remembers a request to resume while a helper is still stopping.
///
/// The app uses this to defer a restart until the old helper has exited. It lives in DigUpKit so the stop/resume
/// transition can be tested without launching the macOS app.
public struct HelperRestartPolicy: Sendable {
    private var stopWasRequested = false
    private var startWasRequested = false

    public init() {}

    public mutating func requestStop() {
        stopWasRequested = true
    }

    public mutating func requestStart() {
        if stopWasRequested { startWasRequested = true }
    }

    /// Returns whether the helper should be started again, then clears the completed stop cycle.
    public mutating func helperExited() -> Bool {
        defer {
            stopWasRequested = false
            startWasRequested = false
        }
        return startWasRequested
    }
}
