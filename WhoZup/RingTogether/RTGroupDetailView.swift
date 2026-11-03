//
//  RTGroupDetailView.swift
//  WhoZup
//
//  Accountability / Shared group detail, backed by live Firestore data. The
//  hero card shows the wake-up time with an elegant Edit-alarm control
//  (accountability: your own time; shared: admin-only). Members can share the
//  invite (code + QR) subject to group visibility rules, and admins can manage
//  the admin roster. Alarms are scheduled automatically by RTAlarmSync — no
//  manual "set alarm" step.
//

import FirebaseCore
import FirebaseFirestore
import SwiftUI

struct RTGroupDetailView: View {
    let groupId: String

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var showEditAlarm = false
    @State private var showHabitSheet = false
    @State private var showShareInvite = false
    @State private var showManageMembers = false
    @State private var showDashboard = false
    @State private var inviteAsAdmin = false
    @State private var everLoaded = false
    @State private var showRemoved = false
    @State private var showLeaveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showReassignAdmin = false
    // Set the moment the user chooses to leave/delete, so the group vanishing
    // from the live list reads as intentional (dismiss) rather than "you were
    // removed" (the removed alert below).
    @State private var leaving = false
    @State private var actionError: String?

    private var group: RTGroup? { repository.group(id: groupId) }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RT.canvas)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RT.inkSecondary)
                }
            }
        }
        .toolbarBackground(RT.canvas, for: .navigationBar)
        .sheet(isPresented: $showEditAlarm) {
            if let group { RTEditAlarmSheet(group: group) }
        }
        .sheet(isPresented: $showHabitSheet) {
            RTHabitSheet(groupId: groupId)
        }
        .sheet(isPresented: $showShareInvite) {
            if let group, let code = repository.inviteCode(for: groupId) {
                RTAddMembersView(
                    code: code,
                    groupName: group.name,
                    accent: group.type.accent,
                    adminToggle: group.isCurrentUserAdmin ? $inviteAsAdmin : nil,
                    onAdminToggleChange: { value in
                        Task { await repository.setInviteAsAdmin(groupId: groupId, asAdmin: value) }
                    }
                )
            }
        }
        .sheet(isPresented: $showManageMembers) {
            RTManageMembersView(groupId: groupId)
        }
        .sheet(isPresented: $showDashboard) {
            RTDashboardView(groupId: groupId)
        }
        // Once the group has loaded, its later disappearance from the live list
        // means an admin removed us (or deleted it) — we lose membership and
        // read access at once.
        .onChange(of: group?.id) { _, id in
            if id != nil { everLoaded = true }
            else if everLoaded && !leaving { showRemoved = true }
        }
        .modifier(RTGroupExitDialogs(
            showRemoved: $showRemoved,
            showLeave: $showLeaveConfirm,
            showDelete: $showDeleteConfirm,
            showReassignAdmin: $showReassignAdmin,
            actionError: $actionError,
            noun: "group",
            leaveMessage: "Your alarm for this group will be removed from your phone. You can rejoin later with an invite.",
            deleteMessage: "This removes the group and its alarm for every member. This can't be undone.",
            onExitRemoved: { dismiss() },
            onLeave: leave,
            onDelete: performDelete,
            onManageMembers: { showManageMembers = true }
        ))
    }

    @ViewBuilder private func content(_ group: RTGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    RTBadge(text: group.type == .accountability ? "Check-ins" : "In Sync",
                            color: group.type.eyebrow,
                            background: group.type.badgeBackground)
                    if group.isCurrentUserAdmin {
                        RTBadge(text: "Admin", color: RT.inkSecondary, background: RT.cardBorder)
                    }
                }

                Text(group.name)
                    .font(.rtDisplay(30, .bold))
                    .foregroundStyle(RT.ink)
                    .padding(.top, 10)

                if let description = group.detailedDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(group.type.badgeBackground))
                        .padding(.top, 8)
                }

                heroCard(group).padding(.top, 14)

                // "What it is" first: your habit (Check-ins only; habits are
                // personal), or the invitation to add one.
                let me = group.type == .accountability ? group.roster.first(where: { $0.isYou }) : nil
                if let me {
                    if let habit = me.habit {
                        RTYourHabitSection(habit: habit, alarm: group.alarm) { showHabitSheet = true }
                            .padding(.top, 18)
                    } else {
                        RTAddHabitCard(
                            othersWithHabit: group.roster.filter { !$0.isYou && $0.hasHabit }.count,
                            memberCount: group.roster.count
                        ) { showHabitSheet = true }
                        .padding(.top, 12)
                    }
                }

                actionRow(group).padding(.top, 12)

                // Then "today's status": routine progress and the check-in.
                if let me, let habit = me.habit {
                    RTTodayRoutineCard(groupId: group.id, habit: habit, routine: me.routine, alarm: group.alarm)
                        .padding(.top, 26)
                }

                RTCheckInCard(groupId: group.id, accent: group.type.accent, topSpacing: 12)

                liveStatusHeader.padding(.top, 26)

                VStack(spacing: 0) {
                    ForEach(Array(group.roster.enumerated()), id: \.element.id) { index, member in
                        RTMemberRow(member: member)
                        if index < group.roster.count - 1 {
                            Divider().overlay(RT.divider)
                        }
                    }
                }
                .padding(.top, 14)

                if group.canShareInvite {
                    Button { showShareInvite = true } label: {
                        Label("Add members", systemImage: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(group.type.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                                    .foregroundStyle(group.type.accent.opacity(0.5))
                            )
                    }
                    .buttonStyle(RTPressStyle())
                    .padding(.top, 14)
                }

                Text(group.detailFootNote)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .padding(.top, 16)

                dangerZone(group).padding(.top, 28)
            }
            .padding(20)
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
    }

    private func heroCard(_ group: RTGroup) -> some View {
        let canEdit = group.type == .accountability || group.isCurrentUserAdmin
        return VStack(alignment: .leading, spacing: 0) {
            Text(group.detailAlarmLabel.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.75))

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(group.alarm.isEmpty ? "—" : timeNumber(group.alarmDisplay))
                    .font(.rtDisplay(74, .heavy))
                    .foregroundStyle(.white)
                if !group.alarm.isEmpty {
                    Text(timePeriod(group.alarmDisplay))
                        .font(.rtDisplay(22, .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.top, 6)

            Text(group.detailAlarmMeta)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 2)

            if !group.alarm.isEmpty {
                Label(group.alarmDaysLabel, systemImage: "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 6)
            }

            if canEdit {
                Button { showEditAlarm = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                        Text(group.alarm.isEmpty ? "Set alarm time" : "Edit alarm")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.18)))
                }
                .buttonStyle(RTPressStyle())
                .padding(.top, 18)
            } else {
                Text("Only an admin can change the group alarm time.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 14)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(group.type.gradient))
        .shadow(color: group.type.accent.opacity(0.28), radius: 20, y: 12)
    }

    @ViewBuilder private func actionRow(_ group: RTGroup) -> some View {
        HStack(spacing: 10) {
            secondaryButton("Rise Report", icon: "chart.bar", accent: group.type.accent) {
                showDashboard = true
            }
            if group.isCurrentUserAdmin {
                secondaryButton("Manage members", icon: "person.2", accent: group.type.accent) {
                    showManageMembers = true
                }
            }
        }
    }

    private func secondaryButton(_ title: String, icon: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.12)))
        }
        .buttonStyle(RTPressStyle())
    }

    /// Leave (everyone) and, for admins, Delete. Kept visually quiet and set
    /// apart at the bottom so a destructive tap is deliberate.
    @ViewBuilder private func dangerZone(_ group: RTGroup) -> some View {
        VStack(spacing: 10) {
            RTDestructiveButton(title: "Leave group",
                                icon: "rectangle.portrait.and.arrow.right") {
                if group.isSoleAdminWithOthers { showReassignAdmin = true }
                else { showLeaveConfirm = true }
            }
            // Admins can delete; so can any member of an admin-less legacy group.
            if group.isCurrentUserAdmin || group.adminUids.isEmpty {
                RTDestructiveButton(title: "Delete group", icon: "trash") {
                    showDeleteConfirm = true
                }
            }
        }
    }

    private func leave() {
        leaving = true
        Task {
            if await repository.leaveGroup(groupId: groupId) {
                dismiss()
            } else {
                leaving = false
                actionError = repository.lastError ?? "Please try again."
            }
        }
    }

    private func performDelete() {
        leaving = true
        Task {
            if await repository.deleteGroup(groupId: groupId) {
                dismiss()
            } else {
                leaving = false
                actionError = repository.lastError ?? "Please try again."
            }
        }
    }

    /// "6:30" from "6:30 AM".
    private func timeNumber(_ display: String) -> String {
        display.split(separator: " ").first.map(String.init) ?? display
    }
    /// "AM" from "6:30 AM".
    private func timePeriod(_ display: String) -> String {
        display.split(separator: " ").last.map(String.init) ?? ""
    }

    private var liveStatusHeader: some View {
        HStack {
            Text("Group status")
                .font(.rtDisplay(18, .bold))
                .foregroundStyle(RT.ink)
            Spacer()
            RTLiveBadge()
        }
    }
}

