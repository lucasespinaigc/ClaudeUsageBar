import SwiftUI
import AppKit
import ServiceManagement

class UsageManager: ObservableObject {
    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var weeklyFableUsage: Int = 0
    @Published var weeklyFableLimit: Int = 100
    // Extra usage spend (from /overage_spend_limit). Shown only when there's spend.
    @Published var extraSpentMinor: Int = 0
    @Published var extraLimitMinor: Int = 0
    @Published var extraResetsAt: Date?
    @Published var freeCreditsMinor: Int = 0   // remaining free/promo credits (/prepaid/credits)
    @Published var creditCurrency: String = "USD"
    @Published var hasCreditUsage: Bool = false
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var weeklyFableResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasWeeklyFable: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var name: String = ""

    let slot: Int
    // Published so that hasCookie announces itself: AccountsStore.configured is
    // derived from it, and a cookie saved or cleared without an objectWillChange
    // leaves the account list stale. Publishing at the source covers every
    // mutation site, including ones not written yet.
    @Published private var sessionCookie: String = ""
    private var lastNotifiedThreshold: Int = 0

    /// Injected so the slot invariants can be driven against a scratch suite
    /// instead of the real domain; production always gets .standard.
    private let defaults: UserDefaults

    /// The manager no longer knows about NSStatusItem or AppDelegate: the menu
    /// bar observes $sessionUsage instead. Keeping UI out of here is what lets
    /// two of these exist without fighting over one status item.
    var hasCookie: Bool { !sessionCookie.isEmpty }
    var displayName: String { name.isEmpty ? "Account \(slot)" : name }

    /// Last characters of the saved cookie, enough to tell two accounts apart
    /// without ever putting the secret back into an editable field.
    var cookieSuffix: String { String(sessionCookie.suffix(6)) }

    /// Set by AccountsStore. Empty with a single account, so its notification
    /// text stays exactly what 1.3.x users already know.
    var notificationPrefix: String = ""

    // MARK: - App-wide preferences
    //
    // These four are settings of the app, not of an account, so they are read
    // from and written to UserDefaults at the point of use instead of being
    // cached per manager. Held as @Published copies loaded in init, each
    // manager owned its own snapshot: unticking "Enable Usage Notifications"
    // wrote slot 1 and the shared key, slot 2 kept its stale `true`, and
    // account 2 went on notifying until the next launch. With no second copy
    // there is nothing left to go stale.

    var usageNotificationsEnabled: Bool {
        get { defaults.object(forKey: "usage_notifications_enabled") as? Bool ?? true }
        set { setGlobalFlag(newValue, forKey: "usage_notifications_enabled") }
    }

    var statusNotificationsEnabled: Bool {
        get { defaults.object(forKey: "status_notifications_enabled") as? Bool ?? true }
        set { setGlobalFlag(newValue, forKey: "status_notifications_enabled") }
    }

    var shortcutEnabled: Bool {
        get { defaults.object(forKey: "shortcut_enabled") as? Bool ?? true }
        set { setGlobalFlag(newValue, forKey: "shortcut_enabled") }
    }

    var openAtLogin: Bool {
        // The real login-item registration wins over the stored bool: the user
        // can remove the item in System Settings without telling us.
        get {
            if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
            return defaults.bool(forKey: "open_at_login")
        }
        set { setGlobalFlag(newValue, forKey: "open_at_login") }
    }

    /// Published by hand because these are computed: without it the Settings
    /// toggles would write the key and then redraw from their own pre-write
    /// read, showing the checkbox snapping back.
    private func setGlobalFlag(_ value: Bool, forKey key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        defaults.synchronize()
    }

    private func key(_ suffix: String) -> String { accountKey(slot, suffix) }

