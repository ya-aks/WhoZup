//
//  RTModels.swift
//  WhoZup
//
//  UI view models for the RingTogether screens. These are assembled from live
//  Firestore documents by `GroupRepository`; the views consume only these
//  types, never Firestore types directly.
//

import SwiftUI

/// Weekday helpers for alarm day-of-week selection. Days are numbered
/// `1 = Sunday … 7 = Saturday`, matching `Calendar`'s weekday component (and
/// Java's `Calendar`), so the same integers mean the same day on both clients.
/// An empty day set is treated as "every day".
enum RTWeekday {
    static let all = [1, 2, 3, 4, 5, 6, 7]
    static let weekdays = [2, 3, 4, 5, 6]   // Mon–Fri
    static let weekends = [1, 7]            // Sun, Sat

    static let shortNames = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
    static let letters = [1: "S", 2: "M", 3: "T", 4: "W", 5: "T", 6: "F", 7: "S"]

    static func short(_ day: Int) -> String { shortNames[day] ?? "?" }
    static func letter(_ day: Int) -> String { letters[day] ?? "?" }

    /// "Every day" / "Weekdays" / "Weekends" / "Mon, Wed, Fri". Empty = every day.
    static func summary(_ days: [Int]) -> String {
        let set = Set(days.isEmpty ? all : days)
        if set == Set(all) { return "Every day" }
        if set == Set(weekdays) { return "Weekdays" }
        if set == Set(weekends) { return "Weekends" }
        return all.filter(set.contains).map(short).joined(separator: ", ")
    }
}

/// A member's status within a group or event. Carries its own chip styling to
/// match the design's `meta()` map.
enum RTStatus: String {
    case wokeUp
    case snoozed
    case silentLate
    case waiting
    case coming
    case runningLate
    case cantMakeIt
    case noResponse

    var label: String {
        switch self {
        case .wokeUp: return "Woke up"
        case .snoozed: return "Snoozed"
        case .silentLate: return "Silent · Late"
        case .waiting: return "Waiting"
        case .coming: return "Coming"
        case .runningLate: return "Running late"
        case .cantMakeIt: return "Can't make it"
        case .noResponse: return "No response"
        }
    }

    var chipColor: Color {
        switch self {
        case .wokeUp: return Color(hex: "#1f7a5c")
        case .snoozed, .runningLate: return Color(hex: "#9a6410")
        case .silentLate, .cantMakeIt: return Color(hex: "#a83f2e")
        case .waiting, .noResponse: return Color(hex: "#6f6a61")
        case .coming: return Color(hex: "#1f6a8c")
        }
    }

    /// Colour in the Rise Report timeline, which has three outcome buckets —
    /// woke up, snoozed, late — matching its counters and legend. A late wake-up
    /// counts as late there (red), even though its chip elsewhere reads amber.
    var reportColor: Color {
        self == .runningLate ? RTStatus.silentLate.chipColor : chipColor
    }

    var chipBackground: Color {
        switch self {
        case .wokeUp: return Color(hex: "#e3f3ec")
        case .snoozed, .runningLate: return Color(hex: "#fbeed6")
        case .silentLate, .cantMakeIt: return Color(hex: "#f7e0da")
        case .waiting, .noResponse: return Color(hex: "#eeeae1")
        case .coming: return Color(hex: "#e0eff5")
        }
    }

    /// Snake-case string used to persist this status in Firestore. Must match
    /// the allowed values enforced in firestore.rules.
    var storageKey: String {
        switch self {
        case .wokeUp: return "woke_up"
        case .snoozed: return "snoozed"
        case .silentLate: return "silent_late"
        case .waiting: return "waiting"
        case .coming: return "coming"
        case .runningLate: return "running_late"
        case .cantMakeIt: return "cant_make_it"
        case .noResponse: return "no_response"
        }
    }

    init(storageKey: String) {
        switch storageKey {
        case "woke_up": self = .wokeUp
        case "snoozed": self = .snoozed
        case "silent_late": self = .silentLate
        case "coming": self = .coming
        case "running_late": self = .runningLate
        case "cant_make_it": self = .cantMakeIt
        case "no_response": self = .noResponse
        default: self = .waiting
        }
    }
}

