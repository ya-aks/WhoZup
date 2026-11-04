//
//  RTHeadcountCard.swift
//  WhoZup
//
//  The host's view of a plan's headcount: how many are coming (a bar that
//  scales to any group size, plus exact counts), when the scheduled asks go,
//  who hasn't answered, and Ask now.
//

import SwiftUI

/// A plan's headcount for one session.
struct RTHeadcount {
    var coming = 0
    var late = 0
    var cant = 0
    var waiting = 0
    var waitingNames: [String] = []

    var invited: Int { coming + late + cant + waiting }
    var yes: Int { coming + late }

    /// From a session's answers (plans with an alarm or repeating).
    init(group: RTGroup, session: RTPlanSession) {
        for member in group.roster {
            switch session.answer(for: member.uid) {
            case .coming: coming += 1
            case .runningLate: late += 1
            case .skipping: cant += 1
            case nil: waiting += 1; waitingNames.append(member.displayName)
            }
        }
    }

    /// From event answers (a one-time plan).
    init(eventRoster roster: [RTMember]) {
        for member in roster {
            switch member.status {
            case .coming: coming += 1
            case .runningLate: late += 1
            case .cantMakeIt: cant += 1
            default: waiting += 1; waitingNames.append(member.displayName)
            }
        }
    }
}

struct RTHeadcountCard: View {
    let groupId: String
    let headcount: RTHeadcount
    let asks: [RTHeadcountAsk]
    let start: Date
    let sessionKey: String
    /// A one-time plan says "Can't"; a session says "Skipping".
    var cantLabel = "Can't"

