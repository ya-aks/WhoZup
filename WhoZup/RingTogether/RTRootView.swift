//
//  RTRootView.swift
//  WhoZup
//
//  The RingTogether app shell: four tabs (Accountability, Shared, Events,
//  More) with a custom bottom tab bar, plus the alarm-ring and tip sheets.
//  Backed by a live Firestore `GroupRepository`.
//

import FirebaseAuth
import SwiftUI

enum RTTab: String, CaseIterable {
    case accountability, shared, events, more
}

struct RTRootView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(PendingInviteStore.self) private var pendingInvite
    @Environment(PendingGroupStore.self) private var pendingGroup
    @Environment(\.alarmScheduler) private var alarmScheduler
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var alarmStatusRecorder: AlarmStatusRecorder
    @State private var repository = GroupRepository()
    @State private var alarmSync: RTAlarmSync?

    @State private var tab: RTTab = .accountability
    @State private var showTipSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RT.canvas.ignoresSafeArea()

            Group {
                switch tab {
                case .accountability:
                    RTGroupListView(type: .accountability)
                case .shared:
                    RTGroupListView(type: .shared)
                case .events:
                    RTGroupListView(type: .event)
                case .more:
                    RTProfileView(onLeaveTip: { showTipSheet = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                if repository.hasPendingStatusSyncs {
                    RTSyncPendingBanner()
                }
                RTTabBar(selected: $tab)
            }
        }
        .environment(repository)
        .sheet(isPresented: $showTipSheet) {
            RTTipSheet()
        }
        // The habit routine: opened by the lock-screen card, the "Start your
        // routine" notification, or a Stop that opens the app.
        .fullScreenCover(isPresented: Binding(
            get: { RoutineCoordinator.shared.presentRoutine },
            set: { RoutineCoordinator.shared.presentRoutine = $0 }
        )) {
            RTRoutineView()
        }
        // An invite link tapped while signed out parks its code in the store;
        // this view only exists once signed in, so presenting from here is what
        // resumes the flow after authentication.
        .sheet(item: Binding(
            get: { pendingInvite.code.map(PendingInviteCode.init) },
            set: { if $0 == nil { pendingInvite.clear() } }
        )) { pending in
            RTInviteConfirmView(code: pending.id) { pendingInvite.clear() }
                .environment(repository)
        }
        // A tapped notification parks a group id; switch to that group's tab so
        // its list (which then pushes the detail) is the one on screen. Re-run
        // when groups load, in case the tap cold-started the app before the
        // repository had the group.
        .onChange(of: pendingGroup.groupId) { _, _ in switchTabForPendingGroup() }
        .onChange(of: repository.groups.map(\.id)) { _, _ in switchTabForPendingGroup() }
        .onAppear {
            repository.bindAlarmRecorder(alarmStatusRecorder)
            if alarmSync == nil {
                alarmSync = RTAlarmSync(
                    scheduler: alarmScheduler,
                    recorder: alarmStatusRecorder,
                    repository: repository
                )
            }
        }
        .task(id: authManager.user?.uid) {
            if let user = authManager.user {
                repository.start(
                    uid: user.uid,
                    displayName: user.displayName
                        ?? user.email.map { String($0.split(separator: "@")[0]) }
                        ?? "You"
                )
            } else {
                repository.stop()
            }
        }
        .task(id: RTAlarmSync.signature(for: repository.groups)) {
            // Write any alarm response that couldn't be written when it happened.
            await AlarmActionHandler.drainJournal()
            await alarmSync?.reconcile()
            // Back-fill any alarms that were skipped while the app wasn't running
            // (device off, never dismissed) — mark them silent-late after the
            // deadline, since nothing else would.
            await repository.reconcileMissedAlarms()
        }
        // Coming back to the foreground can cross an alarm's deadline while the
        // app sat in the background, so re-check for skipped alarms then too.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Opened with a routine still open: put its card on the lock screen.
                RoutineCoordinator.shared.ensureLiveActivity()
                Task {
                    await AlarmReliability.sweep()
                    await repository.reconcileMissedAlarms()
                }
            }
        }
        // Crossing a time zone changes what a shared group's wake-up means
        // locally. Rebuilding re-converts every alarm, which moves the sync
        // signature above and re-targets the on-device alarms.
        .task {
            let changes = NotificationCenter.default.notifications(
                named: Notification.Name.NSSystemTimeZoneDidChange
            )
            for await _ in changes {
                repository.refreshForTimeZoneChange()
            }
        }
    }

    private func switchTabForPendingGroup() {
        guard let id = pendingGroup.groupId, let group = repository.group(id: id) else { return }
        switch group.type {
        case .accountability: tab = .accountability
        case .shared: tab = .shared
        case .event: tab = .events
        }
    }
}

/// App-wide notice shown just above the tab bar (so it's visible on every tab)
/// whenever one of your status responses is recorded locally but not yet synced.
/// Purely informational — Firestore syncs the queued write automatically once
/// the device is back online, which clears the banner.
struct RTSyncPendingBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .bold))
            Text("Some status updates are pending — connect to the internet to sync.")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(hex: "#7a4f0a"))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#fbeed6"))
    }
}

/// Custom bottom tab bar matching the design's glyphs (outline circle, filled
/// circle, rounded square, three dots).
struct RTTabBar: View {
    @Binding var selected: RTTab

    var body: some View {
        HStack {
            tabItem(.accountability, "Check-ins")
            tabItem(.shared, "In Sync")
            tabItem(.events, "Events")
            tabItem(.more, "More")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(
            RT.card
                .overlay(RT.cardBorder.frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabItem(_ tab: RTTab, _ label: String) -> some View {
        let active = selected == tab
        let color: Color = active ? activeColor(tab) : RT.inkFaint
        return Button {
            selected = tab
        } label: {
            VStack(spacing: 5) {
                glyph(tab, color: color).frame(height: 24)
                Text(label)
                    .font(.system(size: 11, weight: active ? .bold : .semibold))
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func activeColor(_ tab: RTTab) -> Color {
        switch tab {
        case .accountability: return RTGroupType.accountability.accent
        case .shared: return RTGroupType.shared.accent
        case .events: return RTGroupType.event.accent
        case .more: return RT.ink
        }
    }

    @ViewBuilder private func glyph(_ tab: RTTab, color: Color) -> some View {
        Image(assetName(tab))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .foregroundStyle(color)
    }

    private func assetName(_ tab: RTTab) -> String {
        switch tab {
        case .accountability: return "tab-accountability"
        case .shared: return "tab-shared"
        case .events: return "tab-events"
        case .more: return "tab-more"
        }
    }
}