/// One member of a group's roster.
struct RTMember: Identifiable {
    let id = UUID()
    let uid: String
    let name: String
    let initials: String
    let isYou: Bool
    let isAdmin: Bool
    let avatarColor: Color
    let status: RTStatus
    let detail: String
    let alarm: String?
    /// True when this member's own status was recorded locally but hasn't yet
    /// synced to the server (offline write, still in Firestore's pending queue).
    /// Only ever set for your own row — pending writes are inherently local.
    var pendingSync: Bool = false
    /// The member's habit. For other members this is nil when they keep it
    /// private (`showSteps == false`); `hasHabit` still says one exists.
    var habit: MemberHabit? = nil
    var hasHabit: Bool = false
    /// The member's one-time alarm checklist (only when their alarm rings once).
    /// Nil for others who keep it private; `hasChecklist` still says one exists.
    var checklist: MemberHabit? = nil
    var hasChecklist: Bool = false
    /// The member's own alarm rings once (Check-ins).
    var alarmOnce: Bool = false
    /// Plans: session dates ("yyyy-MM-dd") this member is skipping.
    var skips: Set<String> = []
    /// Today's routine, present only once it has started (an on-time stop).
    var routine: RoutineProgress? = nil

    var displayName: String { isYou ? "You" : name }
    var displayAvatarColor: Color { isYou ? RT.ink : avatarColor }
}

/// Today's alarm for a group that has rung without a response from you —
/// offered on the group screens so you can record what actually happened.
struct RTPendingCheckIn: Equatable {
    let groupId: String
    /// Local "HH:mm" the alarm rang at.
    let time: String
    let fireDate: Date
}

/// A summary dot + label shown on list cards ("3 up", "1 snoozed", …).
struct RTSummaryItem: Identifiable {
    let id = UUID()
    let color: Color
    let label: String
}

/// Event-specific payload.
struct RTEventInfo {
    let title: String
    let place: String
    let etas: [String]
    let date: Date?
    /// When the event ends. Past this, the event is treated as completed.
    let endDate: Date?

    /// e.g. "Sat, Jul 5 · 7:00 PM", or empty when no date is set.
    var whenLabel: String {
        guard let date else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()
            .hour().minute())
    }

    /// True once the event's end time has passed.
    var isCompleted: Bool {
        guard let endDate else { return false }
        return endDate < Date()
    }

    /// Short "ends 8:30 PM" / "ended Jul 5" label for the detail screen.
    var endLabel: String {
        guard let endDate else { return "" }
        return endDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// What a shared group's alarm time means when members are in different
/// time zones. Only meaningful for `.shared` groups: an accountability alarm is
/// each member's own, and an event already has an absolute timestamp.
enum RTAlarmAnchor: String, CaseIterable, Identifiable {
    /// Everyone rings at the same instant. 06:30 set in Kolkata rings at 01:00
    /// in London. For groups doing the thing *together*.
    case sameMoment = "moment"
    /// Everyone rings at the same wall-clock time in their own zone — 06:30 is
    /// 06:30 wherever you are. For groups keeping the same routine apart.
    case localTime = "local"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sameMoment: return "Same moment"
        case .localTime: return "Local time"
        }
    }

    var explanation: String {
        switch self {
        case .sameMoment:
            return "Everyone rings at the same instant, converted into their own time zone."
        case .localTime:
            return "Everyone rings at this time in their own time zone."
        }
    }
}

