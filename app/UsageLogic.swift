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

struct UsageSnapshot: Equatable {
    var sessionUsage = 0
    var sessionResetsAt: Date?
    var weeklyUsage = 0
    var weeklyResetsAt: Date?
    var hasWeeklySonnet = false
    var weeklySonnetUsage = 0
    var weeklySonnetResetsAt: Date?
    var hasWeeklyFable = false
    var weeklyFableUsage = 0
    var weeklyFableResetsAt: Date?
}

func parseUsagePayload(_ data: Data) -> UsageSnapshot? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }

    var snapshot = UsageSnapshot()

    if let fiveHour = json["five_hour"] as? [String: Any] {
        snapshot.sessionUsage = intValue(fiveHour["utilization"]) ?? 0
        snapshot.sessionResetsAt = isoDate(fiveHour["resets_at"] as? String)
    }
    if let sevenDay = json["seven_day"] as? [String: Any] {
        snapshot.weeklyUsage = intValue(sevenDay["utilization"]) ?? 0
        snapshot.weeklyResetsAt = isoDate(sevenDay["resets_at"] as? String)
    }
    if let sonnet = json["seven_day_sonnet"] as? [String: Any] {
        snapshot.hasWeeklySonnet = true
        snapshot.weeklySonnetUsage = intValue(sonnet["utilization"]) ?? 0
        snapshot.weeklySonnetResetsAt = isoDate(sonnet["resets_at"] as? String)
    }

    // Fable is not a top-level key like seven_day_sonnet: it arrives as a
    // model-scoped weekly limit inside `limits`.
    if let limits = json["limits"] as? [[String: Any]],
       let fable = limits.first(where: { entry in
           let scope = entry["scope"] as? [String: Any]
           let model = scope?["model"] as? [String: Any]
           return (model?["display_name"] as? String) == "Fable"
       }) {
        snapshot.hasWeeklyFable = true
        snapshot.weeklyFableUsage = intValue(fable["percent"]) ?? 0
        snapshot.weeklyFableResetsAt = isoDate(fable["resets_at"] as? String)
    }

    return snapshot
}

/// `utilization` and `percent` decode as Int or Double depending on the
/// payload, so neither cast alone is enough.
private func intValue(_ raw: Any?) -> Int? {
    if let int = raw as? Int { return int }
    if let double = raw as? Double { return Int(double) }
    return nil
}

/// Not every claude.ai timestamp carries fractional seconds; accepting only
/// the fractional form dropped the rest on the floor.
private func isoDate(_ raw: String?) -> Date? {
    guard let raw = raw else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
}
