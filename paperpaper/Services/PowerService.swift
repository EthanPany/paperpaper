import Foundation
#if os(macOS)
import IOKit.ps
#endif

/// Tells whether the Mac is currently running on battery (i.e. the power
/// adapter is unplugged). Used by the rotation engine's "don't rotate on
/// battery" guard. Read on demand — power state changes are infrequent and a
/// one-shot query is cheaper than maintaining a run-loop source.
enum PowerService {
    /// `true` when the machine is drawing from its internal battery rather than
    /// an AC adapter. Desktops (no battery) always report `false` — they're
    /// effectively always "plugged in", so a battery guard never blocks them.
    static var isOnBattery: Bool {
        #if os(macOS)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String?
        // kIOPSBatteryPowerValue == "Battery Power"; AC reads "AC Power".
        return providing == kIOPSBatteryPowerValue
        #else
        return false
        #endif
    }
}
