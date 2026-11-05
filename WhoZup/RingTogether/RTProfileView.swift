//
//  RTProfileView.swift
//  WhoZup
//
//  The "More" tab: profile header and stat tiles computed from
//  the user's live groups, and settings rows. Sign out is wired to the real
//  AuthManager; "Invite friends" shares the app link; "Leave a tip" opens the
//  tip sheet.
//

import FirebaseAuth
import StoreKit
import SwiftUI

struct RTProfileView: View {
    let onLeaveTip: () -> Void

    @Environment(AuthManager.self) private var authManager
    @Environment(GroupRepository.self) private var repository
    @State private var showDashboard = false
    @StateObject private var eventPackStore = EventPackStore.shared
    @State private var restoreAlert: RestoreAlert?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showSignOutConfirm = false
    @State private var isSigningOut = false
    @State private var deleteError: String?
    @State private var showRoutineLog = false

    /// Result of a restore attempt, surfaced as an alert.
    private enum RestoreAlert: Identifiable {
        case restored, nothing, failed(String)
        var id: String {
            switch self {
            case .restored: return "restored"
            case .nothing: return "nothing"
            case .failed(let m): return "failed-\(m)"
            }
        }
    }

    private func restorePurchases() {
        Task {
            let restored = await eventPackStore.restorePurchases()
            if restored {
                restoreAlert = .restored
            } else if let error = eventPackStore.errorMessage {
                // The store sets this to a "nothing to restore" message on an
                // empty result, or the underlying error on failure.
                restoreAlert = error.contains("No previous purchases")
                    ? .nothing : .failed(error)
            } else {
                restoreAlert = .nothing
            }
        }
    }

    /// Placeholder app link — the real store/universal link is added later.
    private let appLink = "https://whozup.app"

    private var email: String { authManager.user?.email ?? "you@whozup.app" }
    private var displayName: String {
        authManager.user?.displayName
            ?? authManager.user?.email.map { String($0.split(separator: "@")[0]) }
            ?? "You"
    }
    private var initial: String { String(displayName.prefix(1)).uppercased() }

    // MARK: Derived, data-driven stats

    private var alarmGroups: [RTGroup] {
        repository.groups.filter { $0.type == .accountability || $0.type == .shared }
    }
    private var eventGroups: [RTGroup] { repository.groups.filter { $0.type == .event } }

    private func myStatus(in group: RTGroup) -> RTStatus {
        group.roster.first { $0.isYou }?.status ?? .waiting
    }

