//
//  RTTheme.swift
//  WhoZup
//
//  Design tokens for the "RingTogether" UI — colors, typography, and shared
//  layout constants extracted from the RingTogether design.
//

import SwiftUI

extension Color {
    /// Hex initializer, e.g. `Color(hex: "#3f6fa3")`.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: Double
        switch s.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// Central palette + type ramp for RingTogether.
enum RT {
    // Surfaces
    static let canvas = Color(hex: "#f6f1e8")
    static let card = Color(hex: "#fffdf8")
    static let cardBorder = Color(hex: "#eee7d9")
    static let cardBorderPressed = Color(hex: "#efe9dd")
    static let divider = Color(hex: "#f2ecdf")

    // Text
    static let ink = Color(hex: "#2c2a26")
    static let inkSecondary = Color(hex: "#6f6a61")
    static let inkMuted = Color(hex: "#8b857a")
    static let inkFaint = Color(hex: "#a39c8e")

    // Status dot colors used on list-card summaries
    static let dotOnTime = Color(hex: "#1f7a5c")
    static let dotSnoozed = Color(hex: "#d98c3a")
    static let dotLate = Color(hex: "#c85f4e")
    static let dotIdle = Color(hex: "#d8d0be")

    // Accent-forward stat color
    static let statGreen = Color(hex: "#1f7a5c")
}

/// Per-group-type accent styling.
enum RTGroupType: String, CaseIterable, Identifiable {
    case accountability, shared, event

    var id: String { rawValue }

    var accent: Color {
        switch self {
        case .accountability: return Color(hex: "#3f6fa3")
        case .shared: return Color(hex: "#4a9e92")
        case .event: return Color(hex: "#d98c3a")
        }
    }

    /// Text color for the small uppercase section eyebrow.
    var eyebrow: Color {
        switch self {
        case .accountability: return Color(hex: "#3f6fa3")
        case .shared: return Color(hex: "#2f7d72")
        case .event: return Color(hex: "#a9702a")
        }
    }

    var badgeBackground: Color {
        switch self {
        case .accountability: return Color(hex: "#e4eef5")
        case .shared: return Color(hex: "#e3f1ee")
        case .event: return Color(hex: "#fbeed6")
        }
    }

    var gradient: LinearGradient {
        let stops: [Color]
        switch self {
        case .accountability: stops = [Color(hex: "#3f6fa3"), Color(hex: "#325a86")]
        case .shared: stops = [Color(hex: "#4a9e92"), Color(hex: "#35867b")]
        case .event: stops = [Color(hex: "#d98c3a"), Color(hex: "#b96f22")]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var eyebrowText: String {
        switch self {
        case .accountability: return "CHECK-INS"
        case .shared: return "IN SYNC"
        case .event: return "EVENTS"
        }
    }

    /// Custom template icon (asset catalog) used consistently across the tab
    /// bar, section headers, and nav bars for this type.
    var iconAsset: String {
        switch self {
        case .accountability: return "tab-accountability"
        case .shared: return "tab-shared"
        case .event: return "tab-events"
        }
    }

    var blurb: String {
        switch self {
        case .accountability: return "Set individual alarms and share your status to build daily habits together."
        case .shared: return "Sync a single alarm for group activities so everyone wakes up and shows up at once."
        case .event: return "Plan one-off hangouts and track RSVPs and real-time attendance in one tap."
        }
    }

    var detailedDescription: String {
        switch self {
        case .accountability:
            return "Set your own alarm for your personal schedule. When it rings, the group sees live status updates (if you're up, snoozed, or still asleep) to keep everyone consistent."
        case .shared:
            return "Create a single alarm that rings on everyone's devices simultaneously. Track who is ready in real-time so you can coordinate morning runs, study groups, or standups instantly."
        case .event:
            return "Coordinate single events or meetups. Members reply with simple status taps (Coming, Late, or Can't make it), and admins can ping non-responders with a single button."
        }
    }

    var listTitle: String {
        switch self {
        case .event: return "Events"
        default: return "Your groups"
        }
    }

    var listSubtitle: String {
        switch self {
        case .accountability: return "Your own alarms, shared accountability."
        case .shared: return "One shared alarm to show up together."
        case .event: return "Quick one-tap RSVPs and event reminders."
        }
    }

    var newGroupLabel: String {
        switch self {
        case .accountability: return "＋  New check-in group"
        case .shared: return "＋  New In Sync group"
        case .event: return "＋  New event group"
        }
    }

    /// Heading for this feature in the "How it works" explainer.
    var helpTitle: String {
        switch self {
        case .accountability: return "Check-ins"
        case .shared: return "In Sync"
        case .event: return "Events"
        }
    }

    /// Casual, plain-language explanation of the feature for the help sheet and
    /// the More tab's "How WhoZup works" section.
    var helpBody: String {
        switch self {
        case .accountability:
            return "Everyone sets their own alarm. When it rings, you dismiss it like any alarm — and the group sees that you're up. Nobody can touch anyone else's alarm; you're only keeping each other honest. Snooze or miss it and the group sees that too. No scores, no shame — just a nudge to actually show up."
        case .shared:
            return "One common alarm for the whole crew. An admin picks a time and everyone's phone rings together. Great for study groups, gym buddies, or a project team. Change the time and it updates for everyone. In different cities? Choose whether it rings at the same moment everywhere, or at that clock time wherever each person is."
        case .event:
            return "A quick “you coming?” for a one-off. Start an event, share the code, and everyone taps Coming, Running late, or Can't make it. Replies show up live, so no one's chasing people in a group chat. Your first 5 events are free — forever."
        }
    }
}

extension Font {
    /// Display face (approximates Bricolage Grotesque with heavy system weights).
    static func rtDisplay(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}
