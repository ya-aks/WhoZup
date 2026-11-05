//
//  RTHowItWorksSheet.swift
//  WhoZup
//
//  The "How it works" explainer, rebuilt as group-specific visual walkthroughs.
//  Instead of generic slides, this presents the workflow of the chosen tab
//  (Accountability, Shared, or Events) with custom mock screens drawn from
//  the app's own styling.
//

import SwiftUI

struct RTHowItWorksSheet: View {
    let type: RTGroupType
    /// The Plans tab's walkthrough (In Sync and Events together).
    var plans = false

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private var steps: [RTWalkStep] {
        plans ? RTWalkStep.planSteps : RTWalkStep.steps(for: type)
    }

    private var accent: Color { plans ? Color(hex: "#9a5d1c") : type.accent }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(steps.indices, id: \.self) { i in
                        RTWalkStepView(step: steps[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < steps.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page < steps.count - 1 ? "Next" : "Got it")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 16).fill(accent))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .background(RT.canvas)
            .navigationTitle(plans ? "How Plans work" : type == .accountability ? "How Alarms work" : "How \(type.helpTitle) works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One walkthrough step: a mock screen plus a heading and caption.
struct RTWalkStep: Identifiable {
    let id: Int
    let title: String
    let caption: String
    let screenType: RTMockScreenType

    /// The Plans tab: one-off and repeating plans, with an optional alarm.
    static let planSteps: [RTWalkStep] = [
        .init(id: 0, title: "Pick how it runs",
              caption: "A meetup, an on-the-dot plan where everyone's phone rings first, or a recurring meetup. Each has its own short form.",
              screenType: .planKinds),
        .init(id: 1, title: "Everyone answers",
              caption: "For each date: In, Running late with an ETA, or Skip. A recurring meetup can count everyone as In unless they skip.",
              screenType: .planAnswer),
        .init(id: 2, title: "Skip ahead, stay quiet",
              caption: "Skip a date and your alarm stays quiet that day. A skip never counts as missed.",
              screenType: .planSkip),
        .init(id: 3, title: "Headcount, asked for you",
              caption: "The host picks when to ask. We ask the right people at those moments, and the host can Ask now any time.",
              screenType: .planHeadcount),
        .init(id: 4, title: "With an alarm: who's up",
              caption: "Everyone's phone rings before it starts. See who's up, and nudge anyone who isn't.",
              screenType: .planMorning),
        .init(id: 5, title: "Who shows up",
              caption: "Rise Report counts the sessions people actually made it to. Skipping ahead never counts against you.",
              screenType: .streak(.shared)),
    ]

    static func steps(for type: RTGroupType) -> [RTWalkStep] {
        switch type {
        case .accountability:
            return [
                .init(id: 0, title: "Set your alarm",
                      caption: "Your own alarm: repeat it on chosen days, or let it ring once. Only you can change it; your group sees how you did.",
                      screenType: .alarm(.accountability)),
                .init(id: 1, title: "Add a habit or a checklist",
                      caption: "Optional. On a repeating alarm, a habit of up to 3 steps (each with a tiny version). On a one-time alarm, a checklist of up to 5 things to get done.",
                      screenType: .habit),
                .init(id: 2, title: "Stop it when it rings",
                      caption: "It rings on your phone, even when locked. A habit opens after an on-time first-ring Stop; a checklist opens after any Stop.",
                      screenType: .ring(.accountability)),
                .init(id: 3, title: "Work through it",
                      caption: "Go in order and tick each one off, right from the lock screen. It closes itself when you're done or your time runs out.",
                      screenType: .routine),
                .init(id: 4, title: "Your group sees it, live",
                      caption: "Woke up, snoozed, or no response, plus how many steps you've done. Step names stay private unless you share them.",
                      screenType: .roster(.accountability)),
                .init(id: 5, title: "Build your streak",
                      caption: "Every on-time alarm adds to your streak. In Rise Report, woke-up days split into your steps, and missed ones show in soft red.",
                      screenType: .streak(.accountability))
            ]
        case .shared:
            return [
                .init(id: 0, title: "One common alarm",
                      caption: "The group admin sets a single common alarm time. Any time change updates for the whole crew instantly.",
                      screenType: .alarm(.shared)),
                .init(id: 1, title: "Everyone's phone rings",
                      caption: "At the scheduled time, everyone's phone rings. Dismiss or snooze on your own device without interrupting others.",
                      screenType: .ring(.shared)),
                .init(id: 2, title: "Live status dashboard",
                      caption: "See in real-time who has dismissed their alarm and who is snoozing or late, keeping the team in sync.",
                      screenType: .roster(.shared)),
                .init(id: 3, title: "Check who's ready",
                      caption: "Woke up, snoozed, or late: see everyone's status on one board so you know when the crew is ready.",
                      screenType: .streak(.shared))
            ]
        case .event:
            return [
                .init(id: 0, title: "Admin posts a plan",
                      caption: "The group admin creates a one-off event (e.g. “leaving for dinner at 7”) to quickly gather everyone's response.",
                      screenType: .eventDetail),
                .init(id: 1, title: "Respond in one tap",
                      caption: "Tap Coming, Running Late (with an ETA), or Can't Make It. You don't even need to open the app to reply.",
                      screenType: .eventRespond),
                .init(id: 2, title: "Live reply dashboard",
                      caption: "Replies show up live instantly so the whole group knows who's in. Non-responders show as 'No response' passively.",
                      screenType: .eventRoster),
                .init(id: 3, title: "Gentle reminders",
                      caption: "Admin can send up to 2 reminder notifications to those who haven't replied yet, avoiding manual chat chases.",
                      screenType: .eventReminder)
            ]
        }
    }
}

enum RTMockScreenType {
    case alarm(RTGroupType)
    case ring(RTGroupType)
    case roster(RTGroupType)
    case streak(RTGroupType)
    case habit
    case routine
    case planKinds
    case planAnswer
    case planSkip
    case planHeadcount
    case planMorning
    case eventDetail
    case eventRespond
    case eventRoster
    case eventReminder
}

private struct RTWalkStepView: View {
    let step: RTWalkStep

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                RTMockScreen(type: step.screenType)
                VStack(spacing: 6) {
                    Text(step.title)
                        .font(.rtDisplay(21, .bold))
                        .foregroundStyle(RT.ink)
                        .multilineTextAlignment(.center)
                    Text(step.caption)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RT.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
            }
            .padding(20)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Mock screens (built from the real RT components)

/// A phone-screen-shaped panel wrapping one mock, in the app's own palette so it
/// looks like a real screen rather than an illustration.
private struct RTMockScreen<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 26).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(RT.cardBorder, lineWidth: 1))
            .padding(.horizontal, 6)
    }
}

