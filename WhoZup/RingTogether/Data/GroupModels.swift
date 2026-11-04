//
//  GroupModels.swift
//  WhoZup
//
//  Codable Firestore documents for groups, their members, statuses, and
//  invite codes. Field names and shapes match firestore.rules exactly.
//

import FirebaseFirestore
import Foundation

/// A group document (`groups/{id}`).
struct FirestoreGroup: Codable, Identifiable {
    @DocumentID var id: String?
    var type: String                    // accountability | shared | event
    var name: String
    var adminUids: [String]
    var memberUids: [String]
    var inviteCode: String
    /// The uid that created the group. Used to attribute the free-event quota to
    /// the host only (participants don't consume quota) and to badge cards as
    /// "Hosting" vs "Guest". Absent on groups created before this field existed.
    var createdBy: String?
    @ServerTimestamp var createdAt: Timestamp?
    var alarmTime: String?              // "6:30" — shared group-level wake-up
    /// IANA identifier of the zone `alarmTime` was picked in (e.g.
    /// "Asia/Kolkata"). A shared wake-up is one instant for everyone, so the
    /// wall-clock string alone is ambiguous — members elsewhere convert it
    /// into their own local time. Absent on groups created before this
    /// existed, which are read as device-local.
    var alarmTimeZone: String?
    /// Raw `RTAlarmAnchor` value; read through `anchor`, which handles absence.
    var alarmAnchor: String?
    /// Days of week the shared alarm rings, as `1=Sunday … 7=Saturday`. Absent
    /// or empty means every day (the backward-compatible default).
    var alarmDays: [Int]?
    /// When true the shared alarm is a *single* alarm: it rings once on the next
    /// occurrence of `alarmTime` and does not repeat (`alarmDays` is ignored).
    /// Only shared groups use this; absent/false means the usual recurring alarm.
    var alarmOnce: Bool?
    var lateThresholdMinutes: Int?
    /// When the shared alarm was last set/changed. Used as the floor for the
    /// missed-alarm check: an alarm set for later today (or after today's slot
    /// already passed) hasn't fired yet, so the group isn't "late" until it does.
    /// Absent on older groups — callers fall back to `createdAt`.
    var alarmSetAt: Timestamp? = nil
    var detailedDescription: String?
    var eventTitle: String?
    var eventPlace: String?
    var eventAt: Timestamp?          // event date & time
    var eventEndAt: Timestamp?       // when the event ends (→ completed after)
    /// Number of admin nudges sent for this event (events only). Written by the
    /// `sendEventReminder` Cloud Function; the client reads it so the "N left"
    /// count is authoritative and survives reload. Absent means 0.
    var reminderCount: Int?

    // Plans (see docs/plans-build.md). All optional: absent on groups made
    // before Plans, which read as their type's old behaviour.
    /// `RTPlanKind` raw value: "once" | "onceAlarm" | "repeat".
    var planKind: String? = nil
    /// When a repeating plan starts, "HH:mm" (its alarm, if any, is earlier).
    var startTime: String? = nil
    /// When a one-time plan with a wake-up starts.
    var meetAt: Timestamp? = nil
    /// The one date a one-time alarm rings on, "yyyy-MM-dd" (device zone at creation).
    var onceDate: String? = nil
    /// How many minutes before the start everyone's alarm rings (0 = at the start).
    var alarmLeadMinutes: Int? = nil
    /// Repeating plans: whether everyone's alarm rings. Absent = true (old In Sync).
    var hasAlarm: Bool? = nil
    /// One-time alarm: flag anyone not up this many minutes after the alarm.
    var flagNotUpMinutes: Int? = nil
    /// Repeating plans: "in" (everyone's in unless they skip) or "ask".
    var attendanceDefault: String? = nil
    /// When the app asks members for a headcount, relative to the start.
    var headcountAsks: [RTHeadcountAsk]? = nil
    /// Repeating plans: send the host a weekly look-ahead.
    var weeklyLookahead: Bool? = nil

    var groupType: RTGroupType {
        RTGroupType(rawValue: type) ?? .accountability
    }

    /// How the shared wake-up should be read across time zones.
    ///
    /// Groups written before the anchor existed fall back to `.localTime`,
    /// because an absolute instant can't be recovered without knowing which
    /// zone the wall clock was originally picked in — and those groups have no
    /// `alarmTimeZone` either. Groups that do carry a zone but predate the
    /// toggle were created under same-moment semantics, so they keep it.
    var anchor: RTAlarmAnchor {
        if let alarmAnchor, let parsed = RTAlarmAnchor(rawValue: alarmAnchor) { return parsed }
        return alarmTimeZone == nil ? .localTime : .sameMoment
    }
}

/// A member metadata document (`groups/{id}/members/{uid}`).
struct GroupMemberDoc: Codable, Identifiable {
    @DocumentID var id: String?         // the member's uid
    var displayName: String
    var initials: String
    var avatarColorHex: String
    var role: String                    // "admin" | "member"
    var alarmTime: String?              // per-member wake-up (accountability)
    /// Days the member's own alarm rings (`1=Sunday … 7=Saturday`); absent or
    /// empty means every day.
    var alarmDays: [Int]?
    /// When this member last set/changed their own alarm. Floor for the
    /// missed-alarm check so a just-set alarm isn't retroactively "late" for an
    /// occurrence that already passed today. Absent on older docs.
    var alarmSetAt: Timestamp? = nil
    /// This member's personal habit in this group, if they built one.
    var habit: MemberHabit? = nil
    /// The member's own alarm rings once instead of repeating (Check-ins).
    var alarmOnce: Bool? = nil
    /// The one-off checklist for a one-time alarm (Check-ins), same shape as a habit.
    var checklist: MemberHabit? = nil
    /// Plans: session dates ("yyyy-MM-dd") this member is skipping. Their alarm
    /// stays quiet and they're never marked late for these.
    var skips: [String]? = nil
}

