import Combine
import Foundation

final class AccountsStore: ObservableObject {
    static let slots = [1, 2]

    let accounts: [UsageManager]
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        // First statement in the body, before any UsageManager exists: each
        // manager reads its cookie in its own init, so a migration that ran
        // after them would leave an upgrading user looking unconfigured and
        // asking for a cookie they already gave us.
        migrateAccounts(defaults)
        accounts = Self.slots.map { UsageManager(slot: $0) }

        // A nested ObservableObject does not notify its parent. Without this
        // republish, pasting a cookie into account 2 would not make its menu
        // bar item or its popover section appear — no error, no log, the UI
        // simply would not update.
        for account in accounts {
            account.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// Configured means "has a cookie" — one fact, nothing to desynchronise.
    var configured: [UsageManager] { accounts.filter { $0.hasCookie } }

    var showsBadges: Bool { configured.count > 1 }

    func refreshAll() {
        for account in configured { account.fetchUsage() }
    }
}
