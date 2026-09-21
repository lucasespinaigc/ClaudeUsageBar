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

print("")
print(failures == 0 ? "PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
