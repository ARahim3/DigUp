import Observation
import os
import Testing
@testable import DigUpApp

@MainActor
@Test func changingCurrentEditorNotifiesObservers() {
    let original = CodeEditor.current
    defer { CodeEditor.current = original }

    let changed = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
        _ = CodeEditor.current
    } onChange: {
        changed.withLock { $0 = true }
    }

    CodeEditor.current = CodeEditor.known[0]

    #expect(changed.withLock { $0 })
}
