import Foundation

let usageThresholds = [25, 50, 75, 90]

/// The highest threshold newly crossed, or nil when no new one was reached.
/// Reporting only the highest is what keeps a fresh install already at 95%
/// from firing four notifications in a row.
func highestCrossedThreshold(percentage: Int,
                             lastNotified: Int,
                             thresholds: [Int] = usageThresholds) -> Int? {
    thresholds.filter { percentage >= $0 && lastNotified < $0 }.max()
}

/// The threshold to persist after a reading. Usage falling below the last
/// notified threshold means the session reset, which rearms the lower bands.
func rearmedThreshold(percentage: Int,
                      lastNotified: Int,
                      thresholds: [Int] = usageThresholds) -> Int {
    if let crossed = highestCrossedThreshold(percentage: percentage,
                                             lastNotified: lastNotified,
                                             thresholds: thresholds) {
        return crossed
    }
    if percentage < lastNotified {
        return thresholds.filter { $0 <= percentage }.max() ?? 0
    }
    return lastNotified
}
