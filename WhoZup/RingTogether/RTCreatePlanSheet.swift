//
//  RTCreatePlanSheet.swift
//  WhoZup
//
//  The create form for a plan, one layout per kind (picked first in
//  `RTPlanKindSheet`): a one-time plan, a one-time plan with an alarm, or a
//  repeating plan whose alarm is optional. Each carries its headcount asks.
//  "Next · Invite people" creates the plan and opens Add members.
//

import SwiftUI

struct RTCreatePlanSheet: View {
    let kind: RTPlanKind

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var place = ""
    /// One-time plans: the start (date and time). Repeating plans: the time of day.
    @State private var start: Date
    @State private var days: Set<Int> = [3, 5, 7]
    @State private var hasAlarm = true
    @State private var alarmLead: Int
    @State private var flagNotUp = true
    @State private var everyoneIn = true
    @State private var asks: [String: Bool]
    @State private var isWorking = false
    @State private var createdCode: String?
    @State private var showAddMembers = false

    init(kind: RTPlanKind) {
        self.kind = kind
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let hour = kind == .once ? 20 : 6
        _start = State(initialValue: cal.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
        _alarmLead = State(initialValue: kind == .onceAlarm ? 45 : 30)
        _asks = State(initialValue: Dictionary(uniqueKeysWithValues: Self.askOptions(kind).map { ($0.ask.id, $0.on) }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RT.inkMuted)
                    Spacer()
                    RTBadge(text: kind.badge, color: kind.tint, background: kind.tintBackground)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("New \(kind.badge.lowercased())")
                        .font(.rtDisplay(28, .bold))
                        .foregroundStyle(RT.ink)
                    Text(kind.blurb)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }

                field("What's the plan?", "e.g. Saturday catch-up", text: $name)

                whenSection

                field("Where (optional)", "Add a place", text: $place)

                if kind != .once { alarmCard }
                if kind == .repeating { attendanceCard }
                headcountCard

                if kind == .once {
                    VStack(alignment: .leading, spacing: 8) {
                        label("Everyone answers with")
                        HStack(spacing: 8) {
                            chip("Coming", RT.dotOnTime, Color(hex: "#e3f3ec"))
                            chip("Running late +15", Color(hex: "#9a6410"), Color(hex: "#fbeed6"))
                            chip("Can't make it", RT.inkSecondary, RT.cardBorder)
                        }
                    }
                }

                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text("Next · Invite people").font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(RoundedRectangle(cornerRadius: 16).fill(canCreate ? kind.tint : RT.inkFaint))
                }
                .disabled(!canCreate || isWorking)
                .padding(.top, 6)
            }
            .padding(20)
        }
        .background(RT.canvas)
        .sheet(isPresented: $showAddMembers, onDismiss: { dismiss() }) {
            if let code = createdCode {
                RTAddMembersView(code: code, groupName: name, accent: kind.tint)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var whenSection: some View {
        switch kind {
        case .once, .onceAlarm:
            VStack(alignment: .leading, spacing: 8) {
                label(kind == .once ? "When" : "Starts at")
                DatePicker("Starts", selection: $start, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 1))
            }
        case .repeating:
            VStack(alignment: .leading, spacing: 8) {
                label("Every")
                RTWeekdayRow(selected: $days, accent: kind.tint, badgeBackground: kind.tintBackground)
                label("Starts at")
                DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()
                    .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
            }
        }
    }

    private var alarmCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarm").font(.system(size: 16, weight: .bold)).foregroundStyle(RT.ink)
                    Text(kind == .repeating ? "Optional. Rings everyone who is in, before it starts." : "Rings everyone's phone. Stop = I'm up.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color(hex: "#24524b"))
                }
                Spacer()
                if kind == .repeating {
                    Toggle("Alarm", isOn: $hasAlarm.animation()).labelsHidden().tint(Color(hex: "#2f7d72"))
                } else {
                    Text(RTAlarmTime.display(RTAlarmTime.string(from: alarmAt)))
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(Color(hex: "#1f5a50"))
                }
            }
            .padding(16)
            .background(Color(hex: "#e3f1ee"))

            if hasAlarm || kind == .onceAlarm {
                VStack(alignment: .leading, spacing: 10) {
                    let leads = kind == .repeating ? [0, 30, 60] : [15, 30, 45, 60]
                    HStack(spacing: 6) {
                        ForEach(leads, id: \.self) { lead in
                            Button { alarmLead = lead } label: {
                                Text(lead == 0 ? "At start" : lead == 60 ? "1 hr before" : "\(lead) min before")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(alarmLead == lead ? .white : RT.inkSecondary)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(alarmLead == lead ? Color(hex: "#2f7d72") : RT.card))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(RT.cardBorder, lineWidth: alarmLead == lead ? 0 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(kind == .repeating
                         ? "Rings \(RTAlarmTime.display(RTAlarmTime.string(from: alarmAt))) for whoever's in that day. Skip a session and your alarm stays quiet."
                         : "Anyone who says they can't come isn't woken.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                    if kind == .onceAlarm {
                        Divider().overlay(RT.divider)
                        Toggle(isOn: $flagNotUp) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Flag anyone not up by \(RTAlarmTime.display(RTAlarmTime.string(from: alarmAt.addingTimeInterval(15 * 60)))))")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(RT.ink)
                                Text("The group sees who to nudge before you leave.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(RT.inkMuted)
                            }
                        }
                        .tint(Color(hex: "#2f7d72"))
                    }
                }
                .padding(16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "#b9dccd"), lineWidth: 1.5))
    }

    private var attendanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who's coming").font(.system(size: 16, weight: .bold)).foregroundStyle(RT.ink)
            radio(on: everyoneIn, "Everyone's in unless they skip",
                  "For a standing commitment. Members only tap when they can't.") { everyoneIn = true }
            radio(on: !everyoneIn, "Ask everyone each time", "Nobody's counted until they say Coming.") { everyoneIn = false }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RT.cardBorder, lineWidth: 1))
    }

    private var headcountCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .repeating ? "Headcount, every session" : "Headcount")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(RT.ink)
                Text(kind == .repeating ? "The same asks repeat before each session."
                     : kind == .onceAlarm ? "Lock in who's coming before anyone's alarm is set."
                     : "We'll ask for you, so you know how many to plan for.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: "#6b4a1f"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "#fbeed6"))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.askOptions(kind), id: \.ask.id) { option in
                    let on = asks[option.ask.id] ?? false
                    Button {
                        if !option.locked { asks[option.ask.id] = !on }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                .font(.system(size: 22))
                                .foregroundStyle(option.locked ? RT.dotIdle : (on ? Color(hex: "#9a5d1c") : RT.inkFaint))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(RT.ink)
                                Text(option.detail).font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(option.locked)
                }
                if kind == .once {
                    Text("You can also tap Ask now on the plan any time.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "#e9c99b"), lineWidth: 1.5))
    }

    // MARK: Headcount options per kind

    struct AskOption {
        let ask: RTHeadcountAsk
        let title: String
        let detail: String
        let on: Bool
        var locked = false
    }

    static func askOptions(_ kind: RTPlanKind) -> [AskOption] {
        switch kind {
        case .once:
            return [
                AskOption(ask: .init(id: "invite", offsetMinutes: nil, dayBeforeAt: nil, audience: "everyone", question: "Can you make it?"),
                          title: "When they're invited", detail: "Always", on: true, locked: true),
                AskOption(ask: .init(id: "eveningBefore", offsetMinutes: nil, dayBeforeAt: "19:00", audience: "unanswered", question: "Can you make it?"),
                          title: "The evening before", detail: "7:00 PM · only people who haven't answered", on: true),
                AskOption(ask: .init(id: "stillComing", offsetMinutes: -180, dayBeforeAt: nil, audience: "yes", question: "Still coming?"),
                          title: "3 hours before", detail: "\"Still coming?\" to everyone who said yes", on: true),
                AskOption(ask: .init(id: "onTheWay", offsetMinutes: -30, dayBeforeAt: nil, audience: "yes", question: "On your way?"),
                          title: "30 min before", detail: "\"On your way?\" for ETAs", on: false),
            ]
        case .onceAlarm:
            return [
                AskOption(ask: .init(id: "dayBefore", offsetMinutes: nil, dayBeforeAt: "18:00", audience: "everyone", question: "Coming tomorrow?"),
                          title: "The day before, 6:00 PM", detail: "\"Coming tomorrow?\" with the alarm time", on: true),
                AskOption(ask: .init(id: "lastCall", offsetMinutes: nil, dayBeforeAt: "22:00", audience: "unanswered", question: "Last call: coming?"),
                          title: "Bedtime, 10:00 PM", detail: "Last call. After this, the headcount is locked.", on: true),
                AskOption(ask: .init(id: "alarmRings", offsetMinutes: nil, dayBeforeAt: nil, audience: "everyone", question: "Who's up"),
                          title: "When the alarms ring", detail: "Automatic: you see who's up, live", on: true, locked: true),
            ]
        case .repeating:
            return [
                AskOption(ask: .init(id: "nightBefore", offsetMinutes: nil, dayBeforeAt: "21:00", audience: "yes", question: "Still in for tomorrow?"),
                          title: "The night before, 9:00 PM", detail: "\"Still in for tomorrow?\"", on: true),
                AskOption(ask: .init(id: "onTheWay", offsetMinutes: -30, dayBeforeAt: nil, audience: "yes", question: "On your way?"),
                          title: "30 min before start", detail: "\"On your way?\" for ETAs", on: false),
            ]
        }
    }

    // MARK: Helpers

    /// When everyone's alarm rings: the start minus the lead.
    private var alarmAt: Date { start.addingTimeInterval(TimeInterval(-alarmLead * 60)) }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .once: return start > Date()
        case .onceAlarm: return alarmAt > Date()
        case .repeating: return !days.isEmpty
        }
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        let chosen = Self.askOptions(kind).filter { asks[$0.ask.id] ?? false }.map(\.ask)
        let code = await repository.createPlan(
            kind: kind,
            name: name.trimmingCharacters(in: .whitespaces),
            place: place.trimmingCharacters(in: .whitespaces),
            start: start,
            days: days.count == RTWeekday.all.count ? [] : days.sorted(),
            hasAlarm: kind == .onceAlarm || (kind == .repeating && hasAlarm),
            alarmLeadMinutes: alarmLead,
            flagNotUpMinutes: kind == .onceAlarm && flagNotUp ? 15 : nil,
            attendanceDefault: everyoneIn ? "in" : "ask",
            headcountAsks: chosen,
            weeklyLookahead: kind == .repeating
        )
        if let code {
            createdCode = code
            showAddMembers = true
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .bold)).foregroundStyle(RT.inkSecondary)
    }

    private func field(_ title: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            TextField(placeholder, text: text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RT.ink)
                .tint(kind.tint)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(RT.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RT.cardBorder, lineWidth: 1))
        }
    }

    private func chip(_ text: String, _ fg: Color, _ bg: Color) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(bg))
    }

    private func radio(on: Bool, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? kind.tint : RT.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                    Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).stroke(on ? kind.tint : RT.cardBorder, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}
