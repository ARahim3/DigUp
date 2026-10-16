/// Progress through an index's pending-file queue, carried across indexing passes.
///
/// A sync can split a backlog into several passes. `Indexer.run` reports progress for one snapshot at a time; this
/// tracker adds each pass to the completed count so the app can show stable overall progress.
public struct IndexProgress: Sendable {
    public private(set) var completed = 0
    public private(set) var pending = 0

    public init() {}

    /// Reconciles the queue count reported by a sync. A smaller count means some work finished or left the queue
    /// without a summary reaching the app (for example, if the helper was terminated between batches).
    public mutating func sync(pending newPending: Int) {
        let newPending = max(0, newPending)
        if newPending < pending { completed += pending - newPending }
        pending = newPending
    }

    /// Adds the files handled by a completed pass and removes them from the remaining queue.
    public mutating func processed(_ count: Int) {
        let count = min(max(0, count), pending)
        completed += count
        pending -= count
    }

    /// The current total, optionally including progress within the active pass.
    public func progress(passDone: Int = 0) -> (done: Int, total: Int) {
        (completed + min(max(0, passDone), pending), completed + pending)
    }

    /// Starts a fresh progress display after the queue becomes empty.
    public mutating func reset() {
        completed = 0
        pending = 0
    }
}