/// A quiet, full-width destructive action (Leave / Delete). Muted until pressed
/// so it doesn't compete with the primary actions above it.
struct RTDestructiveButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(RT.dotLate)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(RT.dotLate.opacity(0.35), lineWidth: 1.5)
                )
        }
        .buttonStyle(RTPressStyle())
    }
}

/// The "removed", "leave", "delete", and error dialogs shared by the
/// accountability/shared and event detail screens. Extracting them keeps each
/// screen's `body` modifier chain short enough for the type-checker and avoids
/// duplicating four near-identical dialogs. `noun` is "group" or "event".
struct RTGroupExitDialogs: ViewModifier {
    @Binding var showRemoved: Bool
    @Binding var showLeave: Bool
    @Binding var showDelete: Bool
    @Binding var showReassignAdmin: Bool
    @Binding var actionError: String?
    let noun: String
    let leaveMessage: String
    let deleteMessage: String
    let onExitRemoved: () -> Void
    let onLeave: () -> Void
    let onDelete: () -> Void
    let onManageMembers: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Removed from group", isPresented: $showRemoved) {
                Button("Exit", action: onExitRemoved)
            } message: {
                Text("You've been removed from this group. You can rejoin if someone shares an invite.")
            }
            .alert("Leave this \(noun)?", isPresented: $showLeave) {
                Button("Leave \(noun)", role: .destructive, action: onLeave)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(leaveMessage)
            }
            // Shown instead of the plain leave confirm when the leaver is the
            // group's only admin: they must hand off admin or delete, since a
            // group can't be left admin-less while it still has members.
            .alert("You're the only admin", isPresented: $showReassignAdmin) {
                Button("Make someone else an admin", action: onManageMembers)
                Button("Delete \(noun) for everyone", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Before you can leave, make another member an admin — or delete the \(noun) for everyone.")
            }
            .alert("Delete this \(noun) for everyone?", isPresented: $showDelete) {
                Button("Delete \(noun)", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert("Couldn't do that", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
    }
}

/// A rounded rectangular badge (detail-screen type tag).
struct RTBadge: View {
    let text: String
    let color: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
    }
}

/// Dot + "LIVE" badge.
struct RTLiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(RT.dotLate).frame(width: 7, height: 7)
            Text("LIVE")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(RT.inkMuted)
        }
    }
}

