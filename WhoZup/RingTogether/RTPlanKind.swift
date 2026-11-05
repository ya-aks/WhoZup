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
        case .once: return "Just once"
        case .onceAlarm: return "Once · phones ring"
        case .repeating: return "Every week"
        }
    }

    var badge: String { title }

    /// The create form's heading.
    var formTitle: String {
        switch self {
        case .once, .onceAlarm, .repeating: return "New plan"
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

/// The first step of a new plan: two quick questions instead of picking a
/// type. How often (just once / every week) and whether everyone's phone rings
/// before it starts map onto the three kinds; for a weekly plan the answer to
/// the second question seeds its alarm switch.
struct RTPlanKindSheet: View {
    /// The kind, and whether everyone's phone should ring.
    var onPick: (RTPlanKind, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var weekly: Bool?
    @State private var ring: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RT.inkMuted)
                    Spacer()
                }
                Text("New plan")
                    .font(.rtDisplay(26, .bold))
                    .foregroundStyle(RT.ink)
                    .padding(.top, 8)

                question("1 · HOW OFTEN?", tint: Color(hex: "#9a5d1c"))
                option("Just once", "A dinner, a trip, a study session", symbol: "calendar",
                       tint: Color(hex: "#9a5d1c"), bg: Color(hex: "#fbeed6"), on: weekly == false) { weekly = false }
                option("Every week", "A morning run, a class, a weekly game", symbol: "arrow.triangle.2.circlepath",
                       tint: Color(hex: "#3f6fa3"), bg: Color(hex: "#e4eef5"), on: weekly == true) { weekly = true }

                question("2 · RING EVERYONE'S PHONE BEFORE IT STARTS?", tint: Color(hex: "#2f7d72"))
                    .padding(.top, 8)
                option("Yes, ring everyone", "Nobody misses it, and you see who's ready", symbol: "alarm.fill",
                       tint: Color(hex: "#2f7d72"), bg: Color(hex: "#e3f1ee"), on: ring == true) { ring = true }
                option("No, just RSVPs", "People say if they're coming, running late or can't", symbol: "checkmark",
                       tint: RT.inkMuted, bg: RT.cardBorder, on: ring == false) { ring = false }

                Button {
                    guard let weekly, let ring else { return }
                    let kind: RTPlanKind = weekly ? .repeating : (ring ? .onceAlarm : .once)
                    RTAnalytics.planQuestionsAnswered(weekly: weekly, ring: ring)
                    dismiss()
                    // Let this sheet finish closing before the form opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPick(kind, ring) }
                } label: {
                    Text("Continue")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 16)
                            .fill(weekly != nil && ring != nil ? Color(hex: "#9a5d1c") : RT.inkFaint))
                }
                .buttonStyle(RTPressStyle())
                .disabled(weekly == nil || ring == nil)
                .padding(.top, 10)

                Text("Just waking yourself up? That's an Alarm.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .padding(20)
        }
        .background(RT.canvas)
    }

    private func question(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 13, weight: .heavy)).tracking(0.5).foregroundStyle(tint)
    }

    private func option(_ title: String, _ sub: String, symbol: String, tint: Color, bg: Color,
                        on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 13).fill(bg))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(RT.ink)
                    Text(sub).font(.system(size: 13, weight: .medium)).foregroundStyle(RT.inkMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Circle()
                    .strokeBorder(on ? tint : RT.cardBorder, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().fill(tint).frame(width: 10, height: 10).opacity(on ? 1 : 0))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(on ? tint : RT.cardBorder, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(RTPressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