extension RTMockScreen where Content == AnyView {
    init(type: RTMockScreenType) {
        switch type {
        case .alarm(let gt):
            self.content = AnyView(RTMockAlarm(type: gt))
        case .ring(let gt):
            self.content = AnyView(RTMockRing(type: gt))
        case .roster(let gt):
            self.content = AnyView(RTMockRoster(type: gt))
        case .streak(let gt):
            self.content = AnyView(RTMockStreak(type: gt))
        case .habit:
            self.content = AnyView(RTMockHabit())
        case .routine:
            self.content = AnyView(RTMockRoutine())
        case .planKinds:
            self.content = AnyView(RTMockPlanKinds())
        case .planAnswer:
            self.content = AnyView(RTMockPlanAnswer())
        case .planSkip:
            self.content = AnyView(RTMockPlanSkip())
        case .planHeadcount:
            self.content = AnyView(RTMockPlanHeadcount())
        case .planMorning:
            self.content = AnyView(RTMockPlanMorning())
        case .eventDetail:
            self.content = AnyView(RTMockEventDetail())
        case .eventRespond:
            self.content = AnyView(RTMockEventRespond())
        case .eventRoster:
            self.content = AnyView(RTMockEventRoster())
        case .eventReminder:
            self.content = AnyView(RTMockEventReminder())
        }
    }
}

/// Alarm time + weekday chips.
private struct RTMockAlarm: View {
    let type: RTGroupType
    private var accent: Color { type.accent }
    private let days = ["S", "M", "T", "W", "T", "F", "S"]
    private let active: Set<Int> = [1, 2, 3, 4, 5]

    var body: some View {
        VStack(spacing: 16) {
            Text(type == .accountability ? "YOUR ALARM TIME" : "GROUP ALARM TIME")
                .font(.system(size: 11, weight: .bold)).tracking(0.5)
                .foregroundStyle(RT.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("6:30").font(.rtDisplay(56, .black)).foregroundStyle(RT.ink)
                Text("AM").font(.rtDisplay(20, .bold)).foregroundStyle(RT.inkMuted)
            }
            HStack(spacing: 7) {
                ForEach(days.indices, id: \.self) { i in
                    Text(days[i])
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(active.contains(i) ? .white : RT.inkMuted)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(active.contains(i) ? accent : RT.cardBorder))
                }
            }
        }
        .padding(20)
    }
}