    private var wokeUpCount: Int { alarmGroups.filter { myStatus(in: $0) == .wokeUp }.count }
    private var snoozeCount: Int { alarmGroups.filter { myStatus(in: $0) == .snoozed }.count }
    private var eventsAnswered: Int { eventGroups.filter { myStatus(in: $0) != .noResponse }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Profile")
                    .font(.rtDisplay(28, .bold))
                    .foregroundStyle(RT.ink)

                header.padding(.top, 18)

                statGrid.padding(.top, 22)

                Text("Just your own patterns — no scores, no leaderboards.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .padding(.top, 14)

                settings.padding(.top, 22)
            }
            .padding(20)
            .padding(.bottom, 90)
        }
        .background(RT.canvas)
        .scrollIndicators(.hidden)
        .alert(item: $restoreAlert) { alert in
            switch alert {
            case .restored:
                return Alert(
                    title: Text("Purchases restored"),
                    message: Text("Your Lifetime Unlimited unlock is active again."),
                    dismissButton: .default(Text("OK"))
                )
            case .nothing:
                return Alert(
                    title: Text("Nothing to restore"),
                    message: Text("No previous purchases were found for this Apple ID. Consumable event packs and tips can't be restored."),
                    dismissButton: .default(Text("OK"))
                )
            case .failed(let message):
                return Alert(
                    title: Text("Couldn't restore"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        // Hosted here (on the full-screen root) rather than on the settings card
        // so the dimmed backdrop and centered popup cover the whole screen.
        .overlay { accountActionOverlay }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(initial)
                .font(.rtDisplay(28, .heavy))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(RT.ink))
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.rtDisplay(21, .bold))
                    .foregroundStyle(RT.ink)
                Text(email)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                Text("\(repository.groups.count) group\(repository.groups.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RT.inkFaint)
                    .padding(.top, 1)
            }
            Spacer()
        }
    }

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            statTile("\(repository.groups.count)", "Your groups", RT.ink)
            statTile("\(wokeUpCount)", "Woke up on time", RT.statGreen)
            statTile("\(snoozeCount)", "Snoozes today", RT.ink)
            statTile("\(eventsAnswered)/\(eventGroups.count)", "Events answered", RT.ink)
        }
    }

    private func statTile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.rtDisplay(30, .heavy))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RT.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
    }

    /// The Unlimited events purchase row. Off for now; the purchase code stays.
    static let showUnlimitedEvents = false

    @ViewBuilder private var unlimitedEventsRow: some View {
        Divider().overlay(RT.divider)
        if repository.eventsLifetime {
            settingRowContent("Unlimited events", trailing: "Active ✓")
        } else if let lifetime = eventPackStore.lifetimeProduct {
            // Only offer the purchase when the real StoreKit product loaded —
            // never a fallback price behind a button that can't complete.
            Button {
                Task { _ = await eventPackStore.purchaseLifetime() }
            } label: {
                settingRowContent(
                    "Unlimited events",
                    trailing: eventPackStore.isPurchasing ? "Purchasing…" : lifetime.displayPrice
                )
            }
            .buttonStyle(.plain)
            .disabled(eventPackStore.isPurchasing)
        } else {
            // Product not available (not configured/approved, or offline).
            settingRowContent("Unlimited events", trailing: "Unavailable")
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            Button { showDashboard = true } label: {
                settingRowContent("Rise Reports", trailing: "›")
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDashboard) {
                RTDashboardView(groupId: nil)
            }
            // Hidden while pricing is reworked (docs/pricing.md); flip the flag to bring it back.
            if Self.showUnlimitedEvents { unlimitedEventsRow }
            Divider().overlay(RT.divider)
            ShareLink(item: URL(string: appLink)!, message: Text("Try whoZup with me — we keep each other on time.")) {
                settingRowContent("Invite friends", trailing: "Share app ›")
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { RTAnalytics.appShareOpened() })
            Divider().overlay(RT.divider)
            Button(action: onLeaveTip) {
                settingRowContent("Leave a tip", trailing: "♥ Optional")
            }
            .buttonStyle(.plain)
            Divider().overlay(RT.divider)
            Button(action: restorePurchases) {
                settingRowContent(
                    "Restore purchases",
                    trailing: eventPackStore.isRestoring ? "Restoring…" : "›"
                )
            }
            .buttonStyle(.plain)
            .disabled(eventPackStore.isRestoring)
            Divider().overlay(RT.divider)
            #if DEBUG
            Button { showRoutineLog = true } label: {
                settingRowContent("Routine log", trailing: "Debug ›")
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showRoutineLog) { RTRoutineLogView() }
            Divider().overlay(RT.divider)
            #endif
            Button {
                if !isSigningOut && !isDeleting { showSignOutConfirm = true }
            } label: {
                HStack {
                    Text(isSigningOut ? "Signing out…" : "Sign out")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RT.dotLate)
                    Spacer()
                    if isSigningOut { ProgressView() }
                }
                .padding(.vertical, 15)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut || isDeleting)
            Divider().overlay(RT.divider)
            Button {
                if !isDeleting && !isSigningOut { showDeleteConfirm = true }
            } label: {
                HStack {
                    Text("Delete account")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RT.dotLate)
                    Spacer()
                }
                .padding(.vertical, 15)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeleting || isSigningOut)
        }
        .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
        .alert("Sign out of WhoZup?", isPresented: $showSignOutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { signOut() }
        } message: {
            // Firestore keeps unsent writes on this phone, per account: they go
            // out only when this account is signed in here again with internet.
            if repository.hasPendingStatusSyncs {
                Text("Some of your alarm updates haven't synced yet. Connect to the internet first so your group sees them — otherwise they'll stay on this phone until you sign back in to this account here.")
            } else {
                Text("Are you sure you want to sign out of your account?")
            }
        }
        .alert("Couldn't delete account", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Full-screen center alert + tap-blocker for sign-out / delete. Hosted on the
    /// root view (not the settings card) so the dimmed backdrop and centered card
    /// cover the whole screen — attached to the small card, `.ignoresSafeArea()`
    /// could only expand within that card's frame, leaving the popup over the
    /// bottom options.
    @ViewBuilder private var accountActionOverlay: some View {
        // Sign-out is quick and uses the native alert; while it runs, block
        // interaction so no further action can be taken after confirming.
        if isSigningOut {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .allowsHitTesting(true)
        }
        // Custom center alert for delete: a native `.alert` button can't show a
        // spinner, and the user wants the loader ON the Delete button. While
        // deleting, the button becomes a spinner, Cancel is disabled, and the
        // dimmed backdrop blocks all other interaction. On success the account is
        // gone → auth state flips to nil → the app drops straight to the sign-in
        // screen (this whole view is replaced), so no manual dismissal is needed.
        if showDeleteConfirm {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if !isDeleting { showDeleteConfirm = false } }
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Text("Delete your account?")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(RT.ink)
                        Text("This permanently deletes your account, removes you from all your groups, and erases your data. This can't be undone.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(RT.inkMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    Divider().overlay(RT.divider)
                    HStack(spacing: 0) {
                        Button { showDeleteConfirm = false } label: {
                            Text("Cancel")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(RT.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                        Divider().frame(height: 52).overlay(RT.divider)
                        Button { deleteAccount() } label: {
                            Group {
                                if isDeleting {
                                    ProgressView().tint(RT.dotLate)
                                } else {
                                    Text("Delete account")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(RT.dotLate)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    }
                }
                .frame(maxWidth: 300)
                .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
                .padding(40)
            }
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await authManager.signOut()
        }
    }

    private func deleteAccount() {
        isDeleting = true
        Task {
            // Data first (the writes need auth), then the Auth account itself.
            await repository.deleteAccountData()
            let ok = await authManager.deleteAccount()
            isDeleting = false
            // On success the Auth user is gone → `authManager.user` becomes nil →
            // WhoZupApp swaps RTRootView for AuthView, so the app lands on the
            // sign-in screen directly and this alert is torn down with it. Only
            // on failure do we dismiss the alert and surface the error.
            if !ok {
                showDeleteConfirm = false
                deleteError = authManager.errorMessage ?? "Please try again."
            }
        }
    }

    private func settingRowContent(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RT.ink)
            Spacer()
            Text(trailing)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RT.inkMuted)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}