    @State private var showAskNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(headcount.yes)").font(.rtDisplay(44, .heavy)).foregroundStyle(RT.ink)
                    Text("of \(headcount.invited) coming").font(.system(size: 15, weight: .semibold)).foregroundStyle(RT.inkMuted)
                    Spacer()
                    if headcount.invited > 0 {
                        Text("\(Int((Double(headcount.invited - headcount.waiting) / Double(headcount.invited) * 100).rounded()))% answered")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(RT.inkMuted)
                    }
                }
                bar
                HStack(spacing: 6) {
                    tile(headcount.coming, "Coming", Color(hex: "#1f5a46"), Color(hex: "#e3f3ec"))
                    tile(headcount.late, "Late", Color(hex: "#7a4f0c"), Color(hex: "#fbeed6"))
                    tile(headcount.cant, cantLabel, Color(hex: "#4f4a43"), RT.cardBorder)
                    tile(headcount.waiting, "No answer", Color(hex: "#4f4a43"), RT.canvas)
                }
                Text(advice)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "#1f5a50"))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#e3f1ee")))
                Button { showAskNow = true } label: {
                    Label("Ask now", systemImage: "paperplane.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#9a5d1c")))
                }
                .buttonStyle(RTPressStyle())
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))

            if !scheduled.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headcount asks").font(.system(size: 17, weight: .bold)).foregroundStyle(RT.ink).padding(.bottom, 4)
                    ForEach(scheduled, id: \.ask.id) { item in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(item.sent ? RT.dotOnTime : RT.card)
                                .overlay(Circle().stroke(item.sent ? .clear : Color(hex: "#9a5d1c"), lineWidth: 3))
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.at.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(item.ask.question)")
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                                Text(audienceText(item.ask.audience)).font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
                            }
                            Spacer()
                            Text(item.sent ? "Sent" : "Next").font(.system(size: 12, weight: .bold)).foregroundStyle(RT.inkMuted)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $showAskNow) {
            RTAskNowSheet(groupId: groupId, sessionKey: sessionKey, headcount: headcount)
                .presentationDetents([.large])
        }
    }

    // MARK: Pieces

    /// Four proportional segments: readable at 6 people or 600.
    private var bar: some View {
        GeometryReader { geo in
            let total = max(1, headcount.invited)
            let parts: [(Int, Color)] = [(headcount.coming, RT.dotOnTime), (headcount.late, Color(hex: "#d98c3a")),
                                         (headcount.cant, Color(hex: "#b9b2a5")), (headcount.waiting, Color(hex: "#e6dfd0"))]
            let shown = parts.filter { $0.0 > 0 }
            let spacing = CGFloat(max(0, shown.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(shown.indices, id: \.self) { i in
                    Rectangle().fill(shown[i].1)
                        .frame(width: max(6, (geo.size.width - spacing) * CGFloat(shown[i].0) / CGFloat(total)))
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("\(headcount.coming) coming, \(headcount.late) late, \(headcount.cant) \(cantLabel.lowercased()), \(headcount.waiting) no answer")
    }

    private func tile(_ count: Int, _ label: String, _ fg: Color, _ bg: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.system(size: 20, weight: .heavy))
            Text(label).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(fg)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(bg))
    }

    private var advice: String {
        let maybe = headcount.yes + Int((Double(headcount.waiting) / 2).rounded(.up))
        return headcount.waiting > 0 ? "Plan for \(headcount.yes) · up to \(maybe) if half the rest come" : "Plan for \(headcount.yes)"
    }

    /// Scheduled asks with when they go for this session.
    private var scheduled: [(ask: RTHeadcountAsk, at: Date, sent: Bool)] {
        let cal = Calendar.current
        return asks.compactMap { ask in
            var at: Date?
            if let offset = ask.offsetMinutes { at = start.addingTimeInterval(TimeInterval(offset * 60)) }
            if let dayBefore = ask.dayBeforeAt, let day = cal.date(byAdding: .day, value: -1, to: start) {
                at = GroupRepository.date(day: GroupRepository.dayKey(day), time: dayBefore)
            }
            return at.map { (ask, $0, $0 <= Date()) }
        }
        .sorted { $0.at < $1.at }
    }

    private func audienceText(_ audience: String) -> String {
        switch audience {
        case "unanswered": return "Only people who haven't answered"
        case "yes": return "Everyone who said yes"
        default: return "Everyone"
        }
    }
}

/// "Ask for a headcount": who to ask, what to ask, an optional note.
struct RTAskNowSheet: View {
    let groupId: String
    let sessionKey: String
    let headcount: RTHeadcount

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss
    @State private var audience = "unanswered"
    @State private var question = "Can you make it?"
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask for a headcount").font(.rtDisplay(22, .bold)).foregroundStyle(RT.ink)

            Text("Ask").font(.system(size: 13, weight: .bold)).foregroundStyle(RT.inkMuted)
            option("unanswered", "People who haven't answered", headcount.waiting)
            option("yes", "Everyone who said yes", headcount.yes)
            option("everyone", "Everyone", headcount.invited)

            Text("Question").font(.system(size: 13, weight: .bold)).foregroundStyle(RT.inkMuted)
            HStack(spacing: 8) {
                ForEach(["Can you make it?", "Still coming?", "On your way?"], id: \.self) { q in
                    Button { question = q } label: {
                        Text(q)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(question == q ? .white : RT.ink)
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .background(Capsule().fill(question == q ? Color(hex: "#9a5d1c") : RT.card))
                            .overlay(Capsule().stroke(RT.cardBorder, lineWidth: question == q ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Add a note (optional)", text: $note)
                .padding(.horizontal, 14).frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(RT.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RT.cardBorder, lineWidth: 1))

            Spacer()
            HStack {
                Text("Up to 5 asks per session").font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
                Spacer()
                Button {
                    repository.askNow(groupId: groupId, sessionKey: sessionKey, audience: audience,
                                      question: question, note: note.trimmingCharacters(in: .whitespaces))
                    dismiss()
                } label: {
                    Text("Send to \(count)")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 16).fill(count > 0 ? Color(hex: "#9a5d1c") : RT.inkFaint))
                }
                .disabled(count == 0)
            }
        }
        .padding(20)
        .background(RT.canvas)
    }

    private var count: Int {
        switch audience {
        case "unanswered": return headcount.waiting
        case "yes": return headcount.yes
        default: return headcount.invited
        }
    }

    private func option(_ id: String, _ title: String, _ n: Int) -> some View {
        Button { audience = id } label: {
            HStack(spacing: 10) {
                Image(systemName: audience == id ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20)).foregroundStyle(audience == id ? Color(hex: "#9a5d1c") : RT.inkFaint)
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                Spacer()
                Text("\(n)").font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.inkMuted)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(audience == id ? Color(hex: "#9a5d1c") : RT.cardBorder, lineWidth: audience == id ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}