/// The ringing screen.
private struct RTMockRing: View {
    let type: RTGroupType
    private var accent: Color { type.accent }

    var body: some View {
        VStack(spacing: 14) {
            Text("6:31").font(.rtDisplay(50, .black)).foregroundStyle(RT.ink)
            Text(type == .accountability ? "Morning Crew" : "In Sync Crew")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RT.inkMuted)
            Spacer().frame(height: 8)
            Text("I’m up")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 16).fill(accent))
            Text("Snooze 5 min")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(RT.inkSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
        }
        .padding(20)
    }
}

/// The live roster, using the real avatar + status chip.
private struct RTMockRoster: View {
    let type: RTGroupType

    var body: some View {
        VStack(spacing: 0) {
            row("YO", RT.ink, "You", .wokeUp, "up at 6:31 AM",
                routine: type == .accountability ? [true, true, false] : nil)
            Divider().overlay(RT.divider)
            row("GA", Color(hex: "#5b8bb5"), "Gaurav", .snoozed, "snoozed")
            Divider().overlay(RT.divider)
            row("SA", Color(hex: "#b57f5b"), "Sam", .waiting, "no update yet")
        }
        .padding(16)
    }

    private func row(_ initials: String, _ color: Color, _ name: String, _ status: RTStatus, _ detail: String,
                     routine: [Bool]? = nil) -> some View {
        HStack(spacing: 10) {
            RTAvatar(initials: initials, color: color, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
                if let routine {
                    HStack(spacing: 6) {
                        RTRoutineBar(done: routine).frame(width: 70)
                        Text("Routine \(routine.filter { $0 }.count) of \(routine.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(RT.inkSecondary)
                    }
                }
            }
            Spacer()
            RTStatusChip(status: status)
        }
        .padding(.vertical, 11)
    }
}

/// A Rise Report card with the streak badge + heatmap timeline.
private struct RTMockStreak: View {
    let type: RTGroupType
    // A fortnight of sample outcomes, most recent last (today, outlined).
    private let cells: [RTStatus?] = [.wokeUp, .wokeUp, .snoozed, .wokeUp, .wokeUp, .wokeUp,
                                      .silentLate, .wokeUp, .wokeUp, .wokeUp, .snoozed, .wokeUp, .wokeUp, .wokeUp]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RTAvatar(initials: "YO", color: RT.ink, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("You").font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                    Text("86% on-time").font(.system(size: 11, weight: .semibold)).foregroundStyle(RTStatus.wokeUp.chipColor)
                }
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: type == .accountability ? "flame.fill" : "checkmark.seal.fill").font(.system(size: 11, weight: .bold))
                    Text(type == .accountability ? "5" : "100%").font(.system(size: 13, weight: .heavy))
                }
                .foregroundStyle(type == .accountability ? Color(hex: "#e0742a") : type.accent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(type == .accountability ? Color(hex: "#fbeed6") : type.badgeBackground))
            }

            HStack(spacing: 3) {
                ForEach(cells.indices, id: \.self) { i in
                    cell(i)
                        .frame(height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(RT.ink, lineWidth: i == cells.count - 1 ? 2 : 0)
                        )
                }
            }

            Text(type == .accountability ? "11 woke · 2 snoozed · 1 late · routine 9 of 11" : "11/14 sessions completed on-time")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RT.inkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(RT.canvas))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
        .padding(16)
    }

    /// Check-ins woke days split into routine steps (3 steps, done count varies).
    @ViewBuilder private func cell(_ i: Int) -> some View {
        if type == .accountability, cells[i] == .wokeUp {
            let doneSteps = i % 5 == 2 ? 1 : 3
            VStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { s in
                    Rectangle().fill(s < doneSteps ? RT.dotOnTime : Color(hex: "#e1d9c8"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(cells[i]?.chipColor ?? RT.cardBorder.opacity(0.55))
        }
    }
}

/// Your habit: name, steps with tiny versions, and the finish window.
private struct RTMockHabit: View {
    private let steps: [(String, String?)] = [("Drink water", nil), ("Put on running shoes", "Step outside"),
                                              ("Run 2 km", "Walk to the corner")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("YOUR HABIT")
                    .font(.system(size: 11, weight: .bold)).tracking(0.5)
                    .foregroundStyle(RT.inkMuted)
                Spacer()
                Text("Finish in 30 min")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RTGroupType.accountability.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(RTGroupType.accountability.badgeBackground))
            }
            Text("Morning run").font(.rtDisplay(22, .bold)).foregroundStyle(RT.ink)
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(RTGroupType.accountability.accent))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(steps[i].0).font(.system(size: 14, weight: .semibold)).foregroundStyle(RT.ink)
                        if let tiny = steps[i].1 {
                            Text("Tiny: \(tiny)").font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
                        }
                    }
                }
            }
        }
        .padding(20)
    }
}

