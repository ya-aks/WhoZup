//
//  RTPlanSessionCard.swift
//  WhoZup
//
//  A plan's next session on its group screen: your answer (In / Running late /
//  Skip this one), everyone else's, and the next few sessions, where a tap
//  skips one ahead of time. Skipping keeps your alarm quiet that day.
//

import SwiftUI

struct RTPlanSessionCard: View {
    let group: RTGroup
    let session: RTPlanSession

    @Environment(GroupRepository.self) private var repository

    private var me: RTMember? { group.roster.first { $0.isYou } }
    private var mine: RTSessionAnswer? { me.flatMap { session.answer(for: $0.uid) } }
    private var myEta: String? { me.flatMap { session.replies[$0.uid]?.eta } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEXT SESSION")
                            .font(.system(size: 12, weight: .bold)).tracking(0.5)
                            .foregroundStyle(RT.inkMuted)
                        Text(session.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(RT.ink)
                    }
                    Spacer()
                    Text(RTAlarmTime.display(RTAlarmTime.string(from: session.start)))
                        .font(.rtDisplay(30, .heavy))
                        .foregroundStyle(RT.ink)
                }

                if let alarmAt = session.alarmAt {
                    Text(mine == .skipping
                         ? "Your alarm stays quiet this time. Others still ring at \(time(alarmAt))."
                         : "Alarm rings \(time(alarmAt)) for everyone who's in")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#1f5a50"))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#e3f1ee")))
                }

                Text("You").font(.system(size: 13, weight: .bold)).foregroundStyle(RT.inkMuted)
                HStack(spacing: 6) {
                    answerButton("I'm in", .coming)
                    answerButton("Running late", .runningLate, eta: myEta ?? "+10")
                    answerButton("Skip this one", .skipping)
                }
                if mine == .runningLate {
                    HStack(spacing: 6) {
                        Text("I'll be there").font(.system(size: 13, weight: .medium)).foregroundStyle(RT.inkMuted)
                        ForEach(["+10", "+20", "+30"], id: \.self) { eta in
                            Button { answer(.runningLate, eta: eta) } label: {
                                Text(eta)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(myEta == eta ? .white : Color(hex: "#9a6410"))
                                    .padding(.horizontal, 12).frame(minHeight: 34)
                                    .background(Capsule().fill(myEta == eta ? Color(hex: "#9a6410") : RT.card))
                                    .overlay(Capsule().stroke(RT.cardBorder, lineWidth: myEta == eta ? 0 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("This session").font(.system(size: 17, weight: .bold)).foregroundStyle(RT.ink)
                    Spacer()
                    Text(counts).font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.inkMuted)
                }
                ForEach(group.roster) { member in
                    HStack(spacing: 10) {
                        RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 30)
                        Text(member.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(RT.ink)
                        Spacer()
                        chip(for: member)
                    }
                    .padding(.vertical, 6)
                }
            }

            if session.upcoming.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coming up").font(.system(size: 17, weight: .bold)).foregroundStyle(RT.ink)
                    HStack(spacing: 8) {
                        ForEach(session.upcoming) { upcoming in
                            Button {
                                repository.setSessionAnswer(groupId: group.id, dayKey: upcoming.dayKey,
                                                            answer: upcoming.skipping ? .coming : .skipping)
                            } label: {
                                VStack(spacing: 6) {
                                    Text(upcoming.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                        .font(.system(size: 12, weight: .bold)).foregroundStyle(RT.inkMuted)
                                    Text(upcoming.date.formatted(.dateTime.day()))
                                        .font(.system(size: 18, weight: .heavy)).foregroundStyle(RT.ink)
                                    Text(upcoming.skipping ? "Skip" : "In")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(upcoming.skipping ? RT.inkSecondary : RT.dotOnTime)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().fill(upcoming.skipping ? RT.cardBorder : Color(hex: "#e3f3ec")))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 1))
                            }
                            .buttonStyle(RTPressStyle())
                            .accessibilityLabel("\(upcoming.date.formatted(date: .complete, time: .omitted)): \(upcoming.skipping ? "skipping, tap to rejoin" : "in, tap to skip")")
                        }
                    }
                    Text("Tap a date to skip it ahead of time.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
                }
            }
        }
    }

    // MARK: Pieces

    private func answerButton(_ title: String, _ answer: RTSessionAnswer, eta: String? = nil) -> some View {
        let on = mine == answer
        return Button { self.answer(answer, eta: eta) } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(on ? .white : RT.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color(hex: "#9a5d1c") : RT.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RT.cardBorder, lineWidth: on ? 0 : 1))
        }
        .buttonStyle(RTPressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func answer(_ answer: RTSessionAnswer, eta: String?) {
        repository.setSessionAnswer(groupId: group.id, dayKey: session.dayKey, answer: answer,
                                    eta: answer == .runningLate ? eta : nil)
    }

    @ViewBuilder private func chip(for member: RTMember) -> some View {
        // On the day, a stopped (or missed) alarm says more than the answer.
        let today = session.dayKey == GroupRepository.dayKey()
        if today, session.alarmAt != nil, member.status != .waiting, session.answer(for: member.uid) != .skipping {
            RTStatusChip(status: member.status)
        } else {
            let reply = session.replies[member.uid]
            switch session.answer(for: member.uid) {
            case .coming: label("In", RT.dotOnTime, Color(hex: "#e3f3ec"))
            case .runningLate: label("Late \(reply?.eta ?? "")", Color(hex: "#9a6410"), Color(hex: "#fbeed6"))
            case .skipping: label("Skipping", RT.inkSecondary, RT.cardBorder)
            case nil: label("No answer", RT.inkMuted, RT.canvas)
            }
        }
    }

    private func label(_ text: String, _ fg: Color, _ bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }

    private var counts: String {
        let answers = group.roster.map { session.answer(for: $0.uid) }
        let coming = answers.filter { $0 == .coming || $0 == .runningLate }.count
        let skipping = answers.filter { $0 == .skipping }.count
        let waiting = answers.filter { $0 == nil }.count
        var parts = ["\(coming) coming"]
        if skipping > 0 { parts.append("\(skipping) skipping") }
        if waiting > 0 { parts.append("\(waiting) no answer") }
        return parts.joined(separator: " · ")
    }

    private func time(_ date: Date) -> String { RTAlarmTime.display(RTAlarmTime.string(from: date)) }
}
