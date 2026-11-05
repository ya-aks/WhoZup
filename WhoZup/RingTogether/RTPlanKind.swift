//
//  RTPlanKind.swift
//  WhoZup
//
//  The Plans tab's three kinds of plan, picked before the create form. They map
//  onto the existing storage types (never renamed): a one-time plan is an
//  `event`, a one-time plan with an alarm is a one-time `shared` alarm, a
//  repeating plan is a repeating `shared` group (its alarm optional). The raw
//  value is stored as `groups/{id}.planKind`.
//

import SwiftUI

enum RTPlanKind: String, CaseIterable, Identifiable {
    case once, onceAlarm = "onceAlarm", repeating = "repeat"

    var id: String { rawValue }

    var groupType: RTGroupType { self == .once ? .event : .shared }

    /// Whether the plan repeats; nil when the kind doesn't fix it.
    var repeats: Bool { self == .repeating }

    var title: String {
        switch self {
        case .once: return "Meetup"
        case .onceAlarm: return "On the dot"
        case .repeating: return "Recurring meetup"
        }
    }

    var badge: String { title }

    /// The create form's heading.
    var formTitle: String {
        switch self {
        case .once: return "New meetup"
        case .onceAlarm: return "New on-the-dot plan"
        case .repeating: return "New recurring meetup"
        }
    }

    var tagline: String {
        switch self {
        case .once: return "DINNER · PARTY · MOVIE NIGHT"
        case .onceAlarm: return "STUDY AT 4 · EARLY FLIGHT · MATCH"
        case .repeating: return "MORNING RUN · CLASS · WEEKLY GAME"
        }
    }

    var blurb: String {
        switch self {
        case .once: return "Pick a time and place. Everyone says if they're coming, running late or can't make it."
        case .onceAlarm: return "Everyone's phone rings before it starts, any time of day, so you see who's ready and nobody misses it."
        case .repeating: return "Same days every week. Everyone's in unless they skip, and you can add an alarm."
        }
    }

    var symbol: String {
        switch self {
        case .once: return "person.2.fill"
        case .onceAlarm: return "alarm.fill"
        case .repeating: return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .once: return Color(hex: "#9a5d1c")
        case .onceAlarm: return Color(hex: "#2f7d72")
        case .repeating: return Color(hex: "#3f6fa3")
        }
    }

    var tintBackground: Color {
        switch self {
        case .once: return Color(hex: "#fbeed6")
        case .onceAlarm: return Color(hex: "#e3f1ee")
        case .repeating: return Color(hex: "#e4eef5")
        }
    }
}

/// "What are you planning?" — the first step of a new plan.
struct RTPlanKindSheet: View {
    var onPick: (RTPlanKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RT.inkMuted)
                    Spacer()
                }
                Text("What are you planning?")
                    .font(.rtDisplay(26, .bold))
                    .foregroundStyle(RT.ink)
                    .padding(.top, 8)

                ForEach(RTPlanKind.allCases) { kind in
                    Button {
                        dismiss()
                        // Let this sheet finish closing before the form opens.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPick(kind) }
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(kind.tint)
                                .frame(width: 48, height: 48)
                                .background(RoundedRectangle(cornerRadius: 14).fill(kind.tintBackground))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(RT.ink)
                                Text(kind.tagline)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(kind.tint)
                                Text(kind.blurb)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(RT.inkMuted)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(RTPressStyle())
                }

                Text("Just waking yourself up? That's an Alarm.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
            .padding(20)
        }
        .background(RT.canvas)
    }
}