/// The routine after Stop: done, tiny, and the next step's two buttons.
private struct RTMockRoutine: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TODAY'S ROUTINE")
                    .font(.system(size: 11, weight: .bold)).tracking(0.5)
                    .foregroundStyle(RT.inkMuted)
                Spacer()
                Text("by 7:01 AM").font(.system(size: 12, weight: .bold)).foregroundStyle(RT.dotSnoozed)
            }
            RTRoutineBar(done: [true, true, false], tinySteps: [false, true, false], height: 8)
            row("Drink water", note: "Done", done: true)
            row("Put on running shoes", note: "Did tiny version", done: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Run 2 km").font(.system(size: 15, weight: .bold)).foregroundStyle(RT.ink)
                HStack(spacing: 8) {
                    Text("Done")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).fill(RT.dotOnTime))
                    Text("Did tiny version")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(RT.dotOnTime)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).stroke(RT.dotOnTime, lineWidth: 1.5))
                }
            }
        }
        .padding(20)
    }

    private func row(_ title: String, note: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RT.dotOnTime)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(RT.inkSecondary)
            Spacer()
            Text(note).font(.system(size: 11, weight: .semibold)).foregroundStyle(RT.inkMuted)
        }
    }
}

/// Event detail card.
private struct RTMockEventDetail: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("EVENT DETAILS")
                .font(.system(size: 11, weight: .bold)).tracking(0.5)
                .foregroundStyle(RTGroupType.event.eyebrow)
            
            VStack(spacing: 4) {
                Text("Gym Session").font(.rtDisplay(24, .bold)).foregroundStyle(RT.ink)
                Text("6:00 PM").font(.rtDisplay(36, .black)).foregroundStyle(RTGroupType.event.accent)
                Text("Created by Sam").font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.inkMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(RT.canvas))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
        }
        .padding(20)
    }
}

/// Response buttons.
private struct RTMockEventRespond: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("YOUR RESPONSE")
                .font(.system(size: 11, weight: .bold)).tracking(0.5)
                .foregroundStyle(RT.inkMuted)
                .padding(.bottom, 4)

            HStack(spacing: 10) {
                Text("Coming")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RTStatus.coming.chipColor))
                
                Text("Late (10m)")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RTStatus.runningLate.chipColor))
                
                Text("Can't Go")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RTStatus.cantMakeIt.chipColor))
            }
        }
        .padding(20)
    }
}

/// Event responses list.
private struct RTMockEventRoster: View {
    var body: some View {
        VStack(spacing: 0) {
            row("YO", RT.ink, "You", .noResponse, "no response yet")
            Divider().overlay(RT.divider)
            row("GA", Color(hex: "#5b8bb5"), "Gaurav", .coming, "Coming")
            Divider().overlay(RT.divider)
            row("SA", Color(hex: "#b57f5b"), "Sam", .runningLate, "10m late")
        }
        .padding(16)
    }

    private func row(_ initials: String, _ color: Color, _ name: String, _ status: RTStatus, _ detail: String) -> some View {
        HStack(spacing: 10) {
            RTAvatar(initials: initials, color: color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
            }
            Spacer()
            RTStatusChip(status: status)
        }
        .padding(.vertical, 8)
    }
}

/// Gentle reminders notification.
private struct RTMockEventReminder: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(RTGroupType.event.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RingTogether").font(.system(size: 10, weight: .bold)).foregroundStyle(RT.inkSecondary)
                    Text("Sam sent a reminder for Gym Session!").font(.system(size: 12, weight: .semibold)).foregroundStyle(RT.ink)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(RT.canvas))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 1))
            .padding(.horizontal, 16)
            
            Text("Send Reminder (1 of 2)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(RTGroupType.event.accent))
        }
        .padding(.vertical, 20)
    }
}

// MARK: - Plans mocks

private let planBrown = Color(hex: "#9a5d1c")