/// A group of any type.
struct RTGroup: Identifiable {
    let id: String
    let type: RTGroupType
    let name: String
    /// Display alarm: your alarm (accountability) or the group alarm (shared),
    /// **already converted to this device's time zone**. Everything downstream
    /// — display, scheduling, deduplication — works in local wall-clock time,
    /// so the conversion happens once, here, at the point the model is built.
    let alarm: String
    let admin: String?         // display name of an admin ("you" if current user)
    let adminUids: [String]
    let isCurrentUserAdmin: Bool
    /// Whether the signed-in user created this group. For events this decides
    /// who the free-event quota is charged to and drives the Hosting/Guest badge.
    let hostedByCurrentUser: Bool
    let event: RTEventInfo?
    let roster: [RTMember]
    /// The zone a shared group's alarm was originally set in, when it differs
    /// from this device's. Non-nil only when there's a difference worth telling
    /// the user about.
    let alarmSourceZone: TimeZone?
    /// The original wall-clock time in `alarmSourceZone`, for the same purpose.
    let alarmSourceTime: String?
    /// How this group's alarm is interpreted across zones.
    let alarmAnchor: RTAlarmAnchor
    /// Days the alarm rings (`1=Sunday … 7=Saturday`). Empty means every day.
    let alarmDays: [Int]
    /// A single (non-recurring) alarm that rings once: the group's for shared,
    /// your own for Check-ins. False for the usual recurring alarm.
    let alarmOnce: Bool
    /// For a single alarm, when it rings (or rang): the first occurrence of the
    /// time after it was set. Nil for a repeating alarm.
    let alarmOnceFireDate: Date?
    /// Set on groups made from the Plans tab.
    var planKind: RTPlanKind? = nil
    /// Repeating plan: when it starts, "HH:mm" (the alarm may ring earlier).
    var planStartTime: String? = nil
    /// One-time plan with an alarm: when it starts.
    var planMeetAt: Date? = nil
    /// Plans with sessions (one-time with an alarm, repeating): the next one.
    var session: RTPlanSession? = nil
    /// Plans: the host's scheduled headcount asks.
    var planAsks: [RTHeadcountAsk] = []
    /// One-time plan with an alarm: flag anyone not up this long after it rings.
    var planFlagNotUpMinutes: Int? = nil
    let detailedDescription: String?
    /// Admin nudges already sent for this event; gates the max-2 reminder cap.
    let reminderCount: Int

    init(
        id: String,
        type: RTGroupType,
        name: String,
        alarm: String,
        admin: String?,
        adminUids: [String],
        isCurrentUserAdmin: Bool,
        hostedByCurrentUser: Bool = false,
        event: RTEventInfo?,
        roster: [RTMember],
        alarmSourceZone: TimeZone? = nil,
        alarmSourceTime: String? = nil,
        alarmAnchor: RTAlarmAnchor = .localTime,
        alarmDays: [Int] = [],
        alarmOnce: Bool = false,
        alarmOnceFireDate: Date? = nil,
        planKind: RTPlanKind? = nil,
        planStartTime: String? = nil,
        planMeetAt: Date? = nil,
        session: RTPlanSession? = nil,
        planAsks: [RTHeadcountAsk] = [],
        planFlagNotUpMinutes: Int? = nil,
        detailedDescription: String? = nil,
        reminderCount: Int = 0
    ) {
        self.reminderCount = reminderCount
        self.alarmOnce = alarmOnce
        self.alarmOnceFireDate = alarmOnceFireDate
        self.planKind = planKind
        self.planStartTime = planStartTime
        self.planMeetAt = planMeetAt
        self.session = session
        self.planAsks = planAsks
        self.planFlagNotUpMinutes = planFlagNotUpMinutes
        self.detailedDescription = detailedDescription
        self.alarmAnchor = alarmAnchor
        self.id = id
        self.type = type
        self.name = name
        self.alarm = alarm
        self.admin = admin
        self.adminUids = adminUids
        self.isCurrentUserAdmin = isCurrentUserAdmin
        self.hostedByCurrentUser = hostedByCurrentUser
        self.event = event
        self.roster = roster
        self.alarmSourceZone = alarmSourceZone
        self.alarmSourceTime = alarmSourceTime
        self.alarmDays = alarmDays.sorted()
    }

    /// A short human summary of when the alarm rings: "Once" for a single alarm,
    /// otherwise "Every day" / "Weekdays" / "Mon, Wed, Fri".
    var alarmDaysLabel: String { alarmOnce ? "Rings once" : RTWeekday.summary(alarmDays) }

    var memberLabel: String { "\(roster.count) member\(roster.count == 1 ? "" : "s")" }

    /// Human-readable alarm time with AM/PM (empty when unset).
    var alarmDisplay: String { alarm.isEmpty ? "" : RTAlarmTime.display(alarm) }

    /// e.g. "6:30 AM IST" — how this alarm reads where it was set, shown only
    /// when that differs from this device's time zone.
    var alarmSourceDisplay: String? {
        guard let zone = alarmSourceZone, let time = alarmSourceTime else { return nil }
        let abbreviation = zone.abbreviation() ?? zone.identifier
        return "\(RTAlarmTime.display(time)) \(abbreviation)"
    }

    /// Whether the current user may view/share the invite code + QR.
    /// Accountability groups are peer-to-peer (anyone can invite); shared and
    /// event groups are admin-managed.
    var canShareInvite: Bool {
        type == .accountability || isCurrentUserAdmin
    }

