//
//  RTMorningOfCard.swift
//  WhoZup
//
//  A one-time plan with an alarm, on the day: where things stand (headcount
//  locked, alarms rang, time to the start), how many are up, and who isn't
//  once the flag time has passed, with a Nudge for each.
//

import SwiftUI

struct RTMorningOfCard: View {
    let group: RTGroup
    let session: RTPlanSession
    let alarmAt: Date

    @Environment(GroupRepository.self) private var repository
    @State private var nudged: Set<String> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        // People who said they'd come: they're the ones expected up.
        let expected = group.roster.filter { session.answer(for: $0.uid) != .skipping }
        let up = expected.filter { $0.status == .wokeUp || $0.status == .runningLate }
        let flagAt = group.planFlagNotUpMinutes.map { alarmAt.addingTimeInterval(TimeInterval($0 * 60)) }
        let flagged = (flagAt.map { now >= $0 } ?? false)
            ? expected.filter { !$0.isYou && $0.status != .wokeUp && $0.status != .runningLate } : []

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                stage("CONFIRMED", "\(expected.count) coming", done: true)
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

                ForEach(flagged) { member in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(member.displayName) isn't up")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: "#7c2d20"))
                            Text(member.status == .snoozed ? "Snoozed and hasn't stopped it since." : "No answer since the alarm.")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hex: "#7c2d20"))
                        }
                        Spacer()
                        Button {
                            repository.nudge(groupId: group.id, toUid: member.uid)
                            nudged.insert(member.uid)
                        } label: {
                            Text(nudged.contains(member.uid) ? "Nudged" : "Nudge")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(nudged.contains(member.uid) ? Color(hex: "#7c2d20") : .white)
                                .padding(.horizontal, 16).frame(minHeight: 40)
                                .background(Capsule().fill(nudged.contains(member.uid) ? Color(hex: "#f2cfc7") : Color(hex: "#a83f2e")))
                        }
                        .buttonStyle(.plain)
                        .disabled(nudged.contains(member.uid))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#f7e0da")))
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
        }
    }

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
