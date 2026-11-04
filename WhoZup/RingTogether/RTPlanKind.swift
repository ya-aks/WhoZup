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
        case .once: return "One-time plan"
        case .onceAlarm: return "One-time plan with an alarm"
        case .repeating: return "Repeating plan"
        }
    }

    var badge: String {
        switch self {
        case .once: return "One-time plan"
        case .onceAlarm: return "One-time + alarm"
        case .repeating: return "Repeating plan"
        }
    }

    var tagline: String {
        switch self {
        case .once: return "ONCE · NO ALARM"
        case .onceAlarm: return "ONCE · EVERYONE'S ALARM RINGS"
        case .repeating: return "REPEATS · ALARM OPTIONAL"
        }
    }

    var blurb: String {
        switch self {
        case .once: return "A set time and place. See who's coming, who's running late and who can't make it."
        case .onceAlarm: return "The same, plus everyone's alarm rings before it starts, so you see who's up."
        case .repeating: return "Happens on set days. Everyone answers for each session, with or without an alarm."
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