    /// The current user is the group's *only* admin and there are other members
    /// left behind. Leaving would strand the group with no admin, so this case
    /// is steered to "make someone else an admin, or delete" instead of a plain
    /// leave. (A sole admin who is also the only member just deletes on leave.)
    var isSoleAdminWithOthers: Bool {
        isCurrentUserAdmin && adminUids.count == 1 && roster.count > 1
    }

    /// Members who haven't responded (events) — used to gate the admin nudge.
    /// Excludes the current user: you never nudge yourself, even if you haven't
    /// responded to your own event.
    var nonResponders: [RTMember] {
        roster.filter { $0.status == .noResponse && !$0.isYou }
    }

    var metaLine: String {
        switch type {
        case .accountability:
            return alarm.isEmpty ? "Your own alarm" : "Your alarm · \(alarmDisplay)"
        case .shared:
            return alarm.isEmpty ? "Group alarm" : "Rings \(alarmDisplay) · set by \(admin ?? "admin")"
        case .event:
            guard let event else { return "" }
            let when = event.whenLabel.isEmpty ? event.title : event.whenLabel
            return event.isCompleted ? "✓ Completed · \(when)" : when
        }
    }

    /// The list-card avatar strip (first five members).
    var avatarMembers: [RTMember] { Array(roster.prefix(5)) }

    /// Summary dots for the list card, derived from roster statuses.
    var summary: [RTSummaryItem] {
        switch type {
        case .event:
            let coming = roster.filter { $0.status == .coming }.count
            let late = roster.filter { $0.status == .runningLate }.count
            let out = roster.filter { $0.status == .cantMakeIt }.count
            var items: [RTSummaryItem] = []
            if coming > 0 { items.append(.init(color: Color(hex: "#1f6a8c"), label: "\(coming) coming")) }
            if late > 0 { items.append(.init(color: RT.dotSnoozed, label: "\(late) late")) }
            if out > 0 { items.append(.init(color: RT.dotLate, label: "\(out) can't")) }
            return items
        default:
            let up = roster.filter { $0.status == .wokeUp }.count
            let sn = roster.filter { $0.status == .snoozed }.count
            let la = roster.filter { $0.status == .silentLate }.count
            var items: [RTSummaryItem] = []
            if up > 0 { items.append(.init(color: RT.dotOnTime, label: "\(up) up")) }
            if sn > 0 { items.append(.init(color: RT.dotSnoozed, label: "\(sn) snoozed")) }
            if la > 0 { items.append(.init(color: RT.dotLate, label: "\(la) late")) }
            return items
        }
    }

    var detailAlarmLabel: String {
        type == .accountability ? "Your alarm" : "Group alarm"
    }

    var detailAlarmMeta: String {
        type == .accountability ? "only you set this" : "set by \(admin ?? "admin")"
    }

    var detailFootNote: String {
        type == .accountability
            ? "Silent after 15 min with no dismiss or snooze"
            : "Each phone rings & dismisses on its own device"
    }
}

/// A member's answer for one session of a plan.
enum RTSessionAnswer: String {
    case coming, runningLate = "running_late", skipping

    var label: String {
        switch self {
        case .coming: return "In"
        case .runningLate: return "Running late"
        case .skipping: return "Skipping"
        }
    }
}

/// One member's answer to a session.
struct RTSessionReply: Equatable {
    let answer: RTSessionAnswer
    let eta: String?
}

/// One upcoming session of a plan, with whether you're skipping it.
struct RTUpcomingSession: Equatable, Identifiable {
    let dayKey: String
    let date: Date
    let skipping: Bool
    var id: String { dayKey }
}

/// The next session of a plan, with everyone's answers for it.
struct RTPlanSession: Equatable {
    /// "yyyy-MM-dd"
    let dayKey: String
    /// When it starts (date + start time).
    let start: Date
    /// When everyone's alarm rings for it, if the plan has one.
    let alarmAt: Date?
    /// Everyone's in unless they skip ("in"), versus asking each time.
    let everyoneInByDefault: Bool
    /// Answers by uid. With `everyoneInByDefault`, no answer reads as In.
    let replies: [String: RTSessionReply]
    /// The next few sessions.
    let upcoming: [RTUpcomingSession]

    func answer(for uid: String) -> RTSessionAnswer? {
        replies[uid]?.answer ?? (everyoneInByDefault ? .coming : nil)
    }
}
