//
//  RTComponents.swift
//  WhoZup
//
//  Reusable RingTogether atoms: avatars, status chips, group cards, and the
//  small section eyebrow.
//

import SwiftUI

/// Circular member avatar with initials.
struct RTAvatar: View {
    let initials: String
    let color: Color
    var size: CGFloat = 34
    var overlap: Bool = false

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .overlay(
                Circle().stroke(RT.card, lineWidth: overlap ? 2.5 : 0)
            )
    }
}

/// Overlapping avatar strip for a roster preview.
struct RTAvatarStrip: View {
    let members: [RTMember]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(members) { member in
                RTAvatar(
                    initials: member.initials,
                    color: member.displayAvatarColor,
                    size: 34,
                    overlap: true
                )
            }
        }
    }
}

/// Pill-shaped status chip.
struct RTStatusChip: View {
    let status: RTStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(status.chipColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(status.chipBackground))
            .fixedSize()
    }
}

/// Small uppercase eyebrow with the type's icon glyph.
struct RTEyebrow: View {
    let type: RTGroupType

    var body: some View {
        HStack(spacing: 8) {
            typeIcon
            Text(type.eyebrowText)
                .font(.system(size: 13, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(type.eyebrow)
        }
    }

    private var typeIcon: some View {
        Image(type.iconAsset)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
            .foregroundStyle(type.accent)
    }
}

/// A tappable group card in the list.
struct RTGroupCard: View {
    let group: RTGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(.rtDisplay(19, .bold))
                    .foregroundStyle(RT.ink)
                // Events show who's on the hook for them: the host (whose free
                // quota it used) vs. a guest who was just invited.
                if group.type == .event {
                    Text(group.hostedByCurrentUser ? "Hosting" : "Guest")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(group.hostedByCurrentUser ? RTGroupType.event.eyebrow : RT.inkMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(group.hostedByCurrentUser ? RTGroupType.event.badgeBackground : RT.cardBorder))
                }
                Spacer()
                Text(group.memberLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RT.inkMuted)
            }

            Text(group.metaLine)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RT.inkSecondary)
                .padding(.top, 6)

            RTAvatarStrip(members: group.avatarMembers)
                .padding(.leading, 4)
                .padding(.top, 12)

            if !group.summary.isEmpty {
                HStack(spacing: 14) {
                    ForEach(group.summary) { item in
                        HStack(spacing: 6) {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                            Text(item.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RT.inkSecondary)
                        }
                    }
                }
                .padding(.top, 13)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(RT.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.03), radius: 8, y: 4)
    }
}


/// Asks you what happened to an alarm that rang without a response reaching
/// the app, and records the answer. Re-checks every minute so it appears the
/// moment today's alarm time passes and disappears once answered.
struct RTCheckInCard: View {
    let groupId: String
    let accent: Color
    /// Space above the card, applied only when it shows.
    var topSpacing: CGFloat = 0

    @Environment(GroupRepository.self) private var repository
    @State private var saving = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let pending = repository.pendingCheckIn(groupId: groupId, now: context.date) {
                card(pending).padding(.top, topSpacing)
            }
        }
    }

    private func card(_ pending: RTPendingCheckIn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "alarm")
                    .font(.system(size: 14, weight: .bold))
                Text("Your \(RTAlarmTime.display(pending.time)) alarm")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundStyle(RT.ink)

            Text("We didn't get your response. What happened?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RT.inkMuted)

            HStack(spacing: 10) {
                choice("I woke up", status: .wokeUp, filled: true)
                choice("I snoozed", status: .snoozed, filled: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.45), lineWidth: 1.5))
    }

    private func choice(_ title: String, status: RTStatus, filled: Bool) -> some View {
        Button {
            guard !saving else { return }
            saving = true
            Task {
                await repository.recordManualCheckIn(groupId: groupId, status: status)
                saving = false
            }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(filled ? .white : accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(filled ? accent : accent.opacity(0.12)))
        }
        .buttonStyle(RTPressStyle())
        .disabled(saving)
    }
}
