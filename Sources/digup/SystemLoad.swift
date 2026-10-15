import Foundation
#if os(Windows)
import WinSDK
#endif

/// How busy this machine's processors are with other programs' work, for the speed check (`ModelSpeed`): it starts once
/// the machine has settled (just after the model's download a virus scanner reads the new files, and after a login
/// everything starts at once), and its reply says what else ran while it timed. A check timed at such a moment took one
/// PC for thirty times slower than it was.
enum SystemLoad {
    /// The processors' busy and total time since the machine started (any unit, the same for both), and this process's
    /// own processor seconds, at `time`.
    struct Sample {
        let busy, total, own: Double
        let time: Date
    }

    static func sample() -> Sample? {
        let now = Date()
        #if os(Windows)
        var idle = FILETIME(), kernel = FILETIME(), user = FILETIME()
        var created = FILETIME(), exited = FILETIME(), ownKernel = FILETIME(), ownUser = FILETIME()
        guard GetSystemTimes(&idle, &kernel, &user),
              GetProcessTimes(GetCurrentProcess(), &created, &exited, &ownKernel, &ownUser) else { return nil }
        func value(_ time: FILETIME) -> Double { Double(UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)) }
        // The kernel's time includes the idle time; both count 100 ns ticks over all processors.
        let total = value(kernel) + value(user)
        return Sample(busy: total - value(idle), total: total, own: (value(ownKernel) + value(ownUser)) / 1e7, time: now)
        #elseif os(Linux)
        // The first line of /proc/stat: user nice system idle iowait irq softirq steal (guests are inside user).
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = stat.split(separator: "\n").first, line.hasPrefix("cpu ") else { return nil }
        let fields = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard fields.count >= 5 else { return nil }
        let idle = fields[3] + fields[4], busy = fields.prefix(8).reduce(0, +) - idle
        return Sample(busy: busy, total: busy + idle, own: ownSeconds(), time: now)
        #else
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let busy = Double(ticks.0) + Double(ticks.1) + Double(ticks.3), idle = Double(ticks.2)   // user, system, nice
        return Sample(busy: busy, total: busy + idle, own: ownSeconds(), time: now)
        #endif
    }

    #if !os(Windows)
    private static func ownSeconds() -> Double {
        var usage = rusage()
        #if os(Linux)
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)   // Glibc's RUSAGE_SELF is an enum
        #else
        getrusage(RUSAGE_SELF, &usage)
        #endif
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
    #endif

    /// Processors' worth of work other programs did between two samples (1 is one processor kept busy throughout).
    static func others(from start: Sample, to end: Sample) -> Double {
        let wall = end.time.timeIntervalSince(start.time), total = end.total - start.total
        guard wall > 0, total > 0 else { return 0 }
        let busy = (end.busy - start.busy) / total * Double(ProcessInfo.processInfo.activeProcessorCount)
        return max(0, busy - (end.own - start.own) / wall)
    }

    /// Other programs' work this machine shrugs off: a processor's half, plus a little on bigger machines.
    static var quiet: Double { 0.5 + 0.05 * Double(ProcessInfo.processInfo.activeProcessorCount) }

    /// Waits until other programs have kept under `quiet` for the last three seconds, at most `limit` seconds. Says how
    /// long it waited, whether the machine settled, and the least work other programs did over three seconds meanwhile.
    static func waitForQuiet(limit: Double) -> (waited: Double, settled: Bool, calmest: Double?) {
        let started = Date()
        guard var last = sample() else { return (0, true, nil) }
        var recent: [Double] = [], calmest: Double?
        while Date().timeIntervalSince(started) < limit {
            Thread.sleep(forTimeInterval: 1)
            guard let next = sample() else { break }
            recent = (recent + [others(from: last, to: next)]).suffix(3)
            last = next
            guard recent.count == 3 else { continue }
            let average = recent.reduce(0, +) / 3
            calmest = min(calmest ?? average, average)
            if average < quiet { return (Date().timeIntervalSince(started), true, calmest) }
        }
        return (Date().timeIntervalSince(started), false, calmest)
    }
}
