//
//  RTEventDetailView.swift
//  WhoZup
//
//  Event group detail, backed by live Firestore data. One-tap Coming /
//  Running late / Can't make it writes the member's response to Firestore and
//  the live responses roster updates for everyone.
//

import SwiftUI

struct RTEventDetailView: View {
    let groupId: String

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss
    @State private var sendingReminder = false
    @State private var showETAPicker = false
    @State private var showShareInvite = false
    @State private var showManageMembers = false
    @State private var inviteAsAdmin = false
    @State private var pendingStatus: RTStatus?
    @State private var submitting = false
    @State private var showErrorAlert = false
    @State private var everLoaded = false
    @State private var showRemoved = false
    @State private var showLeaveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showReassignAdmin = false
    @State private var leaving = false
    @State private var actionError: String?

    private var group: RTGroup? { repository.group(id: groupId) }
    private var isAdmin: Bool { group?.isCurrentUserAdmin ?? false }
    private var liveStatus: RTStatus { group?.roster.first(where: { $0.isYou })?.status ?? .noResponse }
    /// The status to display: an optimistic pending choice, else the live value.
    private var myStatus: RTStatus { pendingStatus ?? liveStatus }
    private var hasResponded: Bool { myStatus != .noResponse }
    private var nonResponderCount: Int { group?.nonResponders.count ?? 0 }
    /// Server-persisted nudge count (survives reload); the cap is 2 per event.
    private var remindersSent: Int { group?.reminderCount ?? 0 }
    private let maxReminders = 5
    private var canRemind: Bool { remindersSent < maxReminders && !sendingReminder }
    /// Past its end time — the event is view-only (no RSVP, nudge, or member management).
    private var isCompleted: Bool { group?.event?.isCompleted ?? false }

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
        .sheet(isPresented: $showETAPicker) {
            RTEventETASheet { selectedETA in
                Task { await respond(.runningLate, eta: selectedETA) }
            }
        }
        .alert("Couldn't save your reply", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repository.lastError ?? "Please try again.")
        }
        .onChange(of: liveStatus) { _, newValue in
            // Once the live value catches up to (or overrides) our optimistic
            // choice, drop the pending state.
            if pendingStatus == newValue { pendingStatus = nil }
        }
        .sheet(isPresented: $showShareInvite) {
            if let group, let code = repository.inviteCode(for: groupId) {
                RTAddMembersView(
                    code: code, groupName: group.name, accent: RTGroupType.event.accent,
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
        // Removed from the event by an admin (or it was deleted): the group
        // drops out of the live list and read access is gone.
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
            noun: "event",
            leaveMessage: "You'll stop seeing updates for this event. You can rejoin later with an invite.",
            deleteMessage: "This removes the event for every member. This can't be undone.",
            onExitRemoved: { dismiss() },
            onLeave: leave,
            onDelete: performDelete,
            onManageMembers: { showManageMembers = true }
        ))
    }

    @ViewBuilder private func dangerZone(_ group: RTGroup) -> some View {
        let isAdmin = group.isCurrentUserAdmin || group.adminUids.isEmpty
        VStack(spacing: 10) {
            // A completed event just needs cleanup: admins delete it for everyone,
            // members leave. An admin has no "leave" (nothing to hand off anymore).
            if isCompleted {
                if isAdmin {
                    RTDestructiveButton(title: "Delete event", icon: "trash") {
                        showDeleteConfirm = true
                    }
                } else {
                    RTDestructiveButton(title: "Leave event",
                                        icon: "rectangle.portrait.and.arrow.right") {
                        showLeaveConfirm = true
                    }
                }
            } else {
                RTDestructiveButton(title: "Leave event",
                                    icon: "rectangle.portrait.and.arrow.right") {
                    if group.isSoleAdminWithOthers { showReassignAdmin = true }
                    else { showLeaveConfirm = true }
                }
                // Admins can delete; so can any member of an admin-less legacy group.
                if isAdmin {
                    RTDestructiveButton(title: "Delete event", icon: "trash") {
                        showDeleteConfirm = true
                    }
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

    @ViewBuilder private func content(_ group: RTGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RTBadge(text: group.planKind != nil ? "Plan" : "Event", color: RTGroupType.event.eyebrow, background: RTGroupType.event.badgeBackground)

                Text(group.name)
                    .font(.rtDisplay(30, .bold))
                    .foregroundStyle(RT.ink)
                    .padding(.top, 10)

                let noun = group.planKind != nil ? "plan" : "event"
                Text(isCompleted
                     ? "\(noun.capitalized) ended · view only"
                     : (isAdmin ? "Active \(noun) · you're admin" : "Active \(noun)"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RT.inkMuted)
                    .padding(.top, 2)

                if let description = group.detailedDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(RTGroupType.event.badgeBackground))
                        .padding(.top, 8)
                }

                eventCard(group).padding(.top, 16)

                // Plans: the host's headcount for a one-time plan.
                if !isCompleted, group.planKind == .once, group.isCurrentUserAdmin, let start = group.event?.date {
                    RTHeadcountCard(groupId: group.id, headcount: RTHeadcount(eventRoster: group.roster),
                                    asks: group.planAsks, start: start, sessionKey: GroupRepository.dayKey(start))
                        .padding(.top, 16)
                }

                if isCompleted {
                    Label("This event has ended. Responses are closed.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.top, 16)
                } else {
                    replyButtons.padding(.top, 14)

                    Text(hasResponded ? "Tap another option to change your reply." : "Reply in one tap — your group sees it live.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.top, 8)

                    if isAdmin {
                        HStack(spacing: 10) {
                            adminActionButton("Share invite", icon: "person.badge.plus") { showShareInvite = true }
                            adminActionButton("Manage", icon: "person.2") { showManageMembers = true }
                        }
                        .padding(.top, 14)
                    }
                }

                HStack {
                    Text("Responses")
                        .font(.rtDisplay(18, .bold))
                        .foregroundStyle(RT.ink)
                    Spacer()
                    RTLiveBadge()
                }
                .padding(.top, 26)

                VStack(spacing: 0) {
                    ForEach(Array(group.roster.enumerated()), id: \.element.id) { index, member in
                        RTMemberRow(member: member)
                        if index < group.roster.count - 1 {
                            Divider().overlay(RT.divider)
                        }
                    }
                }
                .padding(.top, 14)

                // Nudge is admin-only, hidden once the event has ended, and only
                // shown when there are actually members who haven't responded.
                if isAdmin && !isCompleted && nonResponderCount > 0 {
                    reminderButton.padding(.top, 16)
                }

                dangerZone(group).padding(.top, 28)
            }
            .padding(20)
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
    }

    private func eventCard(_ group: RTGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.event?.title ?? "")
                .font(.rtDisplay(22, .bold))
                .foregroundStyle(.white)

            if let when = group.event?.whenLabel, !when.isEmpty {
                Label(when, systemImage: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 6)
            }

            Text(group.event?.place ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 4)

            HStack {
                Text("Your reply")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(myStatus.label)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.22)))
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(RTGroupType.event.gradient))
        .shadow(color: RTGroupType.event.accent.opacity(0.28), radius: 20, y: 12)
    }

    private var replyButtons: some View {
        HStack(spacing: 10) {
            replyButton("Coming", color: Color(hex: "#1f6a8c"), bg: Color(hex: "#e0eff5"), selected: myStatus == .coming) {
                Task { await respond(.coming) }
            }
            replyButton("Running late", color: Color(hex: "#9a6410"), bg: Color(hex: "#fbeed6"), selected: myStatus == .runningLate) {
                showETAPicker = true
            }
            replyButton("Can't make it", color: Color(hex: "#a83f2e"), bg: Color(hex: "#f7e0da"), selected: myStatus == .cantMakeIt) {
                Task { await respond(.cantMakeIt) }
            }
        }
        .opacity(submitting ? 0.6 : 1)
        .disabled(submitting)
    }

    private func adminActionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(RTGroupType.event.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14).fill(RTGroupType.event.accent.opacity(0.12)))
        }
        .buttonStyle(RTPressStyle())
    }

    private func replyButton(_ title: String, color: Color, bg: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? color : bg))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? color : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(RTPressStyle())
    }

    private var reminderButton: some View {
        Button {
            guard canRemind else { return }
            sendingReminder = true
            Task {
                let ok = await repository.sendReminder(groupId: groupId)
                sendingReminder = false
                if !ok { showErrorAlert = true }
            }
        } label: {
            Text(remindersSent >= maxReminders
                 ? "Reminder limit reached (max \(maxReminders))"
                 : (sendingReminder
                    ? "Sending…"
                    : "Nudge \(nonResponderCount) non-responder\(nonResponderCount == 1 ? "" : "s") · \(maxReminders - remindersSent) left"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(canRemind ? RTGroupType.accountability.accent : RT.inkFaint)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(canRemind ? Color(hex: "#e4eef5") : RT.cardBorderPressed))
        }
        .buttonStyle(.plain)
        .disabled(!canRemind)
    }

    private func respond(_ status: RTStatus, eta: String? = nil) async {
        let previous = pendingStatus
        pendingStatus = status          // optimistic: reflect immediately
        submitting = true
        defer { submitting = false }

        let ok = await repository.recordEventResponse(groupId: groupId, status: status, eta: eta)
        if !ok {
            pendingStatus = previous     // revert on failure
            showErrorAlert = true
        }
    }
}