/// One member's answer for one session of a plan
/// (`groups/{id}/sessions/{yyyy-MM-dd}/responses/{uid}`).
struct SessionAnswerDoc: Codable, Identifiable {
    @DocumentID var id: String?          // the member's uid
    /// "coming" | "running_late" | "skipping"
    var status: String
    var eta: String?
    var respondedAt: Timestamp?
}

/// An append-only activity-feed entry (`groups/{id}/activity/{id}`).
struct GroupActivityDoc: Codable, Identifiable {
    @DocumentID var id: String?
    var kind: String                    // "alarm_changed" | "joined" | ...
    var message: String
    var actorUid: String
    @ServerTimestamp var createdAt: Timestamp?
}

/// A per-member status document (`groups/{id}/statuses/{uid}`).
struct MemberStatusDoc: Codable, Identifiable {
    @DocumentID var id: String?         // the member's uid
    var status: String
    var detail: String
    var eta: String?
    @ServerTimestamp var updatedAt: Timestamp?
    /// True when the app wrote this itself (a skipped alarm marked "no
    /// response"), not the member. A member may still correct an automatic
    /// mark from the app; a real response always replaces the doc and clears it.
    var auto: Bool?
    /// When the member actually answered, stamped by their phone. `updatedAt`
    /// is the server's time, which for an answer made offline is when it
    /// *synced* — possibly hours later, or the next day.
    var respondedAt: Timestamp?
    /// Today's habit routine progress, merged in after an on-time stop.
    var routine: RoutineProgress? = nil

    /// The best known time of this status: the phone's answer time, falling
    /// back to the server time for docs written before `respondedAt` existed.
    var effectiveTime: Date? { (respondedAt ?? updatedAt)?.dateValue() }
}

/// An invite-code document (`invites/{code}`) mapping a code to a group.
///
/// Carries a denormalized preview of the group, because firestore.rules stops a
/// non-member from reading `groups/{id}` — this document is the only thing an
/// invitee can see before they accept. Preview fields are optional so invites
/// written by earlier builds still decode.
struct InviteDoc: Codable {
    var groupId: String
    var groupName: String
    var createdBy: String
    var asAdmin: Bool?

    // Preview payload.
    var groupType: String?              // accountability | shared | event
    var alarmTime: String?              // "6:30"
    var alarmTimeZone: String?          // IANA id the alarmTime was set in
    var alarmAnchor: String?            // RTAlarmAnchor raw value
    var eventTitle: String?
    var eventAt: Timestamp?
    var createdByName: String?
    var invitedByName: String?

    /// The group's type, defaulting to accountability for invites written
    /// before the preview fields existed.
    var previewGroupType: RTGroupType {
        RTGroupType(rawValue: groupType ?? "") ?? .accountability
    }

    /// The wake-up time as it will read on *this* device, so an invitee in
    /// another zone isn't shown a time they'd never actually be woken at.
    /// A local-time group needs no conversion — its wall clock is already what
    /// the invitee's alarm will say.
    var localAlarmTime: String? {
        guard let alarmTime, !alarmTime.isEmpty else { return nil }
        let anchor = alarmAnchor.flatMap(RTAlarmAnchor.init(rawValue:))
            ?? (alarmTimeZone == nil ? .localTime : .sameMoment)
        guard previewGroupType != .accountability, anchor == .sameMoment,
              let zoneID = alarmTimeZone, let zone = TimeZone(identifier: zoneID)
        else { return alarmTime }
        return RTAlarmTime.localTime(of: alarmTime, in: zone)
    }
}

enum RTAvatarPalette {
    /// Deterministic avatar color for a member, from a fixed palette.
    static let hexes = ["#5b8bb5", "#57a99a", "#d98c4a", "#c56b5c", "#8a7bb0", "#7ba05b"]

    static func hex(for uid: String) -> String {
        let idx = abs(uid.hashValue) % hexes.count
        return hexes[idx]
    }
}

/// One scheduled headcount ask on a plan (`groups/{id}.headcountAsks[]`).
struct RTHeadcountAsk: Codable, Hashable, Identifiable {
    /// Stable id, e.g. "eveningBefore".
    var id: String
    /// Minutes relative to the start: negative is before it. Asks tied to a
    /// clock time the day before carry `dayBeforeAt` instead.
    var offsetMinutes: Int?
    /// "HH:mm" on the day before the start, for evening/bedtime asks.
    var dayBeforeAt: String?
    /// "unanswered" | "yes" | "everyone".
    var audience: String
    /// What members see, e.g. "Still coming?".
    var question: String

    var firestoreData: [String: Any] {
        var map: [String: Any] = ["id": id, "audience": audience, "question": question]
        if let offsetMinutes { map["offsetMinutes"] = offsetMinutes }
        if let dayBeforeAt { map["dayBeforeAt"] = dayBeforeAt }
        return map
    }
}
