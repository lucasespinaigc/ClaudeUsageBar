import Foundation

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label): got \(actual), expected \(expected)")
        failures += 1
    }
}

print("highestCrossedThreshold")
// The bug this replaces: a fresh install already at 95% walked [25,50,75,90]
// and fired one notification per crossed threshold — four at once, eight with
// two accounts.
checkEqual(highestCrossedThreshold(percentage: 95, lastNotified: 0), 90,
           "fresh install at 95% reports one threshold, not four")
checkEqual(highestCrossedThreshold(percentage: 55, lastNotified: 25), 50,
           "crossing 50 after 25 reports 50")
checkEqual(highestCrossedThreshold(percentage: 26, lastNotified: 25), nil,
           "staying inside the same band reports nothing")
checkEqual(highestCrossedThreshold(percentage: 24, lastNotified: 0), nil,
           "below the first threshold reports nothing")
checkEqual(highestCrossedThreshold(percentage: 100, lastNotified: 90), nil,
           "already notified at the top band reports nothing")

print("rearmedThreshold")
checkEqual(rearmedThreshold(percentage: 95, lastNotified: 0), 90,
           "remembers the highest crossed threshold")
checkEqual(rearmedThreshold(percentage: 5, lastNotified: 90), 0,
           "a session reset rearms from zero")
checkEqual(rearmedThreshold(percentage: 30, lastNotified: 90), 25,
           "a drop to 30% rearms at 25, not at 0")
checkEqual(rearmedThreshold(percentage: 26, lastNotified: 25), 25,
           "no movement leaves the threshold alone")

print("parseUsagePayload")

func payload(_ json: String) -> Data { json.data(using: .utf8)! }

// Free plan: five_hour and seven_day only.
let free = payload("""
{"five_hour": {"utilization": 45.0, "resets_at": "2026-09-21T18:30:00.000000Z"},
 "seven_day": {"utilization": 22.0, "resets_at": "2026-09-27T09:00:00.000000Z"}}
""")
let freeSnapshot = parseUsagePayload(free)
checkEqual(freeSnapshot?.session?.usage, 45, "free: session utilization")
checkEqual(freeSnapshot?.weekly?.usage, 22, "free: weekly utilization")
checkEqual(freeSnapshot?.sonnet != nil, false, "free: no sonnet bucket")
checkEqual(freeSnapshot?.fable != nil, false, "free: no fable bucket")
check(freeSnapshot?.session?.resetsAt != nil, "free: session reset parsed")

// Pro plan: adds the seven_day_sonnet bucket.
let pro = payload("""
{"five_hour": {"utilization": 10.0},
 "seven_day": {"utilization": 30.0},
 "seven_day_sonnet": {"utilization": 12.0, "resets_at": "2026-09-27T09:00:00.000000Z"}}
""")
let proSnapshot = parseUsagePayload(pro)
checkEqual(proSnapshot?.sonnet != nil, true, "pro: sonnet bucket detected")
checkEqual(proSnapshot?.sonnet?.usage, 12, "pro: sonnet utilization")

// Fable is not a top-level key: it is a model-scoped entry in `limits`.
let fableInt = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Fable"}}, "percent": 7,
             "resets_at": "2026-09-27T09:00:00.000000Z"}]}
""")
checkEqual(parseUsagePayload(fableInt)?.fable != nil, true, "fable: detected in limits")
checkEqual(parseUsagePayload(fableInt)?.fable?.usage, 7, "fable: percent as Int")

// The same field comes back as a Double on other payloads, so neither
// `as? Int` nor `as? Double` alone is enough.
let fableDouble = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Fable"}}, "percent": 7.8}]}
""")
checkEqual(parseUsagePayload(fableDouble)?.fable?.usage, 7, "fable: percent as Double")

