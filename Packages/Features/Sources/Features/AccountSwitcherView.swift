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

    /// Same sort as RootView — most-recently-selected first. `accounts.first`
    /// is therefore the active account (gets the checkmark).
    @Query(sort: \Account.lastSelectedAt, order: .reverse)
    private var accounts: [Account]

    @State private var isAddingAccount = false
    @State private var errorMessage: String?

    /// The active account's userId — `accounts.first`. Drives the
    /// checkmark. nil only in the degenerate empty-list case (which
    /// shouldn't happen while this sheet is open, since you reach it
    /// from a signed-in Profile).
    private var activeUserId: String? { accounts.first?.userId }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(accounts) { account in
                        Button {
                            switchTo(account)
                        } label: {
                            AccountRowLabel(
                                account: account,
                                isActive: account.userId == activeUserId
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

    /// Switch to `account` and dismiss. selectAccount bumps lastSelectedAt;
    /// the reactive chain in RootView handles the actual swap.
    private func switchTo(_ account: Account) {
        // Already active — just close.
        guard account.userId != activeUserId else {
            dismiss()
            return
        }
        let userId = account.userId
        Task {
            await accountStore.selectAccount(userId: userId)
            // dismiss here is belt-and-braces — if this was the active
            // account swap, RootView's `.id(userId)` change tears down
            // this whole sheet anyway. Dismissing first avoids a flash
            // of the sheet over the re-rendered shell.
            dismiss()
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

// MARK: - Row label

/// One account row: avatar + display name + @login, with a checkmark on
/// the active account.
private struct AccountRowLabel: View {
    let account: Account
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(url: URL(string: account.profileImageURL)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text("@\(account.login)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.displayName)\(isActive ? ", active" : "")")
    }
}
