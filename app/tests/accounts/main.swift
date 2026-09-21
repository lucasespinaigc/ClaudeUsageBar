import Combine
import Foundation

// The invariants that only exist once UsageManager and AccountsStore are
// compiled in. They are in a second target because the logic-only target
// cannot observe them: every assertion there stays green if the migration
// call moves below the `accounts` assignment, and that move is precisely what
// loses an upgrading user their cookie.

print("AccountsStore migration ordering")

func freshDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// A 1.3.x install: the legacy keys, nothing under the slot keys.
let legacy = freshDefaults("cub.test.store.legacy")
legacy.set("legacy-cookie-value", forKey: "claude_session_cookie")
legacy.set(50, forKey: "last_notified_threshold")

// Control first: a manager built with no migration ahead of it genuinely
// cannot see the legacy cookie. Without this, the next assertion could pass
// for the wrong reason and prove nothing.
checkEqual(UsageManager(slot: 1, defaults: legacy).hasCookie, false,
           "control: a manager on its own does not read the legacy cookie")

// So slot 1 seeing a cookie here is only explicable by the migration having
// already run when that manager's init read its key.
let store = AccountsStore(defaults: legacy)
checkEqual(store.accounts[0].hasCookie, true,
           "the migration runs before any manager reads its cookie")
checkEqual(legacy.string(forKey: "account_1_cookie"), "legacy-cookie-value",
           "slot 1 holds the copied cookie")
checkEqual(legacy.integer(forKey: "account_1_threshold"), 50,
           "slot 1 holds the copied threshold")
checkEqual(store.accounts[1].hasCookie, false, "slot 2 stays unconfigured")
checkEqual(store.configured.count, 1, "an upgrade yields exactly one configured account")
checkEqual(store.showsBadges, false, "one account shows no badges")
checkEqual(store.accounts.map { $0.displayName }, ["Account 1", "Account 2"],
           "unnamed accounts fall back to their slot names")

print("per-slot isolation")

// Two configured accounts, already migrated.
let pair = freshDefaults("cub.test.store.pair")
pair.set("cookie-1", forKey: "account_1_cookie")
pair.set("cookie-2", forKey: "account_2_cookie")
pair.set(75, forKey: "account_1_threshold")
pair.set(90, forKey: "account_2_threshold")
pair.set(accountsSchemaVersion, forKey: "accounts_schema_version")
let two = AccountsStore(defaults: pair)
checkEqual(two.configured.count, 2, "both accounts are configured")
checkEqual(two.showsBadges, true, "two accounts show badges")

// hasCookie has to announce itself: configured/showsBadges are derived from
// it, so a save that publishes nothing leaves the UI showing a stale account
// list. saveSessionCookie writes no other published property, so this fails
// unless the cookie itself is the thing that publishes.
var republishes = 0
let subscription = two.objectWillChange.sink { _ in republishes += 1 }
two.accounts[1].saveSessionCookie("cookie-2-renewed")
check(republishes > 0, "saving a cookie republishes through the store")
subscription.cancel()

checkEqual(pair.string(forKey: "account_2_cookie"), "cookie-2-renewed",
           "slot 2 saves onto its own key")
checkEqual(pair.string(forKey: "account_1_cookie"), "cookie-1",
           "saving slot 2 leaves slot 1's cookie alone")

// Clearing one account must not touch the other's notification state: a
// shared threshold key would rearm account 1 and re-fire every band it had
// already notified, with nothing on screen to explain it.
two.accounts[1].clearSessionCookie()
checkEqual(pair.integer(forKey: "account_1_threshold"), 75,
           "clearing slot 2 leaves slot 1's notification threshold alone")
checkEqual(pair.integer(forKey: "account_2_threshold"), 0,
           "clearing slot 2 resets its own threshold")
checkEqual(pair.string(forKey: "account_2_cookie"), nil, "clearing slot 2 drops its own cookie")
checkEqual(two.accounts[0].hasCookie, true, "slot 1 stays configured")
checkEqual(two.accounts[1].hasCookie, false, "slot 2 is no longer configured")
checkEqual(two.configured.count, 1, "configured tracks the clear")
checkEqual(two.showsBadges, false, "badges turn off once one account is left")

// Names are per slot too, and drive displayName.
two.accounts[0].name = "Work"
two.accounts[0].saveSettings()
checkEqual(pair.string(forKey: "account_1_name"), "Work", "slot 1 saves its own name")
checkEqual(two.accounts[0].displayName, "Work", "a named account displays its name")
checkEqual(two.accounts[1].displayName, "Account 2", "an unnamed account displays its slot name")
checkEqual(pair.string(forKey: "account_2_name"), nil, "naming slot 1 does not write slot 2's name")

for name in ["cub.test.store.legacy", "cub.test.store.pair"] {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
}

print("")
print(failures == 0 ? "PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