    init(slot: Int, defaults: UserDefaults = .standard) {
        self.slot = slot
        self.defaults = defaults
        loadSessionCookie()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    func loadSessionCookie() {
        if let savedCookie = defaults.string(forKey: key("cookie")) {
            sessionCookie = savedCookie
        }
    }

    func loadSettings() {
        // Migrate the legacy single notifications_enabled flag (pre-v1.1) into
        // the split keys. Idempotent, so the second manager is a no-op.
        let hasUsageKey  = defaults.object(forKey: "usage_notifications_enabled")  != nil
        let hasStatusKey = defaults.object(forKey: "status_notifications_enabled") != nil

        if !hasUsageKey || !hasStatusKey {
            let legacyHasKey = defaults.object(forKey: "notifications_enabled") != nil
            let legacyValue  = legacyHasKey ? defaults.bool(forKey: "notifications_enabled") : true
            if !hasUsageKey {
                defaults.set(legacyValue, forKey: "usage_notifications_enabled")
            }
            if !hasStatusKey {
                defaults.set(legacyValue, forKey: "status_notifications_enabled")
            }
        }

        lastNotifiedThreshold = defaults.integer(forKey: key("threshold"))
        name = defaults.string(forKey: key("name")) ?? ""
    }

    /// Only the account-scoped settings: the app-wide flags write themselves
    /// through on assignment, so there is no snapshot here left to flush.
    func saveSettings() {
        defaults.set(name, forKey: key("name"))
        defaults.synchronize()
    }

    // Actually register/unregister the app as a macOS login item.
    func applyLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            NSLog("🔑 Login item \(enabled ? "registered" : "unregistered")")
        } catch {
            NSLog("❌ Login item error: \(error.localizedDescription)")
        }
    }

    func saveSessionCookie(_ cookie: String) {
        NSLog("ClaudeUsage: Saving cookie, length: \(cookie.count)")
        sessionCookie = cookie
        defaults.set(cookie, forKey: key("cookie"))
        defaults.synchronize()
        NSLog("ClaudeUsage: Cookie saved successfully")
    }

    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing cookie")
        sessionCookie = ""
        defaults.removeObject(forKey: key("cookie"))
        defaults.synchronize()

        // Reset all data
        sessionUsage = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        weeklyFableUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        weeklyFableResetsAt = nil
        extraSpentMinor = 0
        extraLimitMinor = 0
        extraResetsAt = nil
        freeCreditsMinor = 0
        hasCreditUsage = false
        hasFetchedData = false
        hasWeeklySonnet = false
        hasWeeklyFable = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        // Per-slot: resetting the global key here would clear the other
        // account's notification state as a side effect of clearing this one.
        defaults.set(0, forKey: key("threshold"))

        NSLog("ClaudeUsage: Cookie cleared, data reset")
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = sessionCookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                NSLog("📋 Found org ID in cookie: \(orgId)")
                completion(orgId)
                return
            }
        }

        // If not in cookie, fetch from bootstrap
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionCookie)", forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                completion(nil)
                return
            }
            NSLog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            completion(lastActiveOrgId)
        }.resume()
    }

    func fetchUsage() {
        guard !sessionCookie.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Session cookie not set"
                self.updateStatusBar()
            }
            return
        }

        isLoading = true
        errorMessage = nil

        // Extract org ID from cookie
        fetchOrganizationId { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Could not get org ID from cookie"
                    self?.isLoading = false
                }
                return
            }

            self.fetchUsageWithOrgId(orgId)
            self.fetchExtraUsage(orgId)
            self.fetchFreeCredits(orgId)
        }
    }

    // Remaining free/promo credits (balance) from /prepaid/credits.
    func fetchFreeCredits(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/prepaid/credits") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                // `amount` is the current balance; fall back to summing remaining tranches.
                if let amount = json["amount"] as? Int {
                    self.freeCreditsMinor = amount
                } else {
                    var remaining = 0
                    for key in ["tranches", "promo_tranches"] {
                        if let arr = json[key] as? [[String: Any]] {
                            for t in arr { remaining += (t["remaining_amount_minor_units"] as? Int) ?? 0 }
                        }
                    }
                    self.freeCreditsMinor = remaining
                }
                if let cur = json["currency"] as? String { self.creditCurrency = cur }
                NSLog("🎁 Free credits left: \(self.freeCreditsMinor) \(self.creditCurrency)")
            }
        }.resume()
    }

    // Extra usage spend + monthly limit live on a separate endpoint (not /usage).
    func fetchExtraUsage(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/overage_spend_limit") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                let spent = (json["used_credits"] as? Int) ?? 0
                let limit = (json["monthly_credit_limit"] as? Int) ?? 0
                self.extraSpentMinor = spent
                self.extraLimitMinor = limit
                self.creditCurrency = (json["currency"] as? String) ?? "USD"
                if let resetStr = json["disabled_until"] as? String {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    self.extraResetsAt = f.date(from: resetStr) ?? ISO8601DateFormatter().date(from: resetStr)
                }
                self.hasCreditUsage = spent > 0
                NSLog("💳 Extra usage: \(spent)/\(limit) \(self.creditCurrency)")
            }
        }.resume()
    }

    func fetchUsageWithOrgId(_ orgId: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    NSLog("❌ Error: \(error.localizedDescription)")
                    self?.errorMessage = "Network error"
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if httpResponse.statusCode == 200, let data = data {
                    self?.parseUsageData(data)
                } else {
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageData(_ data: Data) {
        guard let snapshot = parseUsagePayload(data) else {
            errorMessage = "Invalid JSON"
            return
        }

        // Only copy a bucket onto published state when it's present: a
        // partial/malformed payload must retain the previously-good reading
        // instead of zeroing it out, since a zeroed sessionUsage would rearm
        // every notification threshold on the next healthy poll.
        if let session = snapshot.session {
            sessionUsage = session.usage
            sessionLimit = 100
            sessionResetsAt = session.resetsAt
        }
        if let weekly = snapshot.weekly {
            weeklyUsage = weekly.usage
            weeklyLimit = 100
            weeklyResetsAt = weekly.resetsAt
        }
        // hasWeeklySonnet/hasWeeklyFable always track the latest read (not
        // sticky), matching the pre-Task-3 behavior of resetting to false
        // the moment the plan-scoped key stops appearing in the payload.
        hasWeeklySonnet = snapshot.sonnet != nil
        if let sonnet = snapshot.sonnet {
            weeklySonnetUsage = sonnet.usage
            weeklySonnetLimit = 100
            weeklySonnetResetsAt = sonnet.resetsAt
        }
        hasWeeklyFable = snapshot.fable != nil
        if let fable = snapshot.fable {
            weeklyFableUsage = fable.usage
            weeklyFableLimit = 100
            weeklyFableResetsAt = fable.resetsAt
        }

        lastUpdated = Date()
        errorMessage = nil
        hasFetchedData = true
        updatePercentages()
    }

    func updateStatusBar() {
        checkNotificationThresholds(percentage: sessionUsage)
    }

    func checkNotificationThresholds(percentage: Int) {
        guard usageNotificationsEnabled else { return }

        if let threshold = highestCrossedThreshold(percentage: percentage,
                                                   lastNotified: lastNotifiedThreshold) {
            sendNotification(percentage: percentage, threshold: threshold)
        }

        let rearmed = rearmedThreshold(percentage: percentage,
                                       lastNotified: lastNotifiedThreshold)
        if rearmed != lastNotifiedThreshold {
            lastNotifiedThreshold = rearmed
            defaults.set(rearmed, forKey: key("threshold"))
            defaults.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = notificationBody(percentage: percentage, prefix: notificationPrefix)
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = testNotificationBody(prefix: notificationPrefix)
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent successfully")
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0
    @Published var weeklyFablePercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
        weeklyFablePercentage = Double(weeklyFableUsage) / Double(weeklyFableLimit)
    }
}
