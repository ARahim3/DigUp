import DigUpKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Notes the file the helper dies on when a fatal signal beats the watchdog. Swift's allocation trap — the
/// "indexer: exited (5)" of issue #182 — fires on the first allocation the system refuses, inside a hundredth
/// of a second of a 45 MP RAW's reading, faster than a watchdog tick could note the file. The file then stays
/// pending, every restart takes it first, and the queue never moves (55,000 files behind it in the #182
/// report). These handlers write a `StoppedFile` note and re-raise, so the next helper marks that file and
/// indexing goes on. The note carries no path (the crash beats `Indexer.nowReading`, and reading runs ahead of
/// the queue's head in media batches): the app that watched the helper names the file for the next one
/// (`DIGUP_STOPPED_FILE`, from the `file` events), and the head-mark is the fallback.
/// The handler runs off install-time copies with syscalls alone (`open`, `write`): malloc and Foundation
/// can deadlock a process that was mid-allocation when the signal arrived, and the helper's startup consumes
/// any note left beside the index, so the file is made at the crash itself, by path.
/// Installing plain handlers replaces Swift's own signal handling: Swift's crash print ("Fatal machine fault"
/// with a backtrace, its "Incident Identifier" report on macOS) is lost, deliberately — the note beside the
/// index is what unblocks a queue, and a backtrace in the log is not. Re-raising at `SIG_DFL` keeps what the
/// system can build from the signal itself (macOS writes its `.ips` report on the re-raise; on Linux Swift's
/// print is gone, which is the trade). Chaining Swift's old handler via `sigaction` would keep both, and is
/// the natural next step here. On Windows the C runtime translates only SEGV, FPE and ILL — a Swift trap
/// arrives as an SEH exit code, not one of these signals, so the note may be absent there; the shell then
/// marks nothing, and the restart cap bounds the loop (disclosed in issue #182's notes).
enum CrashNotes {
    nonisolated(unsafe) static var notePath: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var noteBytes: UnsafeMutableRawPointer?
    nonisolated(unsafe) static var noteLength: Int = 0

    static func install(in folder: URL) {
        let note = StoppedFile(path: nil, why: "crashed on it (a fatal signal — exit 5 among them) while reading it")
        guard let data = try? JSONEncoder().encode(note) else { return }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
        data.withUnsafeBytes { bytes.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        guard let path = strdup(StoppedFile.location(in: folder).path) else {
            bytes.deallocate()
            return
        }
        notePath = path
        noteBytes = bytes
        noteLength = data.count
        // SIGTRAP is Swift's trap; SIGSEGV/SIGBUS the access faults; SIGABRT/SIGILL/SIGFPE the rest.
        // The Windows C runtime has no SIGBUS; its faults all arrive as SIGSEGV.
        #if os(Windows)
        let fatal: [Int32] = [SIGABRT, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
        #else
        let fatal: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
        #endif
        for sig in fatal { signal(sig, crashNoteAndReraise) }
    }
}

/// Runs on the crashing thread. Everything it touches was made at `install`; `open` and `write` are
/// async-signal-safe, so this notes the crash and then lets the default handler take the process: the app
/// sees the same exit it saw before, with a note beside the index for the next helper to mark the file.
func crashNoteAndReraise(_ sig: Int32) {
    if let path = CrashNotes.notePath, let bytes = CrashNotes.noteBytes {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            _ = write(fd, bytes, CrashNotes.noteLength)
            _ = close(fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
