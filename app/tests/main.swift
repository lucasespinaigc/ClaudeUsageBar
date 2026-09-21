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
checkEqual(freeSnapshot?.sessionUsage, 45, "free: session utilization")
checkEqual(freeSnapshot?.weeklyUsage, 22, "free: weekly utilization")
checkEqual(freeSnapshot?.hasWeeklySonnet, false, "free: no sonnet bucket")
checkEqual(freeSnapshot?.hasWeeklyFable, false, "free: no fable bucket")
check(freeSnapshot?.sessionResetsAt != nil, "free: session reset parsed")

// Pro plan: adds the seven_day_sonnet bucket.
let pro = payload("""
{"five_hour": {"utilization": 10.0},
 "seven_day": {"utilization": 30.0},
 "seven_day_sonnet": {"utilization": 12.0, "resets_at": "2026-09-27T09:00:00.000000Z"}}
""")
let proSnapshot = parseUsagePayload(pro)
checkEqual(proSnapshot?.hasWeeklySonnet, true, "pro: sonnet bucket detected")
checkEqual(proSnapshot?.weeklySonnetUsage, 12, "pro: sonnet utilization")

// Fable is not a top-level key: it is a model-scoped entry in `limits`.
let fableInt = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Fable"}}, "percent": 7,
             "resets_at": "2026-09-27T09:00:00.000000Z"}]}
""")
checkEqual(parseUsagePayload(fableInt)?.hasWeeklyFable, true, "fable: detected in limits")
checkEqual(parseUsagePayload(fableInt)?.weeklyFableUsage, 7, "fable: percent as Int")

// The same field comes back as a Double on other payloads, so neither
// `as? Int` nor `as? Double` alone is enough.
let fableDouble = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Fable"}}, "percent": 7.8}]}
""")
checkEqual(parseUsagePayload(fableDouble)?.weeklyFableUsage, 7, "fable: percent as Double")

// A limits array without Fable must not turn the bar on.
let otherModel = payload("""
{"five_hour": {"utilization": 5.0},
 "seven_day": {"utilization": 5.0},
 "limits": [{"scope": {"model": {"display_name": "Opus"}}, "percent": 50}]}
""")
checkEqual(parseUsagePayload(otherModel)?.hasWeeklyFable, false, "fable: other models ignored")

// claude.ai does not send fractional seconds on every field. The pre-1.4
// parser only accepted the fractional form and silently dropped the rest.
let noFraction = payload("""
{"five_hour": {"utilization": 5.0, "resets_at": "2026-09-21T18:30:00Z"},
 "seven_day": {"utilization": 5.0}}
""")
check(parseUsagePayload(noFraction)?.sessionResetsAt != nil,
      "dates without fractional seconds still parse")

checkEqual(parseUsagePayload(payload("not json")), nil, "garbage returns nil")

print("")
print(failures == 0 ? "PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
