//
//  GroupRepository.swift
//  WhoZup
//
//  Live Firestore-backed store of the signed-in user's groups. Produces the
//  `RTGroup` UI models the RingTogether views already consume, so switching
//  from sample data to live data is a data-source swap, not a view rewrite.
//
//  Responsibilities:
//    - Listen to `groups` where memberUids contains the current uid.
//    - For each group, listen to its members + statuses subcollections and
//      assemble a live `RTGroup` roster.
//    - Create groups (creator becomes admin + first member + writes an invite).
//    - Join a group by invite code.
//    - Write the current user's status (alarm dismiss/snooze, event reply).
//

import FirebaseFirestore
import Foundation
import SwiftUI
import os.log

@MainActor
@Observable
final class GroupRepository {
    /// Live UI groups, rebuilt whenever any underlying document changes.
    private(set) var groups: [RTGroup] = []
    private(set) var isLoading = false
    /// The groups listener has delivered a real answer (from the server, or a
    /// non-empty cache). Until then `groups` is empty only because nothing has
    /// loaded, not because you're in no groups.
    private var groupsLoaded = false

    /// Whether `groups` is complete enough to decide which alarms should exist:
    /// the group list has loaded and every group's member docs (where a
    /// Check-ins member keeps their own alarm time and habit) have arrived.
    /// Alarm reconcile waits for this; reconciling against a half-loaded list
    /// cancels every alarm it can't see yet and deletes the records a Stop needs.
    var alarmDataReady: Bool {
        groupsLoaded && rawGroups.keys.allSatisfy { members[$0] != nil }
    }
    private(set) var lastError: String?

    /// True when one or more of your own status responses were recorded locally
    /// (e.g. dismissing an alarm offline) but haven't synced to the server yet.
    /// Drives the app-wide "syncs pending" banner; clears automatically once
    /// Firestore flushes the queued writes.
    private(set) var hasPendingStatusSyncs = false

    /// Lifetime count of events this user has *created* — the basis for the
    /// free-event quota. Monotonic: deleting an event never refunds it, and
    /// events you merely joined don't count. 0 until the usage doc loads.
    private(set) var eventsCreatedCount = 0
    private(set) var eventPackBalance = 0
    /// True once the user has bought the lifetime "unlimited events" unlock.
    private(set) var eventsLifetime = false

    static let freeEventLimit = 5

    /// Off while we learn from usage: nothing is limited or sold except tips.
    /// The event counter still counts. Flip to bring back the free-event limit,
    /// its banner and the event-pack paywall. See docs/decisions.md.
    static let pricingEnabled = false

    var canCreateEvent: Bool {
        !Self.pricingEnabled || eventsLifetime || eventsCreatedCount < Self.freeEventLimit || eventPackBalance > 0
    }