/// One member row on a detail screen.
struct RTMemberRow: View {
    let member: RTMember

    var body: some View {
        HStack(spacing: 12) {
            RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(RT.ink)
                    if member.isAdmin {
                        Text("admin")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(RT.inkFaint)
                    }
                }
                Text(member.detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                if member.hasHabit { habitLines }
                if member.pendingSync {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .bold))
                        Text("Not synced — will sync when online")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: "#9a6410"))
                }
            }
            Spacer()
            RTStatusChip(status: member.status)
        }
        .padding(.vertical, 12)
    }

    /// The routine bar (only after an on-time stop) above the habit name.
    @ViewBuilder private var habitLines: some View {
        let skipped = member.status == .snoozed || member.status == .silentLate || member.status == .runningLate
        if let routine = member.routine, member.status == .wokeUp {
            HStack(spacing: 8) {
                RTRoutineBar(done: routine.done, tiny: routine.tiny, tinySteps: routine.tinySteps)
                    .frame(width: 96)
                Text(routineLabel(routine))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(routine.isComplete ? RT.dotOnTime : RT.inkSecondary)
            }
            .padding(.top, 4)
        }
        let name = member.habit?.name ?? "Building a habit"
        Text(skipped ? "\(name) · no routine today" : name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(skipped ? RT.inkMuted : RT.dotOnTime)
    }

    private func routineLabel(_ routine: RoutineProgress) -> String {
        if routine.tiny { return "Tiny version" }
        if routine.isComplete, let at = routine.completedAt?.dateValue() {
            return "Done \(RTAlarmTime.display(RTAlarmTime.string(from: at)))"
        }
        return routine.summary
    }
}