// A limits array without Fable must not turn the bar on.
let otherModel = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Opus"}}, "percent": 50}]}
""")
checkEqual(parseUsagePayload(otherModel)?.fable != nil, false, "fable: other models ignored")

// claude.ai does not send fractional seconds on every field. The pre-1.4
// parser only accepted the fractional form and silently dropped the rest.
let noFraction = payload("""
{"five_hour": {"utilization": 5.0, "resets_at": "2026-09-21T18:30:00Z"},
 "seven_day": {"utilization": 5.0}}
""")
check(parseUsagePayload(noFraction)?.session?.resetsAt != nil,
      "dates without fractional seconds still parse")

checkEqual(parseUsagePayload(payload("not json")), nil, "garbage returns nil")

// --- Partial/malformed payloads must not corrupt previously-good state. ---
// A zeroed sessionUsage flows into checkNotificationThresholds, which rearms
// every notification threshold — so "bucket absent" must stay distinguishable
// from "bucket present with usage 0" all the way up to the manager, which
// only copies a bucket onto its @Published properties when it is non-nil.

// 1. A key that's entirely absent leaves that bucket nil (manager writes nothing).
let missingFiveHour = payload("""
{"seven_day": {"utilization": 5.0}}
""")
checkEqual(parseUsagePayload(missingFiveHour)?.session, nil,
           "missing five_hour key leaves session bucket nil")

// 2. An empty object is a successful read with no data, not a wipe: the
// snapshot itself must be non-nil (distinct from the "not json" case above)
// while every bucket stays nil.
let emptyPayload = payload("{}")
let emptySnapshot = parseUsagePayload(emptyPayload)
check(emptySnapshot != nil, "empty payload still parses (success with no data, not garbage)")
checkEqual(emptySnapshot?.session, nil, "empty payload: session bucket nil")
checkEqual(emptySnapshot?.weekly, nil, "empty payload: weekly bucket nil")
checkEqual(emptySnapshot?.sonnet, nil, "empty payload: sonnet bucket nil")
checkEqual(emptySnapshot?.fable, nil, "empty payload: fable bucket nil")

// 3. A bucket present with an unparseable usage value stays nil rather than
// collapsing to 0 — a zeroed session bucket is exactly the shape that would
// rearm notification thresholds on garbage data, which is the bug this
// struct exists to prevent. A sibling bucket in the same payload still
// parses on its own.
let malformedUtilization = payload("""
{"five_hour": {"utilization": "oops"}, "seven_day": {"utilization": 5}}
""")
let malformedSnapshot = parseUsagePayload(malformedUtilization)
checkEqual(malformedSnapshot?.session, nil,
           "unparseable utilization leaves the bucket nil, not zeroed")
checkEqual(malformedSnapshot?.weekly?.usage, 5,
           "a sibling bucket still parses independently of a malformed one")

// 4. Every existing fixture above uses a "45.0"-style Double; a bare Int
// must parse too, since Int-or-Double is authorized for `utilization`.
let bareIntUtilization = payload("""
{"five_hour": {"utilization": 45}}
""")
checkEqual(parseUsagePayload(bareIntUtilization)?.session?.usage, 45,
           "utilization as a bare Int parses")

// 5. Assert the actual Date value, not just non-nil — a timezone bug would
// still produce *a* Date and pass a `!= nil` check silently. Expected epoch
// seconds computed independently with `date -u -j -f "%Y-%m-%dT%H:%M:%SZ"`.
let dateValues = payload("""
{"five_hour": {"utilization": 1.0, "resets_at": "2026-09-21T18:30:00.250000Z"},
 "seven_day": {"utilization": 1.0, "resets_at": "2026-09-27T09:00:00Z"}}
""")
let dateSnapshot = parseUsagePayload(dateValues)
checkEqual(dateSnapshot?.session?.resetsAt?.timeIntervalSince1970, 1790015400.25,
           "fractional-seconds timestamp parses to the exact expected instant")
checkEqual(dateSnapshot?.weekly?.resetsAt?.timeIntervalSince1970, 1790499600.0,
           "plain (non-fractional) timestamp parses to the exact expected instant")

print("")
print(failures == 0 ? "PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
