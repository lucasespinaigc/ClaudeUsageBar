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

// MARK: - Notification text
//
// Kept as pure functions, called from UsageManager.sendNotification and
// .sendTestNotification rather than built inline, so the wording can be
// asserted directly — the test harness cannot observe NSUserNotificationCenter.

/// Text of a usage-threshold alert. Empty prefix is the single-account case:
/// the exact 1.3.x wording, since there is nothing to disambiguate. A
/// non-empty prefix lower-cases the body's lead word so "Work — you've
/// reached..." reads as one sentence naming the account that crossed it.
func notificationBody(percentage: Int, prefix: String) -> String {
    let body = "You've reached \(percentage)% of your 5-hour session limit"
    guard !prefix.isEmpty else { return body }
    return "\(prefix) — \(body.prefix(1).lowercased() + body.dropFirst())"
}

/// Text of the Settings "Test Notification" button. Same prefixing rule as
/// notificationBody, minus the lead-word lowercasing: "Test notification" is
/// its own clause here, not the start of the account's sentence.
func testNotificationBody(prefix: String) -> String {
    let body = "Test notification - You've reached 75% of your 5-hour session limit"
    guard !prefix.isEmpty else { return body }
    return "\(prefix) — \(body)"
}

struct UsageSnapshot: Equatable {
    // "Bucket absent" and "bucket present with usage 0" must stay distinct
    // states all the way up to the manager: a partial/malformed payload that
    // collapsed a real reading to 0 would rearm every notification threshold
    // on the next healthy poll (see checkNotificationThresholds).
    struct Bucket: Equatable {
        var usage: Int
        var resetsAt: Date?
    }
    var session: Bucket?
    var weekly: Bucket?
    var sonnet: Bucket?
    var fable: Bucket?
}

func parseUsagePayload(_ data: Data) -> UsageSnapshot? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }

    var snapshot = UsageSnapshot()
    snapshot.session = bucket(from: json["five_hour"] as? [String: Any], usageKey: "utilization")
    snapshot.weekly = bucket(from: json["seven_day"] as? [String: Any], usageKey: "utilization")
    snapshot.sonnet = bucket(from: json["seven_day_sonnet"] as? [String: Any], usageKey: "utilization")

    // Fable is not a top-level key like seven_day_sonnet: it arrives as a
    // model-scoped weekly limit inside `limits`.
    if let limits = json["limits"] as? [[String: Any]],
       let fable = limits.first(where: { entry in
           let scope = entry["scope"] as? [String: Any]
           let model = scope?["model"] as? [String: Any]
           return (model?["display_name"] as? String) == "Fable"
       }) {
        snapshot.fable = bucket(from: fable, usageKey: "percent")
    }

    return snapshot
}

/// Builds a bucket only when its usage value is present and parses; a
/// present-but-unparseable value (or a missing top-level key) yields nil
/// rather than a 0-usage bucket, so the manager leaves the previous reading
/// in place instead of writing a value that reads as "usage just dropped to
/// zero" and rearms notification thresholds.
///
/// A bucket that IS present clears resetsAt to nil when its own resets_at is
/// missing/unparseable, rather than keeping a stale date — showing an
/// outdated reset time indefinitely is worse than showing none.
private func bucket(from dict: [String: Any]?, usageKey: String) -> UsageSnapshot.Bucket? {
    guard let dict = dict, let usage = intValue(dict[usageKey]) else { return nil }
    return UsageSnapshot.Bucket(usage: usage, resetsAt: isoDate(dict["resets_at"] as? String))
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

// MARK: - Account slots

let accountsSchemaVersion = 2

func accountKey(_ slot: Int, _ suffix: String) -> String { "account_\(slot)_\(suffix)" }

/// Moves a 1.3.x single-account install onto the per-slot keys. Runs once,
/// before any UsageManager reads its cookie.
///
/// Copies instead of moving: this runs exactly once on each user's machine and
/// has no undo, so leaving the legacy keys in place is what makes a rollback to
/// 1.3.x survivable. The cost is one orphan key.
func migrateAccounts(_ defaults: UserDefaults) {
    guard defaults.integer(forKey: "accounts_schema_version") < accountsSchemaVersion else {
        return
    }

    // "Configured" means a non-empty cookie everywhere else (UsageManager.hasCookie),
    // so it has to mean that here too. Treating an empty slot-1 string as
    // already-configured would skip the copy, stamp the version anyway, and put
    // the legacy cookie permanently out of reach: the version guard above means
    // there is no second pass.
    let legacyCookie = defaults.string(forKey: "claude_session_cookie") ?? ""
    let slotCookie = defaults.string(forKey: accountKey(1, "cookie")) ?? ""
    if !legacyCookie.isEmpty, slotCookie.isEmpty {
        defaults.set(legacyCookie, forKey: accountKey(1, "cookie"))
        defaults.set(defaults.integer(forKey: "last_notified_threshold"),
                     forKey: accountKey(1, "threshold"))
    }

    defaults.set(accountsSchemaVersion, forKey: "accounts_schema_version")
}
