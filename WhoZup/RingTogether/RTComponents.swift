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

            RTRoutinePendingPill(group: group)

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

/// An Alarms (Check-ins) group on the Alarms tab: when your alarm rings, your
/// habit or checklist, the group's name and your alarm time, and how the
/// group did today.
struct RTAlarmGroupCard: View {
    let group: RTGroup

    private var me: RTMember? { group.roster.first { $0.isYou } }
    private var plan: MemberHabit? { group.alarmOnce ? me?.checklist : me?.habit }

    private var whenLabel: String {
        if group.alarmOnce {
            guard let fire = group.alarmOnceFireDate else { return "ONCE" }
            return "ONCE · " + fire.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
        }
        return RTWeekday.summary(group.alarmDays).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(whenLabel)
                    .font(.system(size: 11, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(RTGroupType.accountability.eyebrow)
                Spacer()
                if let plan {
                    Text(plan.checklist ? "Checklist · \(plan.steps.count) item\(plan.steps.count == 1 ? "" : "s")" : "Habit · \(plan.name)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RT.dotOnTime)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: "#e3f3ec")))
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(.rtDisplay(19, .bold))
                    .foregroundStyle(RT.ink)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !group.alarm.isEmpty {
                    let parts = group.alarmDisplay.split(separator: " ")
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(parts.first.map(String.init) ?? group.alarmDisplay)
                            .font(.rtDisplay(26, .heavy)).foregroundStyle(RT.ink)
                        if parts.count > 1 {
                            Text(String(parts[1])).font(.system(size: 13, weight: .bold)).foregroundStyle(RT.inkMuted)
                        }
                    }
                }
            }
            RTRoutinePendingPill(group: group)
            Text(statusLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RT.inkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RT.cardBorder, lineWidth: 1))
    }

    /// "3 up · 1 snoozed · 1 no response", or who's in it before anyone's rung.
    private var statusLine: String {
        let up = group.roster.filter { $0.status == .wokeUp || $0.status == .runningLate }.count
        let snoozed = group.roster.filter { $0.status == .snoozed }.count
        let silent = group.roster.filter { $0.status == .silentLate }.count
        var parts: [String] = []
        if up > 0 { parts.append("\(up) up") }
        if snoozed > 0 { parts.append("\(snoozed) snoozed") }
        if silent > 0 { parts.append("\(silent) no response") }
        return parts.isEmpty ? group.memberLabel : parts.joined(separator: " · ")
    }
}

/// "Routine pending · 2 of 3" on a group's list card while your routine there
/// is still open, so there's always a visible reminder that something's left.
struct RTRoutinePendingPill: View {
    let group: RTGroup

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if group.type == .accountability, let pending = pending(now: context.date) {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .bold))
                    Text("Routine pending · \(pending.done) of \(pending.total)")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(RTStatus.snoozed.chipColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(RTStatus.snoozed.chipBackground))
                .padding(.top, 10)
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private func pending(now: Date) -> (done: Int, total: Int)? {
        if let s = RoutineCoordinator.shared.session, s.groupId == group.id, s.isOpen(now: now) {
            return (s.doneCount, s.done.count)
        }
        if let r = group.roster.first(where: { $0.isYou })?.routine, r.isOpen(now: now) {
            return (r.doneCount, r.total)
        }
        return nil
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
