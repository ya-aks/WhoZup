//
//  RTProfileView.swift
//  WhoZup
//
//  The "More" tab: profile header, a rhythm strip and stat tiles computed from
//  the user's live groups, and settings rows. Sign out is wired to the real
//  AuthManager; "Invite friends" shares the app link; "Leave a tip" opens the
//  tip sheet.
//

import FirebaseAuth
import SwiftUI

struct RTProfileView: View {
    let onLeaveTip: () -> Void

    @Environment(AuthManager.self) private var authManager
    @Environment(GroupRepository.self) private var repository
    @State private var showHowItWorks = false
    @State private var showDashboard = false

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

                rhythmCard.padding(.top, 22)

                statGrid.padding(.top, 14)

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

    private var rhythmCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your rhythm")
                    .font(.rtDisplay(17, .bold))
                    .foregroundStyle(RT.ink)
                Spacer()
                Text("today · alarm groups")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RT.inkFaint)
            }

            if alarmGroups.isEmpty {
                Text("Join or create an alarm group to start building your rhythm.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .padding(.top, 14)
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(alarmGroups) { group in
                        VStack(spacing: 6) {
                            Circle().fill(myStatus(in: group).chipColor).frame(width: 16, height: 16)
                            Text(String(group.name.prefix(1)).uppercased())
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(RT.inkMuted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 16)

                HStack(spacing: 14) {
                    legend(RT.dotOnTime, "On time")
                    legend(RT.dotSnoozed, "Snoozed")
                    legend(RT.dotLate, "Late")
                }
                .padding(.top, 14)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RT.inkSecondary)
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

    private var settings: some View {
        VStack(spacing: 0) {
            Button { showDashboard = true } label: {
                settingRowContent("Accountability dashboard", trailing: "›")
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDashboard) {
                RTDashboardView(groupId: nil)
            }
            Divider().overlay(RT.divider)
            Button { showHowItWorks = true } label: {
                settingRowContent("How WhoZup works", trailing: "›")
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showHowItWorks) {
                RTHowItWorksSheet(type: nil)
            }
            Divider().overlay(RT.divider)
            ShareLink(item: URL(string: appLink)!, message: Text("Try whoZup with me — we keep each other on time.")) {
                settingRowContent("Invite friends", trailing: "Share app ›")
            }
            .buttonStyle(.plain)
            Divider().overlay(RT.divider)
            Button(action: onLeaveTip) {
                settingRowContent("Leave a tip", trailing: "♥ Optional")
            }
            .buttonStyle(.plain)
            Divider().overlay(RT.divider)
            settingRowContent("Restore purchases", trailing: "›")
            Divider().overlay(RT.divider)
            Button {
                authManager.signOut()
            } label: {
                HStack {
                    Text("Sign out")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RT.dotLate)
                    Spacer()
                }
                .padding(.vertical, 15)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
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
