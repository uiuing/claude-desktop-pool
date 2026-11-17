import Foundation
import Darwin

/// How long the Mac has slept since it started. Darwin keeps one clock that runs on through sleep
/// and one that stops while the Mac sleeps; the difference is the time asleep. A wait timed against
/// the wall clock subtracts the sleep inside it, so a reply interrupted by sleep is not taken for
/// a client that stopped answering.
public enum SystemSleep {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1e-9 : Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Seconds asleep since boot.
    public static func total() -> TimeInterval {
        // the clock that stops is read first, so the difference can only include a few more ticks, never fewer
        let awake = mach_absolute_time(), running = mach_continuous_time()
        return running > awake ? Double(running - awake) * scale : 0
    }
}
