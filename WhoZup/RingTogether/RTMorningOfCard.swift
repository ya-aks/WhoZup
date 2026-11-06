//
//  RTMorningOfCard.swift
//  WhoZup
//
//  A one-time plan with an alarm, on the day: where things stand (headcount
//  locked, alarms rang, time to the start), how many are up, and who isn't
//  once the flag time has passed. Only the host can nudge.
//

import SwiftUI

struct RTMorningOfCard: View {
    let group: RTGroup
    let session: RTPlanSession
    let alarmAt: Date

    @Environment(GroupRepository.self) private var repository
    @State private var nudged: Set<String> = []
    @State private var showAllNotUp = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    /// Who is expected up (everyone not skipping), who is up (woke up or running
    /// late), and who gets flagged "Not up": expected, not up, not you, and only
    /// once `flagNotUpMinutes` after the alarm has passed.
    static func state(group: RTGroup, session: RTPlanSession, alarmAt: Date, now: Date)
        -> (expected: [RTMember], up: [RTMember], flagged: [RTMember]) {
        let expected = group.roster.filter { session.answer(for: $0.uid) != .skipping }
        let up = expected.filter { $0.status == .wokeUp || $0.status == .runningLate }
        let flagAt = group.planFlagNotUpMinutes.map { alarmAt.addingTimeInterval(TimeInterval($0 * 60)) }
        let flagged = (flagAt.map { now >= $0 } ?? false)
            ? expected.filter { !$0.isYou && $0.status != .wokeUp && $0.status != .runningLate } : []
        return (expected, up, flagged)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let state = Self.state(group: group, session: session, alarmAt: alarmAt, now: now)
        let expected = state.expected, up = state.up, flagged = state.flagged

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                // Who actually said yes, matching the headcount below; anyone
                // who hasn't answered is still expected up but isn't confirmed.
                let confirmed = group.roster.filter {
                    let a = session.answer(for: $0.uid); return a == .coming || a == .runningLate
                }.count
                stage("CONFIRMED", "\(confirmed) coming", done: true)
                stage(time(alarmAt), now >= alarmAt ? "Alarms rang" : "Alarms ring", done: now >= alarmAt)
                stage(time(session.start), startLabel(now: now), done: false, current: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(up.count)").font(.rtDisplay(40, .heavy)).foregroundStyle(RT.ink)
                    Text("of \(expected.count) are up").font(.system(size: 15, weight: .semibold)).foregroundStyle(RT.inkMuted)
                }
                GeometryReader { geo in
                    let total = CGFloat(max(1, expected.count))
                    HStack(spacing: 2) {
                        if !up.isEmpty {
                            Rectangle().fill(RT.dotOnTime).frame(width: geo.size.width * CGFloat(up.count) / total)
                        }
                        Rectangle().fill(flagged.isEmpty ? Color(hex: "#e6dfd0") : RT.dotLate)
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())

            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))

            if !flagged.isEmpty { notUpSection(flagged) }

            VStack(spacing: 8) {
                summaryRow(up, title: "Up · \(up.count)", trailing: nil)
                let notComing = group.roster.filter { session.answer(for: $0.uid) == .skipping }
                if !notComing.isEmpty {
                    summaryRow(notComing, title: "Not coming · \(notComing.count)", trailing: "No alarm")
                }
            }
        }
    }

    /// Who isn't up, a few at a time. Only the host can nudge; everyone else
    /// sees the same list without the buttons.
    @ViewBuilder private func notUpSection(_ flagged: [RTMember]) -> some View {
        let shown = showAllNotUp ? flagged : Array(flagged.prefix(3))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Not up · \(flagged.count)").font(.system(size: 15, weight: .heavy)).foregroundStyle(flagInk)
                if isHost {
                    Text("Host only").font(.system(size: 11, weight: .bold)).foregroundStyle(flagInk)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: "#f2d3cb")))
                }
            }
            Text(isHost ? "Not answered since the alarm. Nudge sends a loud \"the group is waiting\" alert."
                        : "Not answered since the alarm.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(flagInk)
                .padding(.bottom, 4)
            ForEach(shown) { member in
                HStack(spacing: 10) {
                    RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.displayName).font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                        Text(member.status == .snoozed ? "snoozed, hasn't stopped it" : "no answer since the alarm")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(flagInk)
                    }
                    Spacer()
                    if isHost {
                        let done = nudged.contains(member.uid)
                        Button {
                            repository.nudge(groupId: group.id, toUid: member.uid)
                            nudged.insert(member.uid)
                        } label: {
                            Text(done ? "Nudged" : "Nudge")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(done ? flagInk : flagRed)
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .background(Capsule().fill(done ? Color(hex: "#f2cfc7") : RT.card))
                                .overlay(Capsule().stroke(flagRed, lineWidth: done ? 0 : 1.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(done)
                    }
                }
                .padding(.vertical, 6)
            }
            if flagged.count > 3 {
                Button(showAllNotUp ? "Show fewer" : "Show \(flagged.count - 3) more") { showAllNotUp.toggle() }
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(flagInk)
                    .frame(minHeight: 36)
            }
            if isHost && flagged.count > 1 {
                let left = flagged.filter { !nudged.contains($0.uid) }
                Button {
                    for member in left { repository.nudge(groupId: group.id, toUid: member.uid, all: true) }
                    nudged.formUnion(left.map(\.uid))
                } label: {
                    Text(left.isEmpty ? "Everyone nudged" : "Nudge all \(left.count)")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 14).fill(left.isEmpty ? RT.inkFaint : flagRed))
                }
                .buttonStyle(RTPressStyle())
                .disabled(left.isEmpty)
                .padding(.top, 6)
                Text("Each person can be nudged once every 5 minutes")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(flagInk)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(hex: "#fbeeea")))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "#f2d3cb"), lineWidth: 1))
    }

    /// A collapsed group of people: a few faces, +N, and a count.
    private func summaryRow(_ members: [RTMember], title: String, trailing: String?) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(members.prefix(3)) { member in
                    RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 28, overlap: true)
                }
                if members.count > 3 {
                    Text("+\(members.count - 3)")
                        .font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(hex: "#4f4a43"))
                        .padding(.horizontal, 8).frame(minHeight: 28)
                        .background(Capsule().fill(Color(hex: "#efe8da")))
                        .overlay(Capsule().stroke(RT.card, lineWidth: 2.5))
                }
            }
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 13, weight: .medium)).foregroundStyle(RT.inkMuted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 1))
        .opacity(members.isEmpty ? 0.6 : 1)
    }

    private var isHost: Bool { group.isCurrentUserAdmin || group.adminUids.isEmpty }
    private let flagInk = Color(hex: "#7c2d20")
    private let flagRed = Color(hex: "#a83f2e")
    private func stage(_ top: String, _ bottom: String, done: Bool, current: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(top).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: "#1f5a50"))
            Text(bottom).font(.system(size: 13, weight: .bold)).foregroundStyle(RT.ink)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(done ? Color(hex: "#e3f1ee") : RT.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? Color(hex: "#2f7d72") : .clear, lineWidth: 1.5))
    }

    private func startLabel(now: Date) -> String {
        let minutes = Int(session.start.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "Started" }
        return minutes < 60 ? "Starts in \(minutes)m" : "Starts in \(minutes / 60)h \(minutes % 60)m"
    }

    private func time(_ date: Date) -> String { RTAlarmTime.display(RTAlarmTime.string(from: date)) }
}
