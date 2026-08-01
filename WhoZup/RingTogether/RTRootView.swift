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
    @Environment(\.alarmScheduler) private var alarmScheduler
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

            RTTabBar(selected: $tab)
        }
        .environment(repository)
        .sheet(isPresented: $showTipSheet) {
            RTTipSheet()
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
            await alarmSync?.reconcile()
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
}

/// Custom bottom tab bar matching the design's glyphs (outline circle, filled
/// circle, rounded square, three dots).
struct RTTabBar: View {
    @Binding var selected: RTTab

    var body: some View {
        HStack {
            tabItem(.accountability, "Accountability")
            tabItem(.shared, "Shared")
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