    /// Events the user can still create — free allowance left plus any purchased
    /// pack balance. `nil` means unlimited (lifetime unlock).
    var eventsRemaining: Int? {
        if eventsLifetime { return nil }
        return max(0, Self.freeEventLimit - eventsCreatedCount) + eventPackBalance
    }

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "GroupRepository")

    private var currentUid: String?
    private var currentDisplayName: String = "You"

    private let db = Firestore.firestore()
    private var groupsListener: ListenerRegistration?
    private var usageListener: ListenerRegistration?
    private var memberListeners: [String: ListenerRegistration] = [:]
    private var statusListeners: [String: ListenerRegistration] = [:]
    /// Plans: one listener per plan on its next session's answers, keyed by group.
    private var sessionListeners: [String: (dayKey: String, listener: ListenerRegistration)] = [:]
    /// Analytics: this device's Ask now count per "groupId|session".
    private var askNowCounts: [String: Int] = [:]
    /// The id of the group most recently created on this device (for analytics).
    private(set) var lastCreatedGroupId: String?
    /// The invite code of the group `createGroup` last made (plans return the
    /// group id, as on Android, and the add-members sheet reads the code here).
    private(set) var lastCreatedInviteCode: String?
    /// Last user properties sent, so they're only sent on change.
    private var lastAnalyticsProps: [Int] = []
    /// Plans: the next session's answers, by group then uid.
    private var sessionReplies: [String: [String: RTSessionReply]] = [:]

    // Usage-doc bookkeeping, for seeding the events-created counter once for
    // users who already hosted events before the counter existed.
    private var usageLoaded = false
    private var usageDocExists = false
    private var seedingUsage = false

    // Raw live data keyed by groupId.
    private var rawGroups: [String: FirestoreGroup] = [:]
    private var members: [String: [GroupMemberDoc]] = [:]
    private var statuses: [String: [MemberStatusDoc]] = [:]
    /// gid → uids whose status doc has an unsynced local write pending. Sourced
    /// from Firestore snapshot metadata (`hasPendingWrites`), which the model
    /// data itself doesn't carry, so it's tracked alongside `statuses`.
    private var pendingStatuses: [String: Set<String>] = [:]

    // Our own member doc for a group we just created, kept until the members
    // listener delivers it. A freshly-created group's members listener can miss
    // the creator's just-written doc for the rest of the session, which would
    // otherwise leave our own alarm blank until an app restart.
    private var pendingOwnMember: [String: GroupMemberDoc] = [:]

    // MARK: - Lifecycle

    /// Begins listening for the given user's groups. Safe to call again with a
    /// new uid (e.g. after re-auth) — it resets first.
    func start(uid: String, displayName: String) {
        if currentUid == uid {
            currentDisplayName = displayName
            members.keys.forEach { healPlaceholderName(groupId: $0) }
            return
        }
        stop()
        currentUid = uid
        currentDisplayName = displayName
        isLoading = true

        groupsListener = db.collection("groups")
            .whereField("memberUids", arrayContains: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleGroupsSnapshot(snapshot, error)
                }
            }

        usageListener = db.collection("usage").document(uid)
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.usageLoaded = true
                    self.usageDocExists = snap?.exists ?? false
                    self.eventsCreatedCount = (snap?.data()?["eventsCreated"] as? Int) ?? 0
                    self.eventPackBalance = (snap?.data()?["eventPackBalance"] as? Int) ?? 0
                    self.eventsLifetime = (snap?.data()?["eventsLifetime"] as? Bool) ?? false
                    self.seedUsageIfNeeded()
                }
            }
    }

    func stop() {
        groupsListener?.remove(); groupsListener = nil
        usageListener?.remove(); usageListener = nil
        memberListeners.values.forEach { $0.remove() }; memberListeners.removeAll()
        statusListeners.values.forEach { $0.remove() }; statusListeners.removeAll()
        sessionListeners.values.forEach { $0.listener.remove() }; sessionListeners.removeAll(); sessionReplies.removeAll()
        rawGroups.removeAll(); members.removeAll(); statuses.removeAll(); pendingStatuses.removeAll(); pendingOwnMember.removeAll()
        groups = []
        eventsCreatedCount = 0
        eventPackBalance = 0
        eventsLifetime = false
        usageLoaded = false; usageDocExists = false; seedingUsage = false
        groupsLoaded = false
        currentUid = nil
    }

    /// One-time backfill: a user who hosted events before the counter existed
    /// has no usage doc, so seed it with their current hosted-event count the
    /// first time we see it's missing. After that it only ever increments.
    private func seedUsageIfNeeded() {
        guard usageLoaded, !usageDocExists, !seedingUsage, let uid = currentUid else { return }
        let hosted = groups.filter { $0.type == .event && $0.planKind == nil && $0.hostedByCurrentUser }.count
        guard hosted > 0 else { return }
        seedingUsage = true
        Task {
            try? await db.collection("usage").document(uid)
                .setData(["eventsCreated": hosted], merge: true)
        }
    }

    // MARK: - Snapshot handling

    private func handleGroupsSnapshot(_ snapshot: QuerySnapshot?, _ error: Error?) {
        isLoading = false
        if let error {
            lastError = error.localizedDescription
            return
        }
        guard let snapshot else { return }
        // An empty answer straight from an empty cache isn't "no groups".
        if !snapshot.metadata.isFromCache || !snapshot.documents.isEmpty { groupsLoaded = true }

        let decoded = snapshot.documents.compactMap { try? $0.data(as: FirestoreGroup.self) }
        let liveIDs = Set(decoded.compactMap(\.id))

        // Drop listeners for groups we're no longer in.
        for goneID in Set(rawGroups.keys).subtracting(liveIDs) {
            memberListeners[goneID]?.remove(); memberListeners[goneID] = nil
            statusListeners[goneID]?.remove(); statusListeners[goneID] = nil
            sessionListeners[goneID]?.listener.remove(); sessionListeners[goneID] = nil; sessionReplies[goneID] = nil
            rawGroups[goneID] = nil; members[goneID] = nil; statuses[goneID] = nil
            pendingStatuses[goneID] = nil
        }

        for group in decoded {
            guard let gid = group.id else { continue }
            rawGroups[gid] = group
            attachSubListeners(groupId: gid)
        }
        rebuild()
    }

    /// Names written before the user had typed theirs (a brand-new user who
    /// created or joined a group in their first session) read "You" to
    /// everyone else. Replace that placeholder on our own member doc once the
    /// real name is known. Only ever touches our own doc, and only a placeholder.
    private func healPlaceholderName(groupId gid: String) {
        guard let uid = currentUid, !Self.placeholderNames.contains(currentDisplayName),
              let mine = members[gid]?.first(where: { $0.id == uid }),
              Self.placeholderNames.contains(mine.displayName) else { return }
        let initials = String(currentDisplayName.prefix(1)).uppercased()
        db.collection("groups").document(gid).collection("members").document(uid)
            .updateData(["displayName": currentDisplayName, "initials": initials.isEmpty ? "?" : initials])
    }

    private static let placeholderNames: Set<String> = ["You", "Member", ""]

    private func attachSubListeners(groupId gid: String) {
        if memberListeners[gid] == nil {
            memberListeners[gid] = db.collection("groups").document(gid).collection("members")
                .addSnapshotListener { [weak self] snap, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.members[gid] = snap?.documents.compactMap { try? $0.data(as: GroupMemberDoc.self) } ?? []
                        // Once the listener has our own doc, drop the optimistic copy.
                        if self.members[gid]?.contains(where: { $0.id == self.currentUid }) == true {
                            self.pendingOwnMember[gid] = nil
                        }
                        self.healPlaceholderName(groupId: gid)
                        self.rebuild()
                    }
                }
        }
        if statusListeners[gid] == nil {
            // includeMetadataChanges so the has-pending-writes → synced flip
            // fires an update and the "Not synced" marker clears on its own once
            // an offline write reaches the server.
            statusListeners[gid] = db.collection("groups").document(gid).collection("statuses")
                .addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.statuses[gid] = snap?.documents.compactMap { try? $0.data(as: MemberStatusDoc.self) } ?? []
                        self.pendingStatuses[gid] = Set(
                            snap?.documents.filter { $0.metadata.hasPendingWrites }.map(\.documentID) ?? []
                        )
                        self.rebuild()
                    }
                }
        }
    }

    /// Plans: keeps one listener on each plan's next-session answers, moving it
    /// along as sessions pass.
    private func attachSessionListener(groupId gid: String, dayKey: String?) {
        if sessionListeners[gid]?.dayKey == dayKey { return }
        sessionListeners[gid]?.listener.remove(); sessionListeners[gid] = nil; sessionReplies[gid] = nil
        guard let dayKey else { return }
        let listener = db.collection("groups").document(gid).collection("sessions").document(dayKey)
            .collection("responses")
            .addSnapshotListener { [weak self] snap, _ in
                Task { @MainActor in
                    guard let self else { return }
                    var replies: [String: RTSessionReply] = [:]
                    for doc in snap?.documents ?? [] {
                        guard let decoded = try? doc.data(as: SessionAnswerDoc.self),
                              let answer = RTSessionAnswer(rawValue: decoded.status) else { continue }
                        replies[doc.documentID] = RTSessionReply(answer: answer, eta: decoded.eta)
                    }
                    self.sessionReplies[gid] = replies
                    self.rebuild()
                }
            }
        sessionListeners[gid] = (dayKey, listener)
    }

    /// Plans with sessions: the next `count` sessions from now (a session stays
    /// "next" until two hours after it starts). Empty for other groups.
    static func planSessions(_ g: FirestoreGroup, count: Int, now: Date = Date()) -> [Date] {
        planSessions(kind: g.planKind.flatMap(RTPlanKind.init(rawValue:)), meetAt: g.meetAt?.dateValue(),
                     startTime: g.startTime, alarmDays: g.alarmDays ?? [],
                     alarmLeadMinutes: g.hasAlarm == false ? 0 : (g.alarmLeadMinutes ?? 0), count: count, now: now)
    }

    static func planSessions(kind: RTPlanKind?, meetAt: Date?, startTime: String?, alarmDays: [Int],
                             alarmLeadMinutes lead: Int, count: Int, now: Date = Date()) -> [Date] {
        let grace: TimeInterval = 2 * 60 * 60
        switch kind {
        case .onceAlarm:
            guard let meet = meetAt, meet.addingTimeInterval(grace) > now else { return [] }
            return [meet]
        case .repeating:
            guard let startTime else { return [] }
            let parts = startTime.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2 else { return [] }
            // Stored days are the alarm's; an alarm that crosses midnight rang
            // the day before the session, so shift back to session days.
            let crosses = parts[0] * 60 + parts[1] - lead < 0
            let days = Set(alarmDays.map { crosses ? ($0 == 7 ? 1 : $0 + 1) : $0 })
            let cal = Calendar.current
            var out: [Date] = []
            for offset in 0..<21 where out.count < count {
                guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                      let start = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) else { continue }
                let weekday = cal.component(.weekday, from: day)
                if (days.isEmpty || days.contains(weekday)) && start.addingTimeInterval(grace) > now { out.append(start) }
            }
            return out
        default:
            return []
        }
    }

    /// Answers the next session of a plan (or any upcoming one by `dayKey`).
    /// Skipping also lands on your member doc, which keeps your alarm quiet
    /// that day and stops the day ever counting as missed.
    func setSessionAnswer(groupId: String, dayKey: String, answer: RTSessionAnswer, eta: String? = nil) {
        guard let uid = currentUid else { return }
        let group = db.collection("groups").document(groupId)
        var data: [String: Any] = [
            "status": answer.rawValue,
            "respondedAt": Timestamp(date: Date()),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        data["eta"] = eta ?? NSNull()
        if let raw = rawGroups[groupId] {
            RTAnalytics.planAnswered(groupId: groupId, kind: Self.analyticsKind(raw),
                                     answer: answer == .coming ? "in" : answer == .runningLate ? "late" : "skip",
                                     ahead: sessionListeners[groupId].map { $0.dayKey != dayKey } ?? false)
        }
        // Queued, not awaited: the tap is the answer; syncing is our job.
        group.collection("sessions").document(dayKey).collection("responses").document(uid)
            .setData(data) { [weak self] error in
                if let error { Task { @MainActor in self?.lastError = error.localizedDescription } }
            }
        group.collection("members").document(uid).setData([
            "skips": answer == .skipping ? FieldValue.arrayUnion([dayKey]) : FieldValue.arrayRemove([dayKey]),
        ], merge: true) { _ in }
    }

    /// Plans: a loud "the group is waiting" push to one member who isn't up
    /// (sent by the `nudgeMember` Cloud Function, at most every 5 minutes).
    func nudge(groupId: String, toUid: String, all: Bool = false) {
        guard let uid = currentUid else { return }
        RTAnalytics.nudgeSent(groupId: groupId, all: all)
        db.collection("groups").document(groupId).collection("nudges").addDocument(data: [
            "byUid": uid, "toUid": toUid, "createdAt": FieldValue.serverTimestamp(),
        ]) { _ in }
    }

    /// Plans: a host's "Ask now". The `headcountAskNow` Cloud Function sends it
    /// to the chosen audience (admins only, at most 5 per session).
    func askNow(groupId: String, sessionKey: String, audience: String, question: String, note: String?) {
        guard let uid = currentUid else { return }
        var data: [String: Any] = [
            "byUid": uid, "manual": true, "sessionKey": sessionKey,
            "audience": audience, "question": question,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let note, !note.isEmpty { data["note"] = note }
        let countKey = "\(groupId)|\(sessionKey)"
        askNowCounts[countKey, default: 0] += 1
        RTAnalytics.askNowSent(groupId: groupId, audience: audience, manualIndex: askNowCounts[countKey] ?? 1)
        db.collection("groups").document(groupId).collection("asks").addDocument(data: data) { [weak self] error in
            if let error { Task { @MainActor in self?.lastError = error.localizedDescription } }
        }
    }

    /// Rebuilds the `RTGroup` list from raw docs + members + statuses.
    private func rebuild() {
        guard let uid = currentUid else { groups = []; hasPendingStatusSyncs = false; return }
        groups = rawGroups.values
            .sorted { ($0.createdAt?.dateValue() ?? .distantPast) < ($1.createdAt?.dateValue() ?? .distantPast) }
            .compactMap { buildRTGroup($0, uid: uid) }
        hasPendingStatusSyncs = pendingStatuses.values.contains { !$0.isEmpty }
        seedUsageIfNeeded()
        let props = [
            groups.filter { $0.type == .accountability }.count,
            groups.filter { $0.planKind != nil && $0.hostedByCurrentUser }.count,
            groups.filter { $0.planKind != nil && !$0.hostedByCurrentUser }.count,
            weeklyPlansHosted,
        ]
        if props != lastAnalyticsProps {
            lastAnalyticsProps = props
            RTAnalytics.updateUserProperties(alarmGroups: props[0], plansHosted: props[1], plansJoined: props[2],
                                             weeklyPlansHosted: props[3])
        }
    }

    private func buildRTGroup(_ g: FirestoreGroup, uid: String) -> RTGroup? {
        guard let gid = g.id else { return nil }
        // Merge the optimistic own-member doc if the listener hasn't delivered
        // ours yet (freshly-created group), so our own alarm shows immediately.
        let loaded = members[gid] ?? []
        let memberDocs = loaded.contains { $0.id == uid } ? loaded
            : loaded + [pendingOwnMember[gid]].compactMap { $0 }
        let statusDocs = statuses[gid] ?? []
        let type = g.groupType

        // Local wall-clock of a shared group's alarm, used by the skipped-alarm
        // check below. Mirrors the display-alarm conversion done further down: a
        // same-moment alarm set in another zone is read in this device's zone.
        let sharedLocalAlarm: String? = {
            guard type == .shared, let a = g.alarmTime, !a.isEmpty else { return nil }
            if g.anchor == .sameMoment, let zoneID = g.alarmTimeZone,
               let zone = TimeZone(identifier: zoneID),
               zone.identifier != TimeZone.current.identifier {
                return RTAlarmTime.localTime(of: a, in: zone)
            }
            return a
        }()

        func memberFor(_ memberUid: String) -> RTMember {
            let doc = memberDocs.first { $0.id == memberUid }
            let statusDoc = statusDocs.first { $0.id == memberUid }
            let isYou = memberUid == uid
            let initials = doc?.initials ?? String((doc?.displayName ?? "?").prefix(1)).uppercased()
            let colorHex = doc?.avatarColorHex ?? RTAvatarPalette.hex(for: memberUid)

            // Judged by when the member answered, not when it reached the
            // server — an offline answer that syncs the next day still counts
            // for the day it was made (and doesn't masquerade as today's).
            let isStatusFromToday: Bool
            if let answeredAt = statusDoc?.effectiveTime {
                isStatusFromToday = Self.dayKey(answeredAt) == Self.dayKey()
            } else {
                isStatusFromToday = (statusDoc != nil)
            }

            var status: RTStatus
            var baseDetail: String
            if type != .event && !isStatusFromToday {
                status = .waiting
                baseDetail = "no update yet"
            } else {
                status = statusDoc.map { RTStatus(storageKey: $0.status) }
                    ?? (type == .event ? .noResponse : .waiting)
                baseDetail = statusDoc?.detail ?? (type == .event ? "hasn't replied" : "no update yet")
            }

            // Skipped-alarm fallback: if today's alarm slot has no response and
            // its deadline has already passed, show the member as silent-late —
            // even when their own device never recorded it (phone off, app never
            // ran). Their device writes the authoritative status when it next
            // reconciles; until then this keeps the roster honest. Recurring
            // accountability/shared alarms only.
            if type != .event, status == .waiting {
                let alarmTime = type == .accountability ? doc?.alarmTime : sharedLocalAlarm
                let alarmDays = (type == .accountability ? doc?.alarmDays : g.alarmDays) ?? []
                let once = type == .shared ? (g.alarmOnce ?? false) : (doc?.alarmOnce ?? false)
                let lateWindow = TimeInterval((g.lateThresholdMinutes ?? 15) * 60)
                // The alarm only counts from when it was set: a member's own
                // `alarmSetAt` (accountability) or the group's (shared), falling
                // back to when the group was created. This keeps a just-created
                // alarm whose time already passed today from showing as missed.
                let notBefore = (type == .accountability ? doc?.alarmSetAt : g.alarmSetAt)?.dateValue()
                    ?? g.createdAt?.dateValue()
                let skippingToday = doc?.skips?.contains(Self.dayKey()) == true
                if let alarmTime, !alarmTime.isEmpty, !once, !skippingToday,
                   MissedAlarm.isTodayMissed(time: alarmTime, days: alarmDays,
                                             lateWindow: lateWindow, notBefore: notBefore) {
                    status = .silentLate
                    baseDetail = "no response"
                }
            }
            // For accountability, prepend the member's own alarm time.
            let detail: String
            if type == .accountability, let a = doc?.alarmTime, !a.isEmpty {
                detail = "\(RTAlarmTime.display(a)) · \(baseDetail)"
            } else {
                detail = baseDetail
            }
            return RTMember(
                uid: memberUid,
                name: doc?.displayName ?? "Member",
                initials: initials,
                isYou: isYou,
                isAdmin: g.adminUids.contains(memberUid),
                avatarColor: Color(hex: colorHex),
                status: status,
                detail: detail,
                alarm: doc?.alarmTime,
                pendingSync: isYou && (pendingStatuses[gid]?.contains(memberUid) ?? false),
                habit: (isYou || doc?.habit?.showSteps == true) ? doc?.habit : nil,
                hasHabit: type == .accountability && doc?.habit != nil,
                checklist: (isYou || doc?.checklist?.showSteps == true) ? doc?.checklist?.asChecklist : nil,
                hasChecklist: type == .accountability && doc?.alarmOnce == true && doc?.checklist != nil,
                alarmOnce: type == .accountability && doc?.alarmOnce == true,
                skips: Set(doc?.skips ?? []),
                // Only today's routine, and only while today's status stands.
                routine: (isStatusFromToday && statusDoc?.routine?.day == Self.dayKey())
                    ? statusDoc?.routine : nil
            )
        }

        // "You" first, then the rest in stable order.
        let ordered = [uid] + g.memberUids.filter { $0 != uid }
        let roster = ordered.map(memberFor)

        let event = (type == .event)
            ? RTEventInfo(
                title: g.eventTitle ?? "",
                place: g.eventPlace ?? "",
                etas: ["+15", "+30", "+45"],
                date: g.eventAt?.dateValue(),
                endDate: g.eventEndAt?.dateValue()
            )
            : nil

        // Display alarm: your own alarm for accountability, the group alarm for
        // shared. An accountability alarm is the member's own, picked on their
        // own device, so it needs no conversion. A shared alarm is one instant
        // agreed by the group, so it's converted from the zone it was set in
        // into this device's.
        let myAlarm = memberDocs.first { $0.id == uid }?.alarmTime
        var displayAlarm = (type == .accountability ? myAlarm : g.alarmTime) ?? ""
        var sourceZone: TimeZone?
        var sourceTime: String?

        // Only a same-moment group converts. A local-time group means "06:30
        // wherever you are", so the stored wall clock is already correct here
        // and there's no source zone worth surfacing.
        if type != .accountability, !displayAlarm.isEmpty, g.anchor == .sameMoment,
           let zoneID = g.alarmTimeZone, let zone = TimeZone(identifier: zoneID),
           zone.identifier != TimeZone.current.identifier {
            sourceZone = zone
            sourceTime = displayAlarm
            displayAlarm = RTAlarmTime.localTime(of: displayAlarm, in: zone)
        }

        // Host = the recorded creator; for legacy groups without `createdBy`,
        // fall back to "is an admin" as the best available signal.
        let hosted = g.createdBy.map { $0 == uid } ?? g.adminUids.contains(uid)

        // Days the alarm rings: the member's own for accountability, the group's
        // for shared. Empty means every day.
        let myDoc = memberDocs.first { $0.id == uid }
        let days = (type == .accountability ? myDoc?.alarmDays : g.alarmDays) ?? []

        // A single alarm (the group's for shared, your own for Check-ins) rings
        // at the first occurrence of its time after it was set — and only then.
        // An unsynced `alarmSetAt` reads as nil locally: it was set just now.
        let once = type == .shared ? (g.alarmOnce ?? false)
            : (type == .accountability && myDoc?.alarmOnce == true)
        let onceSetAt = (type == .accountability ? myDoc?.alarmSetAt : g.alarmSetAt)?.dateValue() ?? Date()
        // A plan's one-time alarm rings on its chosen date, not "the next 06:30" —
        // unless an older build re-set the alarm since (its `alarmSetAt` is then
        // past that date's anchor), when the next occurrence is what's meant.
        let onceFire: Date? = {
            guard once, !displayAlarm.isEmpty else { return nil }
            if let day = g.onceDate, let date = Self.date(day: day, time: displayAlarm), onceSetAt < date { return date }
            return Self.firstOccurrence(of: displayAlarm, after: onceSetAt)
        }()

        // Plans: the next session and everyone's answers for it.
        let sessionDates = Self.planSessions(g, count: 4)
        let mySkips = Set(myDoc?.skips ?? [])
        let session: RTPlanSession? = sessionDates.first.map { next in
            let lead = g.hasAlarm == false ? nil : g.alarmLeadMinutes
            return RTPlanSession(
                dayKey: Self.dayKey(next),
                start: next,
                alarmAt: lead.map { next.addingTimeInterval(TimeInterval(-$0 * 60)) },
                everyoneInByDefault: g.planKind == RTPlanKind.repeating.rawValue ? g.attendanceDefault != "ask" : false,
                replies: sessionReplies[gid] ?? [:],
                upcoming: sessionDates.map { RTUpcomingSession(dayKey: Self.dayKey($0), date: $0, skipping: mySkips.contains(Self.dayKey($0))) }
            )
        }
        attachSessionListener(groupId: gid, dayKey: session?.dayKey)

        return RTGroup(
            id: gid,
            type: type,
            name: g.name,
            alarm: displayAlarm,
            admin: adminName(for: g, memberDocs: memberDocs, uid: uid),
            adminUids: g.adminUids,
            isCurrentUserAdmin: g.adminUids.contains(uid),
            hostedByCurrentUser: hosted,
            event: event,
            roster: roster,
            alarmSourceZone: sourceZone,
            alarmSourceTime: sourceTime,
            alarmAnchor: g.anchor,
            alarmDays: days,
            alarmOnce: once,
            alarmOnceFireDate: onceFire,
            planKind: type == .accountability ? nil : g.planKind.flatMap(RTPlanKind.init(rawValue:)),
            planStartTime: g.startTime,
            planMeetAt: g.meetAt?.dateValue(),
            session: session,
            planAsks: g.headcountAsks ?? [],
            planFlagNotUpMinutes: g.flagNotUpMinutes,
            detailedDescription: g.detailedDescription,
            reminderCount: g.reminderCount ?? 0
        )
    }

    private func adminName(for g: FirestoreGroup, memberDocs: [GroupMemberDoc], uid: String) -> String {
        if g.adminUids.contains(uid) { return "you" }
        if let first = g.adminUids.first {
            return memberDocs.first { $0.id == first }?.displayName ?? "admin"
        }
        return "admin"
    }

    /// Recomputes the UI models after the device's time zone changes.
    ///
    /// A shared group's alarm is stored as wall-clock plus the zone it was set
    /// in, and converted to local time when the model is built — so travelling
    /// across zones has to rebuild, or the displayed time and the scheduled
    /// alarm would both still be anchored to the old zone.
    func refreshForTimeZoneChange() {
        rebuild()
    }

    /// The current user's own alarm time for a group (member alarm for
    /// accountability, group alarm for shared), if set.
    func myAlarmTime(groupId: String) -> String? {
        guard let uid = currentUid, let g = rawGroups[groupId] else { return nil }
        if g.groupType == .accountability {
            return members[groupId]?.first { $0.id == uid }?.alarmTime
        }
        return g.alarmTime
    }

    // MARK: - Mutations

    /// Creates a group; the creator becomes admin and the first member, and an
    /// invite doc is written so others can join by code.
    @discardableResult
    func createGroup(
        type: RTGroupType,
        name: String,
        alarmTime: String? = nil,
        alarmAnchor: RTAlarmAnchor = .localTime,
        alarmDays: [Int] = [],
        alarmOnce: Bool = false,
        eventTitle: String? = nil,
        eventPlace: String? = nil,
        eventAt: Date? = nil,
        eventEndAt: Date? = nil,
        detailedDescription: String? = nil,
        habit: MemberHabit? = nil,
        checklist: MemberHabit? = nil,
        planFields: [String: Any] = [:]
    ) async -> String? {
        guard let uid = currentUid else { return nil }
        // Plans skip the free-event limit for now (pricing is being reworked).
        if type == .event && planFields.isEmpty && !canCreateEvent {
            lastError = "Free event limit reached (5/5). Please purchase an Event Pack (+20 events for $10) to create more events."
            return nil
        }
        let code = Self.makeInviteCode()
        let groupRef = db.collection("groups").document()
        lastCreatedGroupId = groupRef.documentID
        lastCreatedInviteCode = code

        var payload: [String: Any] = [
            "type": type.rawValue,
            "name": name,
            "adminUids": [uid],
            "memberUids": [uid],
            "inviteCode": code,
            "createdBy": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let detailedDescription, !detailedDescription.isEmpty {
            payload["detailedDescription"] = detailedDescription
        }
        // For shared groups the alarm lives on the group; for accountability the
        // creator's own alarm lives on their member doc (written below).
        if type == .shared, let alarmTime {
            payload["alarmTime"] = alarmTime
            payload["alarmTimeZone"] = TimeZone.current.identifier
            payload["alarmAnchor"] = alarmAnchor.rawValue
            payload["alarmOnce"] = alarmOnce
            payload["alarmSetAt"] = FieldValue.serverTimestamp()
            if !alarmDays.isEmpty { payload["alarmDays"] = alarmDays.sorted() }
        }
        if let eventTitle { payload["eventTitle"] = eventTitle }
        if let eventPlace { payload["eventPlace"] = eventPlace }
        if let eventAt { payload["eventAt"] = Timestamp(date: eventAt) }
        if let eventEndAt { payload["eventEndAt"] = Timestamp(date: eventEndAt) }
        if type != .event { payload["lateThresholdMinutes"] = 15 }
        payload.merge(planFields) { _, new in new }

        do {
            try await groupRef.setData(payload)
            let ownAlarm = type == .accountability ? alarmTime : nil
            let ownOnce = type == .accountability && alarmOnce
            let ownDays = type == .accountability && !ownOnce ? alarmDays : []
            try await writeMyMemberDoc(
                groupId: groupRef.documentID, uid: uid, role: "admin",
                alarmTime: ownAlarm, alarmDays: ownDays, alarmOnce: ownOnce
            )
            // The creator's personal habit (repeating alarm) or one-off checklist
            // (single alarm), if they built one — Check-ins only.
            let ownHabit = type == .accountability && !ownOnce ? habit : nil
            let ownChecklist = ownOnce ? checklist : nil
            if let ownHabit {
                try await groupRef.collection("members").document(uid)
                    .setData(["habit": ownHabit.firestoreData], merge: true)
            }
            if let ownChecklist {
                try await groupRef.collection("members").document(uid)
                    .setData(["checklist": ownChecklist.firestoreData], merge: true)
            }
            // Show our own alarm immediately; the members listener for a
            // just-created group can otherwise miss our doc until a restart.
            let initials = String(currentDisplayName.prefix(1)).uppercased()
            pendingOwnMember[groupRef.documentID] = GroupMemberDoc(
                id: uid,
                displayName: currentDisplayName,
                initials: initials.isEmpty ? "?" : initials,
                avatarColorHex: RTAvatarPalette.hex(for: uid),
                role: "admin",
                alarmTime: ownAlarm,
                alarmDays: ownDays.isEmpty ? nil : ownDays.sorted(),
                habit: ownHabit,
                alarmOnce: ownOnce ? true : nil,
                checklist: ownChecklist
            )
            rebuild()
            // The invite doubles as the invitee's only readable preview of the
            // group, so it carries a denormalized copy of the display fields.
            var invitePayload: [String: Any] = [
                "groupId": groupRef.documentID,
                "groupName": name,
                "createdBy": uid,
                "groupType": type.rawValue,
                "createdByName": String(currentDisplayName.prefix(50)),
                "invitedByName": String(currentDisplayName.prefix(50)),
            ]
            if let alarmTime {
                invitePayload["alarmTime"] = alarmTime
                invitePayload["alarmTimeZone"] = TimeZone.current.identifier
            }
            if let eventTitle { invitePayload["eventTitle"] = eventTitle }
            if let eventAt { invitePayload["eventAt"] = Timestamp(date: eventAt) }
            try await db.collection("invites").document(code).setData(invitePayload)
            // Creating an event consumes one of the free-event quota. Monotonic:
            // a later delete never gives it back, so the count can be trusted for
            // billing once the free 5 are used up.
            // A one-time plan is stored as an event but isn't one of the paid
            // events; it adds 0, which still creates the usage doc so older
            // builds don't seed the counter from hosted events (plans included).
            if type == .event {
                try? await db.collection("usage").document(uid)
                    .setData(["eventsCreated": FieldValue.increment(Int64(planFields.isEmpty ? 1 : 0))], merge: true)
            }
            return code
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Joins a group by invite code: resolves the code, appends the current uid
    /// to memberUids, and writes the member metadata doc. For an accountability
    /// group the joiner inherits the group's shared time (if any) so their alarm
    /// is set right away.
    ///
    /// Deliberately never reads `groups/{id}` — rules deny that to a non-member,
    /// so everything needed to join comes off the invite document. The join is
    /// two writes and cannot be made atomic (rules evaluate a batch against
    /// pre-batch state, so the member-doc write can't see the membership the
    /// same batch grants), so instead it is made *idempotent*: a second attempt
    /// after a partial failure completes the missing half rather than erroring.
    @discardableResult
    func joinGroup(inviteCode: String) async -> Bool {
        guard let uid = currentUid else { return false }
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        do {
            let inviteSnap = try await db.collection("invites").document(code).getDocument()
            guard let invite = try? inviteSnap.data(as: InviteDoc.self) else {
                lastError = "That invite code doesn't match a group."
                return false
            }

            do {
                try await db.collection("groups").document(invite.groupId).updateData([
                    "memberUids": FieldValue.arrayUnion([uid])
                ])
            } catch {
                // `isSelfJoinUpdate` rejects a uid that is already in memberUids,
                // so this failure is expected when a previous attempt got this
                // far and only the member doc is missing. Confirm that's the
                // case and carry on; otherwise the error is real.
                guard await isMember(groupId: invite.groupId, uid: uid) else { throw error }
            }

            let defaultAlarm = invite.previewGroupType == .accountability ? invite.alarmTime : nil
            try await writeMyMemberDoc(groupId: invite.groupId, uid: uid, role: "member", alarmTime: defaultAlarm)
            await writeActivity(groupId: invite.groupId, kind: "joined", message: "\(currentDisplayName) joined the group")
            // Group size for analytics: one read, best-effort.
            if let snap = try? await db.collection("groups").document(invite.groupId).getDocument(),
               let raw = try? snap.data(as: FirestoreGroup.self) {
                RTAnalytics.groupJoined(groupId: invite.groupId, kind: Self.analyticsKind(raw), groupSize: raw.memberUids.count)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Resolves an invite code to its document so the join confirmation can
    /// show what the user is agreeing to. This is the only view a non-member
    /// gets of a group — rules deny them `groups/{id}` itself.
    func fetchInvite(code: String) async -> InviteDoc? {
        guard let code = InviteLink.normalize(code) else { return nil }
        do {
            let snap = try await db.collection("invites").document(code).getDocument()
            return try? snap.data(as: InviteDoc.self)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Whether the signed-in user is already in this group, so the confirmation
    /// sheet can say so instead of failing on a duplicate join.
    func isCurrentUserMember(ofGroupId groupId: String) -> Bool {
        guard let uid = currentUid else { return false }
        return rawGroups[groupId]?.memberUids.contains(uid) ?? false
    }

    /// The signed-in user's display name, for stamping into invite links.
    var myDisplayName: String { currentDisplayName }

    /// Whether `uid` is already in the group's roster. Reading the group doc at
    /// all requires membership, so a denied read answers the question too.
    private func isMember(groupId: String, uid: String) async -> Bool {
        guard
            let snap = try? await db.collection("groups").document(groupId).getDocument(),
            let uids = snap.data()?["memberUids"] as? [String]
        else { return false }
        return uids.contains(uid)
    }

    // MARK: - Alarm edits

    // MARK: - Habits

    /// The signed-in member's habit in a group, if they built one.
    func myHabit(groupId: String) -> MemberHabit? {
        guard let uid = currentUid else { return nil }
        return (members[groupId]?.first { $0.id == uid } ?? pendingOwnMember[groupId])?.habit
    }

    /// The signed-in member's one-time-alarm checklist in a group, if any.
    func myChecklist(groupId: String) -> MemberHabit? {
        guard let uid = currentUid else { return nil }
        return (members[groupId]?.first { $0.id == uid } ?? pendingOwnMember[groupId])?.checklist?.asChecklist
    }

    /// Whether the signed-in member's own alarm in a group rings once.
    func myAlarmOnce(groupId: String) -> Bool {
        guard let uid = currentUid else { return false }
        return (members[groupId]?.first { $0.id == uid } ?? pendingOwnMember[groupId])?.alarmOnce == true
    }

    /// What opens after your alarm in a group: the checklist when your alarm
    /// rings once, the habit when it repeats.
    func myPlan(groupId: String) -> MemberHabit? {
        myAlarmOnce(groupId: groupId) ? myChecklist(groupId: groupId) : myHabit(groupId: groupId)
    }

    /// Every Check-ins group where the signed-in member has a habit (or, for a
    /// one-time alarm, a checklist), by group. Persisted with the alarm records
    /// so a Stop in a cold background launch knows which routine to open.
    func myHabitsByGroup() -> [String: MemberHabit] {
        var out: [String: MemberHabit] = [:]
        for group in groups where group.type == .accountability {
            if let plan = myPlan(groupId: group.id) { out[group.id] = plan }
        }
        return out
    }

    /// Sets the signed-in member's one-time-alarm checklist, or removes it with `nil`.
    @discardableResult
    func setMyChecklist(groupId: String, checklist: MemberHabit?) async -> Bool {
        guard let uid = currentUid else { return false }
        var stored = checklist
        stored?.isChecklist = nil
        do {
            try await db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .setData(["checklist": stored?.firestoreData ?? FieldValue.delete()], merge: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Sets the signed-in member's habit in a group, or removes it with `nil`.
    /// Habits are personal: this never touches anyone else's.
    @discardableResult
    func setMyHabit(groupId: String, habit: MemberHabit?) async -> Bool {
        guard let uid = currentUid else { return false }
        let hadHabit = myHabit(groupId: groupId) != nil
        do {
            try await db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .setData(["habit": habit?.firestoreData ?? FieldValue.delete()], merge: true)
            if let habit, !hadHabit {
                let what = habit.showSteps ? "started a habit: \(habit.name)" : "started building a habit"
                await writeActivity(groupId: groupId, kind: "habit_started", message: "\(currentDisplayName) \(what)")
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Sets the current member's own alarm (accountability) and notes it in the
    /// activity feed so the whole group is informed.
    func setMyAlarm(groupId: String, time: String, days: [Int] = [], once: Bool = false) async {
        guard let uid = currentUid else { return }
        do {
            try await db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .setData([
                    "alarmTime": time,
                    "alarmDays": once ? [] : days.sorted(),
                    "alarmOnce": once,
                    "alarmSetAt": FieldValue.serverTimestamp(),
                ], merge: true)
            await writeActivity(groupId: groupId, kind: "alarm_changed",
                                message: "\(currentDisplayName) set their alarm to \(RTAlarmTime.display(time))")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Sets the shared group's common alarm time (admins only, enforced by
    /// rules) and notes it in the activity feed.
    /// The picked time is wall-clock on *this* device, so whoever edits the
    /// alarm also sets the zone it's anchored to. Members elsewhere convert
    /// from it when the group is same-moment; the zone is written either way so
    /// that switching the anchor later has something to convert from.
    func setGroupAlarm(groupId: String, time: String, anchor: RTAlarmAnchor, days: [Int] = [], once: Bool = false) async {
        var fields: [String: Any] = [
            "alarmTime": time,
            "alarmTimeZone": TimeZone.current.identifier,
            "alarmAnchor": anchor.rawValue,
            "alarmDays": days.sorted(),
            "alarmOnce": once,
            "alarmSetAt": FieldValue.serverTimestamp(),
        ]
        // A dated plan alarm keeps its date for older builds too.
        if once, let day = rawGroups[groupId]?.onceDate, let alarmAt = Self.date(day: day, time: time) {
            fields["alarmSetAt"] = Timestamp(date: Self.onceAnchor(alarmAt))
        }
        do {
            try await db.collection("groups").document(groupId).updateData(fields)
            await refreshInvitePreview(groupId: groupId, fields: fields)
            await writeActivity(groupId: groupId, kind: "alarm_changed",
                                message: "\(currentDisplayName) changed the alarm to \(RTAlarmTime.display(time))")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Updates the denormalized copy of a group's display fields on its invite,
    /// so an invitee's pre-join preview doesn't show a stale wake-up time.
    /// Best-effort: a stale preview is cosmetic and must never fail the edit
    /// that triggered it.
    private func refreshInvitePreview(groupId: String, fields: [String: Any]) async {
        guard let code = rawGroups[groupId]?.inviteCode else { return }
        do {
            try await db.collection("invites").document(code).updateData(fields)
        } catch {
            logger.error("invite preview refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Admin roster

    /// Sets whether people who join via this group's invite code should become
    /// admins. The grant on join is applied by the (scaffolded) Cloud Function;
    /// until that's enabled, existing admins can promote via Manage Members.
    /// Only the invite's creator can change this (enforced by rules).
    func setInviteAsAdmin(groupId: String, asAdmin: Bool) async {
        guard let code = rawGroups[groupId]?.inviteCode else { return }
        do {
            try await db.collection("invites").document(code).updateData(["asAdmin": asAdmin])
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The current invite's "join as admin" setting, if known.
    func inviteAsAdmin(groupId: String) -> Bool { pendingInviteAsAdmin[groupId] ?? false }
    private var pendingInviteAsAdmin: [String: Bool] = [:]
    func cacheInviteAsAdmin(groupId: String, value: Bool) { pendingInviteAsAdmin[groupId] = value }

    func promoteToAdmin(groupId: String, memberUid: String) async {
        do {
            try await db.collection("groups").document(groupId)
                .updateData(["adminUids": FieldValue.arrayUnion([memberUid])])
        } catch { lastError = error.localizedDescription }
    }

    func removeAdmin(groupId: String, memberUid: String) async {
        guard let g = rawGroups[groupId], g.adminUids.count > 1 else {
            lastError = "A group needs at least one admin."
            return
        }
        do {
            try await db.collection("groups").document(groupId)
                .updateData(["adminUids": FieldValue.arrayRemove([memberUid])])
        } catch { lastError = error.localizedDescription }
    }

    /// Removes another member from the group (admins only). Drops them from the
    /// roster and admin list in one write, then best-effort deletes their member
    /// and status docs. Membership is the source of truth, so it's removed first
    /// — a failed sub-doc delete just leaves harmless orphans a rebuild ignores.
    func removeMember(groupId: String, memberUid: String) async {
        guard let uid = currentUid, let g = rawGroups[groupId] else { return }
        guard g.adminUids.contains(uid) else {
            lastError = "Only an admin can remove members."
            return
        }
        guard memberUid != uid else {
            lastError = "You can't remove yourself."
            return
        }
        // Refuse to strip the group's last admin.
        if g.adminUids.contains(memberUid) && g.adminUids.count <= 1 {
            lastError = "A group needs at least one admin."
            return
        }
        let removedName = members[groupId]?.first { $0.id == memberUid }?.displayName ?? "A member"
        do {
            try await db.collection("groups").document(groupId).updateData([
                "memberUids": FieldValue.arrayRemove([memberUid]),
                "adminUids": FieldValue.arrayRemove([memberUid]),
            ])
            try? await db.collection("groups").document(groupId)
                .collection("members").document(memberUid).delete()
            try? await db.collection("groups").document(groupId)
                .collection("statuses").document(memberUid).delete()
            await writeActivity(groupId: groupId, kind: "removed",
                                message: "\(removedName) was removed by \(currentDisplayName)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Leaves a group of the current user's own accord: drops them from the
    /// roster (and admin list), then best-effort deletes their own member and
    /// status docs. The group then leaves this device's live list, so
    /// `RTAlarmSync` cancels the associated alarm on the next reconcile — no
    /// separate alarm teardown is needed.
    ///
    /// Scenarios, all handled here:
    ///  - **Sole member:** there's no one to leave behind, so leaving *is*
    ///    deleting — it routes to `deleteGroup` (which also tidies the invite
    ///    and avoids a zombie one-person group).
    ///  - **Last admin with other members:** refused. Removing the only admin
    ///    would strand the group with no one able to manage it, and the rules
    ///    reject an empty `adminUids` anyway. The user is told to promote
    ///    someone first or delete the group.
    ///  - **Otherwise:** a plain self-removal (a co-admin, or a regular member).
    @discardableResult
    func leaveGroup(groupId: String) async -> Bool {
        guard let uid = currentUid, let g = rawGroups[groupId] else { return false }
        // A one-person group has no one to leave behind — leaving is deleting.
        if g.memberUids.count <= 1 {
            return await deleteGroup(groupId: groupId)
        }
        // Can't abandon a group that still has members but would have no admin.
        if g.adminUids.contains(uid) && g.adminUids.count <= 1 {
            lastError = "You're the only admin. Make someone else an admin first, or delete the group."
            return false
        }
        do {
            // Announce the exit while still a member — activity writes require it.
            await writeActivity(groupId: groupId, kind: "left",
                                message: "\(currentDisplayName) left the group")
            try await db.collection("groups").document(groupId).updateData([
                "memberUids": FieldValue.arrayRemove([uid]),
                "adminUids": FieldValue.arrayRemove([uid]),
            ])
            try? await db.collection("groups").document(groupId)
                .collection("members").document(uid).delete()
            try? await db.collection("groups").document(groupId)
                .collection("statuses").document(uid).delete()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Removes the signed-in user from every group and deletes their profile and
    /// FCM token — the data side of account deletion. A group the user solely
    /// admins (with other members) is deleted outright, since it can't be left
    /// orphaned; every other group is simply left. Best-effort per group so one
    /// failure doesn't abort the rest. The Auth account itself is deleted by
    /// `AuthManager.deleteAccount` after this.
    func deleteAccountData() async {
        guard let uid = currentUid else { return }
        // Snapshot ids first — leaving/deleting mutates the live `groups` list.
        for id in groups.map(\.id) {
            guard let g = rawGroups[id] else { continue }
            let soleAdmin = g.adminUids.contains(uid) && g.adminUids.count <= 1 && g.memberUids.count > 1
            if soleAdmin {
                _ = await deleteGroup(groupId: id)
            } else {
                _ = await leaveGroup(groupId: id)
            }
        }
        try? await db.collection("users").document(uid).delete()
        try? await db.collection("fcmTokens").document(uid).delete()
    }

    /// Deletes a group outright (admins only). This removes it for **everyone**:
    /// each member's live query stops returning it, so their `RTAlarmSync`
    /// cancels the associated on-device alarm on the next reconcile. With no
    /// server, that client-side reconcile is the only thing that clears the
    /// alarm off other members' phones — which is exactly why a group's alarm
    /// can't outlive the group.
    ///
    /// Firestore doesn't cascade, so the invite and sub-docs are cleaned up
    /// first (best-effort) and the group doc is deleted last — the invite/member
    /// deletes are admin-gated on the group still existing, so ordering matters.
    @discardableResult
    func deleteGroup(groupId: String) async -> Bool {
        guard let uid = currentUid, let g = rawGroups[groupId] else { return false }
        // Admins can always delete. An admin-less legacy group (empty adminUids)
        // has no one to manage it, so any member may delete it to clean it up.
        guard g.adminUids.isEmpty || g.adminUids.contains(uid) else {
            lastError = "Only an admin can delete the group."
            return false
        }
        // Invite first, while the group (and its adminUids) still exists to
        // authorize a co-admin who didn't mint it.
        try? await db.collection("invites").document(g.inviteCode).delete()
        // Then the sub-docs. An admin may delete any member's/status's doc.
        for member in members[groupId] ?? [] {
            guard let mid = member.id else { continue }
            try? await db.collection("groups").document(groupId)
                .collection("members").document(mid).delete()
        }
        for status in statuses[groupId] ?? [] {
            guard let sid = status.id else { continue }
            try? await db.collection("groups").document(groupId)
                .collection("statuses").document(sid).delete()
        }
        do {
            try await db.collection("groups").document(groupId).delete()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Writes/updates the current user's status in a group. When `activity` is
    /// provided, also appends an activity entry so the whole group is notified.
    ///
    /// The writes are queued, not awaited: `setData` lands in Firestore's
    /// on-disk queue immediately (and the live roster updates from the local
    /// cache), then syncs when the network allows. Awaiting the server ack used
    /// to stall here offline — and since the history write only started after
    /// that ack, a response made offline could reach the roster but never the
    /// Rise Report. Returns false only when nobody is signed in.
    @discardableResult
    func setMyStatus(groupId: String, status: RTStatus, detail: String, eta: String? = nil, activity: String? = nil) async -> Bool {
        guard let uid = currentUid else {
            lastError = "You're not signed in."
            return false
        }
        var payload: [String: Any] = [
            "status": status.storageKey,
            "detail": detail,
            "respondedAt": Timestamp(date: Date()),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let eta { payload["eta"] = eta }
        if let raw = rawGroups[groupId] {
            let kind = Self.analyticsKind(raw)
            switch status {
            case .coming, .runningLate, .cantMakeIt:
                RTAnalytics.planAnswered(groupId: groupId, kind: kind,
                                         answer: status == .coming ? "in" : status == .runningLate ? "late" : "skip", ahead: false)
            default:
                RTAnalytics.alarmResponse(groupId: groupId, kind: kind, status: status.storageKey)
            }
        }
        db.collection("groups").document(groupId)
            .collection("statuses").document(uid)
            .setData(payload) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        lastError = nil
        recordHistory(groupId: groupId, uid: uid, status: status, detail: detail)
        if let activity {
            await writeActivity(groupId: groupId, kind: "response", message: activity)
        }
        return true
    }

    /// Alarm outcomes that belong in a member's per-day history (the Rise
    /// Report). `runningLate` is included: a late dismiss is a real wake-up and
    /// must show as late — leaving it out made the report show a gap for that
    /// day, which the missed-alarm reconcile then back-filled as "no response".
    static let historyStatuses: Set<RTStatus> = [.wokeUp, .snoozed, .runningLate, .silentLate]

    /// Appends today's alarm outcome to the member's per-day history, which
    /// backs the Rise Report. Alarm groups only — an event's "running late" RSVP
    /// shares a status with a late wake-up but isn't accountability data.
    /// Replaces the day's doc so a real response clears an earlier automatic
    /// mark. Queued like the status write; best-effort.
    private func recordHistory(groupId: String, uid: String, status: RTStatus, detail: String, extra: [String: Any] = [:]) {
        guard Self.historyStatuses.contains(status),
              rawGroups[groupId]?.groupType != .event else { return }
        let day = Self.dayKey()
        var data: [String: Any] = [
            "status": status.storageKey,
            "detail": detail,
            "date": day,
            "respondedAt": Timestamp(date: Date()),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        data.merge(extra) { _, new in new }
        db.collection("groups").document(groupId)
            .collection("members").document(uid)
            .collection("history").document(day)
            .setData(data) { [weak self] error in
                guard let error else { return }
                self?.logger.error("history write failed: \(error.localizedDescription, privacy: .public)")
            }
    }

    // MARK: - Manual check-in

    /// Today's alarm slot for this group that has already rung but has no
    /// response from you — the case where tapping Stop/Snooze didn't reach the
    /// app (or the alarm was silenced some other way). The group screens offer
    /// to record what happened. Nil when there's nothing to fill in.
    ///
    /// Counts as "no response": no status since the alarm fired, or only the
    /// automatic "no response" mark the app writes for a skipped alarm. A real
    /// response — including the ring screen's own timeout — closes it.
    func pendingCheckIn(groupId: String, now: Date = Date()) -> RTPendingCheckIn? {
        guard let uid = currentUid, let raw = rawGroups[groupId],
              let group = group(id: groupId),
              group.type == .accountability || group.type == .shared,
              !group.alarm.isEmpty
        else { return nil }

        let setAt = (group.type == .accountability
            ? members[groupId]?.first { $0.id == uid }?.alarmSetAt
            : raw.alarmSetAt)?.dateValue()
        let fire: Date?
        if group.alarmOnce {
            // A one-time alarm rings at the first occurrence after it was set.
            fire = setAt.flatMap { Self.firstOccurrence(of: group.alarm, after: $0) }
        } else {
            fire = MissedAlarm.mostRecentFire(time: group.alarm, days: group.alarmDays, now: now, lookbackDays: 0)
        }
        guard let fire, fire <= now, Calendar.current.isDate(fire, inSameDayAs: now) else { return nil }
        // You can't have missed an alarm that rang before you had it.
        if let floor = setAt ?? raw.createdAt?.dateValue(), fire < floor { return nil }

        if let doc = statuses[groupId]?.first(where: { $0.id == uid }) {
            let automatic = doc.auto == true && doc.status == RTStatus.silentLate.storageKey
            // A legacy unsynced write has no time at all yet, so it's from now.
            let respondedSinceFire = doc.effectiveTime.map { $0 >= fire.addingTimeInterval(-60) } ?? true
            if respondedSinceFire && !automatic { return nil }
        }
        return RTPendingCheckIn(groupId: groupId, time: group.alarm, fireDate: fire)
    }

    /// Records what happened to today's alarm, as told by the member. Applies to
    /// every alarm group that shares the slot and is still awaiting a check-in —
    /// they were all one alarm on the phone, so one answer covers them all.
    @discardableResult
    func recordManualCheckIn(groupId: String, status: RTStatus) async -> Bool {
        guard let uid = currentUid, status == .wokeUp || status == .snoozed,
              let target = pendingCheckIn(groupId: groupId) else { return false }
        let covered = groups.compactMap { pendingCheckIn(groupId: $0.id) }
            .filter { $0.time == target.time }
        let detail = status == .wokeUp ? "woke up · marked in app" : "snoozed · marked in app"
        let verb = status == .wokeUp ? "woke up" : "snoozed"
        for item in covered {
            db.collection("groups").document(item.groupId)
                .collection("statuses").document(uid)
                .setData([
                    "status": status.storageKey,
                    "detail": detail,
                    "manual": true,
                    "respondedAt": Timestamp(date: Date()),
                    "updatedAt": FieldValue.serverTimestamp(),
                ]) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                }
            recordHistory(groupId: item.groupId, uid: uid, status: status, detail: detail, extra: ["manual": true])
            await writeActivity(groupId: item.groupId, kind: "response",
                                message: "\(currentDisplayName) marked that they \(verb)")
        }
        // Answered here, so withdraw the "Did you wake up?" notification for it.
        if let group = group(id: groupId) {
            await AlarmReliability.checkInAnsweredInApp(slotKey: RTAlarmSync.slotKey(for: group), fire: target.fireDate)
        }
        return !covered.isEmpty
    }

    /// The habit or checklist to ask about after a check-in, if any: a
    /// checklist follows any stop, a habit only "I woke up" (as with a real stop).
    func checkInFollowUp(groupId: String, status: RTStatus) -> MemberHabit? {
        guard let me = group(id: groupId)?.roster.first(where: { $0.isYou }) else { return nil }
        if let checklist = me.checklist, !checklist.steps.isEmpty { return checklist }
        if status == .wokeUp, let habit = me.habit, !habit.steps.isEmpty { return habit }
        return nil
    }

    /// Records a habit or checklist answered on the check-in card, for an alarm
    /// whose stop never reached the app (so its routine never started). The
    /// window is already over, so unticked steps read as missed, as with a
    /// routine left unfinished. Same fields as `RoutineCoordinator`, plus
    /// `manual: true`. Queued, not awaited.
    func recordManualRoutine(groupId: String, fireDate: Date, habit: MemberHabit, done: [Bool]) {
        guard let uid = currentUid else { return }
        let day = Self.dayKey(fireDate)
        let deadline = fireDate.addingTimeInterval(TimeInterval(habit.windowMinutes * 60))
        let allDone = !done.isEmpty && done.allSatisfy { $0 }
        let progress = RoutineProgress(
            day: day, done: done, tiny: false,
            startedAt: Timestamp(date: fireDate),
            deadline: Timestamp(date: min(deadline, Date())),
            completedAt: allDone ? Timestamp(date: Date()) : nil)
        var routine = progress.firestoreData
        routine["manual"] = true
        let group = db.collection("groups").document(groupId)
        group.collection("statuses").document(uid).setData(["routine": routine], merge: true) { _ in }
        group.collection("members").document(uid).collection("history").document(day)
            .setData(["routine": routine, "date": day], merge: true) { _ in }
        RTAnalytics.checkInRoutineAnswered(groupId: groupId, checklist: habit.checklist,
                                           done: done.filter { $0 }.count, total: done.count)
    }

    /// The first time "HH:mm" occurs at or after `date`, in this device's zone.
    /// "yyyy-MM-dd" + "HH:mm" in the device's zone.
    static func date(day: String, time: String) -> Date? {
        let d = day.split(separator: "-").compactMap { Int($0) }
        let t = time.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2 else { return nil }
        return Calendar.current.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1]))
    }

    // MARK: - Plans

    /// Creates a plan from the Plans tab. A one-time plan is an `event`; the
    /// other two are `shared` groups whose alarm (if any) rings `alarmLeadMinutes`
    /// minutes before the start. Plan settings ride on the group doc (see
    /// docs/plans-build.md); headcount asks are stored now and sent by a later
    /// Cloud Function.
    @discardableResult
    /// Creates a plan; returns its group id (Android's `createPlan` returns the
    /// same), or nil if it failed. The invite code is `lastCreatedInviteCode`.
    func createPlan(
        kind: RTPlanKind,
        name: String,
        place: String,
        start: Date,
        days: [Int] = [],
        hasAlarm: Bool,
        alarmLeadMinutes: Int,
        flagNotUpMinutes: Int?,
        attendanceDefault: String,
        headcountAsks: [RTHeadcountAsk],
        weeklyLookahead: Bool
    ) async -> String? {
        let code = await createPlanGroup(kind: kind, name: name, place: place, start: start, days: days,
                                         hasAlarm: hasAlarm, alarmLeadMinutes: alarmLeadMinutes,
                                         flagNotUpMinutes: flagNotUpMinutes, attendanceDefault: attendanceDefault,
                                         headcountAsks: headcountAsks, weeklyLookahead: weeklyLookahead)
        return code == nil ? nil : lastCreatedGroupId
    }

    private func createPlanGroup(
        kind: RTPlanKind,
        name: String,
        place: String,
        start: Date,
        days: [Int] = [],
        hasAlarm: Bool,
        alarmLeadMinutes: Int,
        flagNotUpMinutes: Int?,
        attendanceDefault: String,
        headcountAsks: [RTHeadcountAsk],
        weeklyLookahead: Bool
    ) async -> String? {
        var fields: [String: Any] = [
            "planKind": kind.rawValue,
            "headcountAsks": headcountAsks.map(\.firestoreData),
        ]
        if !place.isEmpty { fields["eventPlace"] = place }
        switch kind {
        case .once:
            return await createGroup(type: .event, name: name, eventTitle: name,
                                     eventPlace: place.isEmpty ? nil : place, eventAt: start, planFields: fields)
        case .onceAlarm:
            let alarmAt = start.addingTimeInterval(TimeInterval(-alarmLeadMinutes * 60))
            fields["meetAt"] = Timestamp(date: start)
            fields["onceDate"] = Self.dayKey(alarmAt)
            // Older builds ring a one-time alarm at the first occurrence of its
            // time after `alarmSetAt`; anchoring it just before the real alarm
            // makes them ring on the plan's date too (and not mark misses before).
            fields["alarmSetAt"] = Timestamp(date: Self.onceAnchor(alarmAt))
            fields["alarmLeadMinutes"] = alarmLeadMinutes
            if let flagNotUpMinutes { fields["flagNotUpMinutes"] = flagNotUpMinutes }
            return await createGroup(type: .shared, name: name, alarmTime: RTAlarmTime.string(from: alarmAt),
                                     alarmOnce: true, planFields: fields)
        case .repeating:
            let startTime = RTAlarmTime.string(from: start)
            fields["startTime"] = startTime
            fields["hasAlarm"] = hasAlarm
            fields["attendanceDefault"] = attendanceDefault
            fields["weeklyLookahead"] = weeklyLookahead
            guard hasAlarm else {
                // No alarm at all: the days still say when it happens.
                if !days.isEmpty { fields["alarmDays"] = days.sorted() }
                return await createGroup(type: .shared, name: name, planFields: fields)
            }
            fields["alarmLeadMinutes"] = alarmLeadMinutes
            let alarm = Self.planAlarm(start: start, leadMinutes: alarmLeadMinutes, days: days)
            return await createGroup(type: .shared, name: name, alarmTime: alarm.time,
                                     alarmDays: alarm.days, alarmOnce: false, planFields: fields)
        }
    }

    /// `alarmSetAt` for a plan's dated one-time alarm: a minute before it rings,
    /// so "the first occurrence after alarmSetAt" (how older builds schedule it)
    /// is the plan's date.
    static func onceAnchor(_ alarmAt: Date) -> Date { alarmAt.addingTimeInterval(-60) }

    /// A repeating plan's alarm: `lead` minutes before `start`, on the session
    /// days, except an alarm before midnight for a just-after-midnight start
    /// rings the evening before, so its days shift back one.
    static func planAlarm(start: Date, leadMinutes lead: Int, days: [Int],
                          calendar: Calendar = .current) -> (time: String, days: [Int]) {
        let alarmAt = start.addingTimeInterval(TimeInterval(-lead * 60))
        let crossesMidnight = !calendar.isDate(alarmAt, inSameDayAs: start)
        return (RTAlarmTime.string(from: alarmAt), crossesMidnight ? days.map { $0 == 1 ? 7 : $0 - 1 } : days)
    }

    private static func firstOccurrence(of time: String, after date: Date) -> Date? {
        let parts = time.split(separator: ":")
        guard let hour = parts.first.flatMap({ Int($0) }) else { return nil }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.nextDate(after: date.addingTimeInterval(-1), matching: comps, matchingPolicy: .nextTime)
    }

    // MARK: - Skipped-alarm reconciliation

    /// Marks *skipped* alarms as silent-late.
    ///
    /// A status is normally only recorded in reaction to a real action (dismiss/
    /// snooze) or the ring UI's no-response timer — all of which need the app to
    /// run. When the device is switched off (or the alarm rings natively and is
    /// never touched) across the alarm's deadline, nothing records the miss and
    /// the slot stays blank forever. This is the counterpart: on launch and
    /// foreground each device reconciles its *own* recent slots — for any
    /// past-deadline day with no recorded outcome it writes `silent_late` to
    /// that day's history, and for *today* also updates the live status doc so
    /// the rest of the group sees it.
    ///
    /// Own alarms only (you can only write your own status), recurring
    /// accountability/shared alarms only, bounded to the last `lookbackDays`
    /// days and never earlier than the first day this device saw the group.
    func reconcileMissedAlarms(lookbackDays: Int = 7) async {
        guard let uid = currentUid else { return }
        let now = Date()
        let todayKey = Self.dayKey(now)
        let startOfToday = Calendar.current.startOfDay(for: now)

        for group in groups where group.type == .accountability || group.type == .shared {
            // A one-time alarm (shared, or your own on Check-ins) isn't swept: it
            // rings once, and its pending check-in card covers a missed ring.
            if group.alarmOnce { continue }
            let time = group.alarm    // already this device's local wall-clock
            guard !time.isEmpty else { continue }

            // The group's configured late window (the same "limit" the ring UI's
            // auto-snooze path uses before going silent), defaulting to 15 min.
            let lateWindow = TimeInterval((rawGroups[group.id]?.lateThresholdMinutes ?? 15) * 60)
            let missed = MissedAlarm.missedOccurrences(
                time: time, days: group.alarmDays, now: now,
                lookbackDays: lookbackDays, lateWindow: lateWindow
            )
            guard !missed.isEmpty else { continue }

            // Never mark a day from before we first knew about this group — a
            // freshly-joined member wasn't accountable for last week — nor before
            // the alarm was actually set (so a just-set alarm whose time already
            // passed today isn't retroactively marked missed for today).
            let deviceFloor = missedReconcileFloor(for: group.id, uid: uid, startOfToday: startOfToday)
            let alarmFloor = (group.type == .accountability
                ? members[group.id]?.first { $0.id == uid }?.alarmSetAt
                : rawGroups[group.id]?.alarmSetAt)?.dateValue()
                ?? rawGroups[group.id]?.createdAt?.dateValue()
            let floor = max(deviceFloor, alarmFloor ?? .distantPast)
            // A day you said you'd skip is never a miss.
            let skipped = Set(members[group.id]?.first { $0.id == uid }?.skips ?? [])
            let eligible = missed.filter { $0.fireDate >= floor && !skipped.contains($0.dayKey) }
            guard !eligible.isEmpty else { continue }

            let earliestKey = eligible.map(\.dayKey).min() ?? todayKey
            let recorded = await recordedHistoryDays(groupId: group.id, uid: uid, from: earliestKey)
            // A status recorded today means the user did respond — including a
            // *late* dismiss, which maps to running-late and is deliberately not
            // written to history. Without this guard that response would be
            // overwritten as silent-late today.
            let respondedToday = statusRecordedToday(groupId: group.id, uid: uid)

            // `recorded` is only a cheap pre-filter. It can come back short — a
            // swallowed query error, or an offline/partial cache — and trusting
            // it is exactly what overwrote real "woke up" days as late. The
            // writes below re-check each doc on the server and never replace one.
            for occ in eligible where !recorded.contains(occ.dayKey) {
                if occ.dayKey == todayKey {
                    if respondedToday { continue }
                    // Today's miss also updates the live status doc so the group
                    // sees it now — but only once history confirmed the day was empty.
                    if await writeSilentLateHistoryIfAbsent(groupId: group.id, uid: uid, dayKey: occ.dayKey) {
                        await markTodaySilentLateStatusIfUnanswered(groupId: group.id, uid: uid, fire: occ.fireDate)
                    }
                } else {
                    await writeSilentLateHistoryIfAbsent(groupId: group.id, uid: uid, dayKey: occ.dayKey)
                }
            }
        }
    }

    /// The earliest day this device is willing to back-fill for `gid` — the
    /// first day it ever reconciled the group, persisted so a member who joined
    /// recently isn't retroactively marked late for days they weren't in.
    ///
    /// Keyed by account as well as group: a different account signing in on
    /// this device starts its own floor rather than inheriting the previous
    /// account's history with the group.
    private func missedReconcileFloor(for gid: String, uid: String, startOfToday: Date) -> Date {
        let key = "whozup.missedFloor.\(uid).\(gid)"
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: key) as? Date { return stored }
        defaults.set(startOfToday, forKey: key)
        return startOfToday
    }

    /// The set of day keys in `[from, today]` for which this user already has a
    /// recorded alarm outcome (any history doc), read from cache-or-server.
    private func recordedHistoryDays(groupId: String, uid: String, from startKey: String) async -> Set<String> {
        let q = db.collection("groups").document(groupId)
            .collection("members").document(uid)
            .collection("history")
            .whereField("date", isGreaterThanOrEqualTo: startKey)
        guard let snap = try? await q.getDocuments() else { return [] }
        return Set(snap.documents.map(\.documentID))
    }

    /// Writes a silent-late outcome to one day's history **only if that day has
    /// no outcome on the server**. Returns whether it wrote.
    ///
    /// An automatic mark is a guess; a real response is a fact, so the guess
    /// must never replace the fact. The existence check and the write happen in
    /// one transaction against the server, so a response that already landed —
    /// or lands concurrently — always wins. Offline the transaction fails and
    /// nothing is written: the live roster already shows "no response", and the
    /// next reconcile with a connection back-fills the day.
    @discardableResult
    private func writeSilentLateHistoryIfAbsent(groupId: String, uid: String, dayKey: String) async -> Bool {
        let ref = db.collection("groups").document(groupId)
            .collection("members").document(uid)
            .collection("history").document(dayKey)
        let wrote = try? await withTimeout(.seconds(10)) { [db] in
            (try await db.runTransaction { tx, errorPointer -> Any? in
                do {
                    if try tx.getDocument(ref).exists { return false }
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                tx.setData([
                    "status": RTStatus.silentLate.storageKey,
                    "detail": "no response",
                    "date": dayKey,
                    "auto": true,
                    "updatedAt": FieldValue.serverTimestamp(),
                ], forDocument: ref)
                return true
            }) as? Bool == true
        }
        return wrote == true
    }

    /// Whether this user already has a status recorded *today* — i.e. they
    /// responded (status docs are only written on a real response, never for the
    /// derived "waiting" default), or an earlier reconcile already marked them.
    private func statusRecordedToday(groupId: String, uid: String) -> Bool {
        // A response written while offline still has a `null` server timestamp
        // locally, so `updatedAt` alone can't see it — and without this the
        // missed-alarm reconcile would read "no response today" and overwrite a
        // real, just-made dismiss/snooze/late response with silent-late, losing
        // the user's action. A pending own-status write is exactly that unsynced
        // response, so treat it as recorded today. (A `runningLate` response,
        // which writes no history doc, relies on this guard entirely once synced.)
        if pendingStatuses[groupId]?.contains(uid) == true { return true }
        guard let answeredAt = statuses[groupId]?.first(where: { $0.id == uid })?.effectiveTime
        else { return false }
        return Self.dayKey(answeredAt) == Self.dayKey()
    }

    /// Sets today's live status doc to silent-late, unless the server copy shows
    /// a real answer since the alarm fired. Checked in a transaction for the same
    /// reason as `writeSilentLateHistoryIfAbsent`: the in-memory `statuses` can be
    /// empty (a background task's fresh repository) and must not be read as
    /// "no answer".
    private func markTodaySilentLateStatusIfUnanswered(groupId: String, uid: String, fire: Date) async {
        if statusRecordedToday(groupId: groupId, uid: uid) { return }
        let ref = db.collection("groups").document(groupId).collection("statuses").document(uid)
        _ = try? await withTimeout(.seconds(10)) { [db] in
            _ = try await db.runTransaction { tx, errorPointer -> Any? in
                let snap: DocumentSnapshot
                do { snap = try tx.getDocument(ref) } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                let answeredAt = (snap.get("respondedAt") as? Timestamp ?? snap.get("updatedAt") as? Timestamp)?.dateValue()
                let realAnswer = snap.exists && (snap.get("auto") as? Bool) != true
                    && (answeredAt.map { $0 >= fire.addingTimeInterval(-60) } ?? false)
                if realAnswer { return nil }
                tx.setData([
                    "status": RTStatus.silentLate.storageKey,
                    "detail": "no response",
                    "auto": true,
                    "respondedAt": Timestamp(date: Date()),
                    "updatedAt": FieldValue.serverTimestamp(),
                ], forDocument: ref)
                return nil
            }
        }
    }

    /// Runs `operation`, giving up after `timeout` so an offline reconcile
    /// (whose transactions retry until the network returns) can't stall.
    private func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    /// Local "yyyy-MM-dd" key for a day, the doc id under a member's history.
    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Dashboard reads

    /// Each member's alarm outcome for one day (uid → status), for the
    /// dashboard's day view. One-shot read; absent members simply have no entry.
    func fetchDayOutcomes(
        groupId: String, day: String,
        routine: ((_ uid: String, _ routine: RoutineProgress) -> Void)? = nil
    ) async -> [String: RTStatus] {
        guard let g = rawGroups[groupId] else { return [:] }
        var result: [String: RTStatus] = [:]
        for uid in g.memberUids {
            if let snap = try? await db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .collection("history").document(day).getDocument(),
               let s = snap.data()?["status"] as? String {
                result[uid] = RTStatus(storageKey: s)
                if let r = RoutineProgress(map: snap.data()?["routine"]) { routine?(uid, r) }
            }
        }
        if day == Self.dayKey() {
            overlayLiveOutcomes(groupId: groupId) { uid, s in result[uid] = s }
            for member in group(id: groupId)?.roster ?? [] { if let r = member.routine { routine?(member.uid, r) } }
        }
        return result
    }

    /// Today's outcome per member as the live roster shows it, so the Rise
    /// Report agrees with the group screen. History can briefly trail the live
    /// status (a write still syncing) or not exist yet (another member's device
    /// hasn't reconciled a skipped alarm, which the roster already derives as
    /// "no response"); the live view is the fresher of the two for today.
    private func overlayLiveOutcomes(groupId: String, apply: (String, RTStatus) -> Void) {
        for member in group(id: groupId)?.roster ?? [] where Self.historyStatuses.contains(member.status) {
            apply(member.uid, member.status)
        }
    }

    /// Each member's outcomes across a month (uid → [dayKey → status]), for the
    /// dashboard's month view. `monthPrefix` is "yyyy-MM".
    func fetchMonthOutcomes(
        groupId: String, monthPrefix: String,
        routine: ((_ uid: String, _ day: String, _ routine: RoutineProgress) -> Void)? = nil
    ) async -> [String: [String: RTStatus]] {
        guard let g = rawGroups[groupId] else { return [:] }
        let start = "\(monthPrefix)-01"
        let end = "\(monthPrefix)-31"
        var result: [String: [String: RTStatus]] = [:]
        for uid in g.memberUids {
            let q = db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .collection("history")
                .whereField("date", isGreaterThanOrEqualTo: start)
                .whereField("date", isLessThanOrEqualTo: end)
            if let snap = try? await q.getDocuments() {
                var days: [String: RTStatus] = [:]
                for doc in snap.documents where doc.data()["status"] is String {
                    days[doc.documentID] = RTStatus(storageKey: doc.data()["status"] as! String)
                    if let r = RoutineProgress(map: doc.data()["routine"]) { routine?(uid, doc.documentID, r) }
                }
                result[uid] = days
            }
        }
        let today = Self.dayKey()
        if today.hasPrefix(monthPrefix) {
            overlayLiveOutcomes(groupId: groupId) { uid, s in result[uid, default: [:]][today] = s }
            for member in group(id: groupId)?.roster ?? [] { if let r = member.routine { routine?(member.uid, today, r) } }
        }
        return result
    }

    /// Records (or changes) the current user's event RSVP and notifies the group.
    @discardableResult
    func recordEventResponse(groupId: String, status: RTStatus, eta: String? = nil) async -> Bool {
        let detail: String
        let verb: String
        switch status {
        case .coming: detail = "coming"; verb = "is coming"
        case .runningLate:
            detail = eta.map { "ETA \($0)" } ?? "running late"
            verb = eta.map { "is running late (\($0))" } ?? "is running late"
        case .cantMakeIt: detail = "can't make it"; verb = "can't make it"
        default: detail = ""; verb = "responded"
        }
        let message = "\(currentDisplayName) \(verb)"
        return await setMyStatus(groupId: groupId, status: status, detail: detail, eta: eta, activity: message)
    }

    /// Admin nudge: ask the `sendEventReminder` Cloud Function to push every
    /// non-responder (excluding the admin). Writing a trigger doc — rather than
    /// calling a callable — keeps the client free of the Functions SDK and lets
    /// the server stay authoritative for the max-2 cap. The resulting
    /// `reminderCount` bump on the group doc flows back through the live
    /// listener, so the "N left" label updates on its own.
    @discardableResult
    func sendReminder(groupId: String) async -> Bool {
        guard let uid = currentUid else { return false }
        do {
            _ = try await db.collection("groups").document(groupId)
                .collection("reminders")
                .addDocument(data: [
                    "byUid": uid,
                    "createdAt": FieldValue.serverTimestamp(),
                ])
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func group(id: String) -> RTGroup? { groups.first { $0.id == id } }

    /// Weekly plans this user hosts (analytics: the "second weekly plan" pricing trigger).
    var weeklyPlansHosted: Int { groups.filter { $0.planKind == .repeating && $0.hostedByCurrentUser }.count }

    /// The analytics kind of a raw group doc.
    static func analyticsKind(_ raw: FirestoreGroup) -> String {
        RTAnalytics.kind(type: raw.groupType, planKind: raw.planKind.flatMap(RTPlanKind.init(rawValue:)))
    }

    func groups(of type: RTGroupType) -> [RTGroup] { groups.filter { $0.type == type } }

    func inviteCode(for groupId: String) -> String? { rawGroups[groupId]?.inviteCode }

    // MARK: - Alarm bridge

    /// Wires an `AlarmStatusRecorder` so an alarm action seen in-process (the
    /// app is running when the user taps Stop/Snooze) is written too. It goes
    /// through the same `AlarmActionHandler` as the alarm's AppIntents, which
    /// derives the status against the right occurrence, fans it out to every
    /// group behind the alarm, and drops the duplicate when both paths report
    /// the same tap. Call once at app start.
    func bindAlarmRecorder(_ recorder: AlarmStatusRecorder) {
        recorder.onRecorded = { alarmID, result in
            Task {
                await AlarmActionHandler.capture(
                    alarmID: alarmID, kind: result.action.kind, at: result.action.timestamp
                )
            }
        }
    }

    /// The signed-in uid this repository is serving, stamped onto persisted
    /// alarm records so a response can only ever be written for that account.
    var signedInUid: String? { currentUid }

    static func rtStatus(from status: MemberStatus) -> RTStatus {
        switch status {
        case .respondedOnTime: return .wokeUp
        case .snoozed: return .snoozed
        case .respondedLate: return .runningLate
        case .silentLate: return .silentLate
        case .pending: return .waiting
        }
    }

    /// The status line, stamped with when the person answered — `at` matters
    /// for a response replayed later from the journal.
    /// Stopped on a re-ring after a snooze: recorded as snoozed, with when.
    /// Same copy as Android's `StatusDerivation.upAfterSnoozeDetail`.
    static func upAfterSnoozeDetail(at date: Date = Date()) -> String {
        "snoozed · " + detail(for: .wokeUp, at: date)
    }

    static func detail(for status: RTStatus, at date: Date = Date()) -> String {
        // Force 12-hour AM/PM rather than the device's short-time style, which is
        // 24-hour on some locales — WhoZup shows wake-up times as AM/PM everywhere.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        let time = f.string(from: date)
        switch status {
        case .wokeUp: return "up at \(time)"
        case .snoozed: return "snoozed"
        case .runningLate: return "up late at \(time)"
        case .silentLate: return "no dismiss or snooze"
        default: return ""
        }
    }

    // MARK: - Helpers

    private func writeMyMemberDoc(groupId: String, uid: String, role: String, alarmTime: String? = nil,
                                  alarmDays: [Int] = [], alarmOnce: Bool = false) async throws {
        let initials = String(currentDisplayName.prefix(1)).uppercased()
        var data: [String: Any] = [
            "displayName": currentDisplayName,
            "initials": initials.isEmpty ? "?" : initials,
            "avatarColorHex": RTAvatarPalette.hex(for: uid),
            "role": role,
        ]
        if let alarmTime {
            data["alarmTime"] = alarmTime
            // Floor for the missed-alarm check — the alarm only applies from now.
            data["alarmSetAt"] = FieldValue.serverTimestamp()
        }
        if !alarmDays.isEmpty { data["alarmDays"] = alarmDays.sorted() }
        if alarmOnce { data["alarmOnce"] = true }
        try await db.collection("groups").document(groupId)
            .collection("members").document(uid).setData(data, merge: true)
    }

    /// Appends an entry to the group's activity feed. This both informs the
    /// group in-app and serves as the trigger source for the (scaffolded) push
    /// Cloud Function.
    private func writeActivity(groupId: String, kind: String, message: String) async {
        guard let uid = currentUid else { return }
        // Queued, not awaited, so an offline device isn't held up waiting for a
        // server ack; Firestore keeps queued writes in order and syncs them later.
        db.collection("groups").document(groupId).collection("activity").addDocument(data: [
            "kind": kind,
            "message": message,
            "actorUid": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]) { [weak self] error in
            // Best-effort notification feed — never surface as a user-facing
            // error or block the primary write that triggered it.
            guard let error else { return }
            self?.logger.error("activity write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