private func mockChip(_ text: String, _ fg: Color, _ bg: Color) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(fg)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(bg))
}

/// The three plan kinds.
private struct RTMockPlanKinds: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(RTPlanKind.allCases) { kind in
                HStack(spacing: 12) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(kind.tint)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 11).fill(kind.tintBackground))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.system(size: 14, weight: .bold)).foregroundStyle(RT.ink)
                        Text(kind.tagline).font(.system(size: 10, weight: .bold)).foregroundStyle(kind.tint)
                    }
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(RT.canvas))
            }
        }
        .padding(18)
    }
}

/// Your answer for a session, and everyone else's.
private struct RTMockPlanAnswer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEXT SESSION · THU 6:00 AM").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(RT.inkMuted)
            HStack(spacing: 6) {
                ForEach(["I'm in", "Running late", "Skip this one"], id: \.self) { label in
                    Text(label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(label == "I'm in" ? .white : RT.ink)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(label == "I'm in" ? planBrown : RT.canvas))
                }
            }
            row("PY", "#5b8bb5", "Priya", mockChip("In", RT.dotOnTime, Color(hex: "#e3f3ec")))
            row("SA", "#b57f5b", "Sam", mockChip("Late +15", Color(hex: "#9a6410"), Color(hex: "#fbeed6")))
            row("GA", "#7b6bb5", "Gaurav", mockChip("Skipping", RT.inkSecondary, RT.cardBorder))
        }
        .padding(18)
    }

    private func row(_ initials: String, _ hex: String, _ name: String, _ chip: some View) -> some View {
        HStack(spacing: 10) {
            RTAvatar(initials: initials, color: Color(hex: hex), size: 28)
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(RT.ink)
            Spacer()
            chip
        }
    }
}

/// The coming-up strip with a skipped date.
private struct RTMockPlanSkip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("COMING UP").font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(RT.inkMuted)
            HStack(spacing: 8) {
                day("THU", "5", skip: false)
                day("SAT", "7", skip: true)
                day("TUE", "10", skip: false)
                day("THU", "12", skip: false)
            }
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill").foregroundStyle(Color(hex: "#2f7d72"))
                Text("Your alarm stays quiet Sat 7.").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: "#24524b"))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#e3f1ee")))
        }
        .padding(18)
    }

    private func day(_ weekday: String, _ date: String, skip: Bool) -> some View {
        VStack(spacing: 5) {
            Text(weekday).font(.system(size: 11, weight: .bold)).foregroundStyle(RT.inkMuted)
            Text(date).font(.system(size: 17, weight: .heavy)).foregroundStyle(RT.ink)
            mockChip(skip ? "Skip" : "In", skip ? RT.inkSecondary : RT.dotOnTime, skip ? RT.cardBorder : Color(hex: "#e3f3ec"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(RT.canvas))
    }
}

/// The host's headcount.
private struct RTMockPlanHeadcount: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("38").font(.rtDisplay(40, .heavy)).foregroundStyle(RT.ink)
                Text("of 60 coming").font(.system(size: 14, weight: .semibold)).foregroundStyle(RT.inkMuted)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(RT.dotOnTime).frame(width: geo.size.width * 0.58)
                    Rectangle().fill(Color(hex: "#d98c3a")).frame(width: geo.size.width * 0.07)
                    Rectangle().fill(Color(hex: "#b9b2a5")).frame(width: geo.size.width * 0.12)
                    Rectangle().fill(Color(hex: "#e6dfd0"))
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            Text("Fri 5:00 PM · Still coming? to everyone who said yes")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(RT.inkMuted)
            Label("Ask now", systemImage: "paperplane.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(RoundedRectangle(cornerRadius: 12).fill(planBrown))
        }
        .padding(18)
    }
}

/// The morning of a plan with an alarm.
private struct RTMockPlanMorning: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("6").font(.rtDisplay(40, .heavy)).foregroundStyle(RT.ink)
                Text("of 7 are up").font(.system(size: 14, weight: .semibold)).foregroundStyle(RT.inkMuted)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(RT.dotOnTime).frame(width: geo.size.width * 0.85)
                    Rectangle().fill(RT.dotLate)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gaurav isn't up").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: "#7c2d20"))
                    Text("No answer since the alarm.").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hex: "#7c2d20"))
                }
                Spacer()
                Text("Nudge")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color(hex: "#a83f2e")))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#f7e0da")))
        }
        .padding(18)
    }
}
