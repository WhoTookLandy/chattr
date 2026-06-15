import SwiftUI
import SwiftData
import Accounts
import Core
import NukeUI
import os

private let logger = AppLogger.make("Features.AccountSwitcher")

/// Sheet for switching between signed-in Twitch accounts and adding new
/// ones. Presented from `ProfileScreen`'s tappable account header.
///
/// ## How switching works
///
/// The "active" account is the one with the most recent `lastSelectedAt`
/// (RootView sorts `@Query` by it). Tapping an account calls
/// `AccountStore.selectAccount`, which bumps that timestamp — SwiftData
/// `@Query` reactivity then floats the account to the top, RootView
/// re-renders `AppShell` with it (forced fresh via `.id(userId)`), and
/// this sheet's underlying ProfileScreen is torn down with the old
/// AppShell. So tapping a row + dismiss is all the UI does; the rest
/// flows through the data layer.
struct AccountSwitcherView: View {
    let accountStore: AccountStore
    let clientId: String

    @Environment(\.dismiss) private var dismiss

    /// Same sort as RootView — most-recently-added first.
    @Query(sort: \Account.addedAt, order: .reverse)
    private var accounts: [Account]

    /// The stored active-account selection (UserDefaults via @AppStorage,
    /// same key RootView reads). Drives the checkmark.
    @AppStorage(AccountStore.activeAccountUserIdKey) private var storedActiveUserId: String = ""

    @State private var isAddingAccount = false
    @State private var errorMessage: String?

    /// The effective active account's userId: the stored selection if it
    /// resolves to a real, healthy account, else the most-recently-added
    /// healthy one (fallback, mirroring RootView's `activeAccount` logic —
    /// `needsReauth` accounts can't be active, so they never get the
    /// checkmark).
    private var activeUserId: String? {
        if !storedActiveUserId.isEmpty,
           let match = accounts.first(where: { $0.userId == storedActiveUserId }),
           !match.needsReauth {
            return storedActiveUserId
        }
        return accounts.first(where: { !$0.needsReauth })?.userId
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(accounts) { account in
                        Button {
                            switchTo(account)
                        } label: {
                            AccountRow(
                                account: account,
                                isActive: account.userId == activeUserId,
                                style: .listRow
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: removeAccounts)
                }

                Section {
                    Button {
                        Task { await addAccount() }
                    } label: {
                        Label("Add Account", systemImage: "person.badge.plus")
                    }
                    .disabled(isAddingAccount)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Accounts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    /// Switch to `account` and dismiss. selectAccount writes the active
    /// userId to UserDefaults; RootView's @AppStorage observes it and
    /// re-renders AppShell with the new account.
    ///
    /// Expired accounts route to re-auth instead — selecting them would
    /// render an AppShell whose every Helix call fails.
    private func switchTo(_ account: Account) {
        if account.needsReauth {
            Task { await reauthorize(account) }
            return
        }
        // Already active — just close.
        guard account.userId != activeUserId else {
            dismiss()
            return
        }
        // selectAccount is sync (UserDefaults write + setActive). The
        // @AppStorage in RootView reacts; the `.id(userId)` change tears
        // down this sheet's host AppShell. Dismiss to avoid a flash of
        // the sheet over the re-rendered shell.
        //
        // The Account-taking overload reads the platform off the row, so
        // the selection lands in the right per-platform slot when Kick /
        // YouTube accounts join this list.
        accountStore.selectAccount(account)
        dismiss()
    }

    /// Re-run the OAuth flow for an expired account. Same flow as "Add
    /// Account" — `AccountStore.add` upserts on the unique `userId`, which
    /// replaces the row's fields (clearing `needsReauth`, since a fresh
    /// `Account` defaults to false) and persists the new tokens under the
    /// same `tokenNamespace`. On success the account becomes active and
    /// we dismiss into it.
    private func reauthorize(_ account: Account) async {
        isAddingAccount = true
        errorMessage = nil
        defer { isAddingAccount = false }
        do {
            _ = try await TwitchSignIn.run(accountStore: accountStore, clientId: clientId)
            dismiss()
        } catch {
            logger.error("Re-authorize failed for @\(account.login): \(error.localizedDescription)")
            errorMessage = (error as? AppError)?.message ?? error.localizedDescription
        }
    }

    /// Run the shared OAuth flow to add a new account. On success it
    /// becomes active automatically (its lastSelectedAt defaults to now),
    /// so we dismiss — RootView re-renders into the new account.
    private func addAccount() async {
        isAddingAccount = true
        errorMessage = nil
        defer { isAddingAccount = false }
        do {
            _ = try await TwitchSignIn.run(accountStore: accountStore, clientId: clientId)
            dismiss()
        } catch {
            logger.error("Add account failed: \(error.localizedDescription)")
            errorMessage = (error as? AppError)?.message ?? error.localizedDescription
        }
    }

    /// Swipe-to-delete. Removing the active account tears down AppShell
    /// (RootView `.id` change) and thus this sheet — acceptable: you land
    /// on the next account, or SignInView if it was the last.
    private func removeAccounts(at offsets: IndexSet) {
        let toRemove = offsets.map { accounts[$0] }
        Task {
            for account in toRemove {
                do {
                    try await accountStore.remove(account: account)
                } catch {
                    logger.error("Remove account failed: \(error.localizedDescription)")
                    errorMessage = "Couldn't remove account: \(error.localizedDescription)"
                }
            }
        }
    }
}
