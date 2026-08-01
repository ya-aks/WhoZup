//
//  RTInviteConfirmView.swift
//  WhoZup
//
//  The join confirmation shown after an invite link is tapped. Joining a group
//  schedules a real alarm on this device, so the invite is never applied
//  silently — the user sees what they're agreeing to and accepts explicitly.
//
//  Everything rendered here comes from the invite document. Firestore rules
//  deny a non-member any read of `groups/{id}`, so the denormalized copy on the
//  invite is the only preview available before joining.
//

import SwiftUI

struct RTInviteConfirmView: View {
    let code: String
    /// Called when the sheet is finished with, whether or not a join happened.
    var onFinish: () -> Void

    @Environment(GroupRepository.self) private var repository

    private enum Phase {
        case loading
        case ready(InviteDoc)
        case notFound
        case joining
        case failed(String)
        case joined(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    switch phase {
                    case .loading:
                        loadingState
                    case .ready(let invite):
                        invitation(invite, isJoining: false)
                    case .joining:
                        joiningState
                    case .notFound:
                        message(
                            title: "Invite not found",
                            body: "That invite link is no longer valid. Ask whoever sent it for a new one."
                        )
                    case .failed(let reason):
                        message(title: "Couldn't join", body: reason)
                    case .joined(let name):
                        message(title: "You're in", body: "Welcome to \(name).")
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .background(RT.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onFinish() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking up this invite…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RT.inkMuted)
        }
        .padding(.top, 60)
    }

    private var joiningState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Joining…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RT.inkMuted)
        }
        .padding(.top, 60)
    }

    private func message(title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.rtDisplay(24, .bold))
                .foregroundStyle(RT.ink)
            Text(body)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button(action: onFinish) {
                Text("Done")
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(15)
                    .background(RoundedRectangle(cornerRadius: 16).fill(RT.ink))
            }
            .buttonStyle(RTPressStyle())
            .padding(.top, 18)
        }
        .padding(.top, 50)
    }

    private func invitation(_ invite: InviteDoc, isJoining: Bool) -> some View {
        let accent = invite.previewGroupType.accent

        return VStack(alignment: .leading, spacing: 0) {
            Text("You've been invited to join")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(RT.inkMuted)

            Text(invite.groupName)
                .font(.rtDisplay(30, .bold))
                .foregroundStyle(RT.ink)
                .padding(.top, 4)

            VStack(spacing: 0) {
                detailRow("Group type", typeLabel(invite.previewGroupType), accent: accent)
                if let alarm = invite.localAlarmTime {
                    Divider().overlay(RT.divider)
                    detailRow("Wake-up", RTAlarmTime.display(alarm), accent: accent)
                }
                if let title = invite.eventTitle, !title.isEmpty {
                    Divider().overlay(RT.divider)
                    detailRow("Event", title, accent: accent)
                }
                if let invitedBy = invite.invitedByName, !invitedBy.isEmpty {
                    Divider().overlay(RT.divider)
                    detailRow("Invited by", invitedBy, accent: accent)
                }
                if let createdBy = invite.createdByName, !createdBy.isEmpty {
                    Divider().overlay(RT.divider)
                    detailRow("Group created by", createdBy, accent: accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
            .padding(.top, 22)

            if invite.previewGroupType != .event {
                Text("Joining sets an alarm on this device. You can change or leave it any time.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RT.inkFaint)
                    .lineSpacing(2)
                    .padding(.top, 12)
                    .padding(.horizontal, 4)
            }

            Button {
                Task { await join(invite) }
            } label: {
                Text("Join \(invite.groupName)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(accent))
            }
            .buttonStyle(RTPressStyle())
            .disabled(isJoining)
            .padding(.top, 24)

            Button(action: onFinish) {
                Text("Not now")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(RT.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(14)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func detailRow(_ label: String, _ value: String, accent: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RT.inkMuted)
            Spacer()
            Text(value)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(RT.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }

    private func typeLabel(_ type: RTGroupType) -> String {
        switch type {
        case .accountability: return "Accountability"
        case .shared: return "Shared wake-up"
        case .event: return "Event"
        }
    }

    // MARK: Actions

    private func load() async {
        guard case .loading = phase else { return }
        if let invite = await repository.fetchInvite(code: code) {
            // Already a member — nothing to confirm, so say so rather than
            // letting the join fail on a duplicate.
            if repository.isCurrentUserMember(ofGroupId: invite.groupId) {
                phase = .joined(invite.groupName)
            } else {
                phase = .ready(invite)
            }
        } else {
            phase = .notFound
        }
    }

    private func join(_ invite: InviteDoc) async {
        phase = .joining
        if await repository.joinGroup(inviteCode: code) {
            phase = .joined(invite.groupName)
        } else {
            phase = .failed(repository.lastError ?? "Something went wrong. Try again.")
        }
    }
}
