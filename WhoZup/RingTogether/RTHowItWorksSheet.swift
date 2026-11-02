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

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private var steps: [RTWalkStep] {
        RTWalkStep.steps(for: type)
    }

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
                        .background(RoundedRectangle(cornerRadius: 16).fill(type.accent))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .background(RT.canvas)
            .navigationTitle("How \(type.helpTitle) works")
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

    static func steps(for type: RTGroupType) -> [RTWalkStep] {
        switch type {
        case .accountability:
            return [
                .init(id: 0, title: "Set your alarm",
                      caption: "Pick an alarm time and repeat days — or set a one-time alarm. This is your personal alarm time.",
                      screenType: .alarm(.accountability)),
                .init(id: 1, title: "Tap “I’m up” when it rings",
                      caption: "It rings locally on your device, even when locked. You can dismiss or snooze — no one else can touch your alarm.",
                      screenType: .ring(.accountability)),
                .init(id: 2, title: "Your group sees it — live",
                      caption: "Woke up, snoozed, or went silent: your status updates for everyone instantly on the shared dashboard.",
                      screenType: .roster(.accountability)),
                .init(id: 3, title: "Build your streak",
                      caption: "Every on-time alarm adds to your streak. See the whole month at a glance in Rise Report.",
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
            Text(type == .accountability ? "Check-in Crew" : "In Sync Crew")
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
            row("YO", RT.ink, "You", .wokeUp, "up at 6:31 AM")
            Divider().overlay(RT.divider)
            row("GA", Color(hex: "#5b8bb5"), "Gaurav", .snoozed, "snoozed")
            Divider().overlay(RT.divider)
            row("SA", Color(hex: "#b57f5b"), "Sam", .waiting, "no update yet")
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
                    RoundedRectangle(cornerRadius: 3)
                        .fill(cells[i]?.chipColor ?? RT.cardBorder.opacity(0.55))
                        .frame(height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(RT.ink, lineWidth: i == cells.count - 1 ? 2 : 0)
                        )
                }
            }

            Text(type == .accountability ? "11 woke · 2 snoozed · 1 late" : "11/14 sessions completed on-time")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RT.inkMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(RT.canvas))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
        .padding(16)
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
