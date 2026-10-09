import Foundation
import IOKit.ps

/// When the big first pass (backfill) may run: with the Mac cool (thermal state nominal or fair), not in Low Power
/// Mode, and on AC power if indexing on battery is off (it's on by default). A few new files always index right away;
/// they take seconds.
///
/// Event-driven: power-source, thermal and Low Power Mode changes call `onChange`; nothing polls.
final class PowerPolicy {
    private var indexOnBattery: Bool
    private let onChange: (String?) -> Void
    nonisolated(unsafe) private var powerSource: CFRunLoopSource?   // main thread, and deinit
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private(set) var blocker: String?

    /// `onChange` gets why the backfill has to wait, or nil when it may run.
    init(indexOnBattery: Bool, onChange: @escaping (String?) -> Void) {
        self.indexOnBattery = indexOnBattery
        self.onChange = onChange
        blocker = Self.backfillBlocker(indexOnBattery: indexOnBattery)

        let me = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(powerSourceChanged, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            })
        }
    }

    deinit {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The "index on battery too" setting changed.
    func setIndexOnBattery(_ on: Bool) {
        indexOnBattery = on
        reevaluate()
    }

    fileprivate func reevaluate() {
        let now = Self.backfillBlocker(indexOnBattery: indexOnBattery)
        guard now != blocker else { return }
        blocker = now
        log("power: backfill \(now.map { "waits (\($0))" } ?? "may run")")
        onChange(now)
    }

    nonisolated static func backfillBlocker(indexOnBattery: Bool) -> String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "Low Power Mode" }
        switch info.thermalState {
        case .serious, .critical: return "Mac is warm"
        default: break
        }
        if !indexOnBattery, !onACPower() { return "on battery" }
        return nil
    }

    nonisolated static func onACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }   // no power-source info: a desktop Mac
        return type == kIOPMACPowerKey
    }
}

/// IOKit calls this on the main run loop when the power source changes.
private nonisolated func powerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        Unmanaged<PowerPolicy>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue().reevaluate()
    }
}
