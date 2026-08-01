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
    private(set) var lastError: String?

    /// Lifetime count of events this user has *created* — the basis for the
    /// free-event quota. Monotonic: deleting an event never refunds it, and
    /// events you merely joined don't count. 0 until the usage doc loads.
    private(set) var eventsCreatedCount = 0
    private(set) var eventPackBalance = 0

    var canCreateEvent: Bool {
        eventsCreatedCount < 5 || eventPackBalance > 0
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

    // Usage-doc bookkeeping, for seeding the events-created counter once for
    // users who already hosted events before the counter existed.
    private var usageLoaded = false
    private var usageDocExists = false
    private var seedingUsage = false

    // Raw live data keyed by groupId.
    private var rawGroups: [String: FirestoreGroup] = [:]
    private var members: [String: [GroupMemberDoc]] = [:]
    private var statuses: [String: [MemberStatusDoc]] = [:]

    // Our own member doc for a group we just created, kept until the members
    // listener delivers it. A freshly-created group's members listener can miss
    // the creator's just-written doc for the rest of the session, which would
    // otherwise leave our own alarm blank until an app restart.
    private var pendingOwnMember: [String: GroupMemberDoc] = [:]

    // MARK: - Lifecycle

    /// Begins listening for the given user's groups. Safe to call again with a
    /// new uid (e.g. after re-auth) — it resets first.
    func start(uid: String, displayName: String) {
        if currentUid == uid { currentDisplayName = displayName; return }
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
                    self.seedUsageIfNeeded()
                }
            }
    }

    func stop() {
        groupsListener?.remove(); groupsListener = nil
        usageListener?.remove(); usageListener = nil
        memberListeners.values.forEach { $0.remove() }; memberListeners.removeAll()
        statusListeners.values.forEach { $0.remove() }; statusListeners.removeAll()
        rawGroups.removeAll(); members.removeAll(); statuses.removeAll(); pendingOwnMember.removeAll()
        groups = []
        eventsCreatedCount = 0
        eventPackBalance = 0
        usageLoaded = false; usageDocExists = false; seedingUsage = false
        currentUid = nil
    }

    /// One-time backfill: a user who hosted events before the counter existed
    /// has no usage doc, so seed it with their current hosted-event count the
    /// first time we see it's missing. After that it only ever increments.
    private func seedUsageIfNeeded() {
        guard usageLoaded, !usageDocExists, !seedingUsage, let uid = currentUid else { return }
        let hosted = groups.filter { $0.type == .event && $0.hostedByCurrentUser }.count
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

        let decoded = snapshot.documents.compactMap { try? $0.data(as: FirestoreGroup.self) }
        let liveIDs = Set(decoded.compactMap(\.id))

        // Drop listeners for groups we're no longer in.
        for goneID in Set(rawGroups.keys).subtracting(liveIDs) {
            memberListeners[goneID]?.remove(); memberListeners[goneID] = nil
            statusListeners[goneID]?.remove(); statusListeners[goneID] = nil
            rawGroups[goneID] = nil; members[goneID] = nil; statuses[goneID] = nil
        }

        for group in decoded {
            guard let gid = group.id else { continue }
            rawGroups[gid] = group
            attachSubListeners(groupId: gid)
        }
        rebuild()
    }

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
                        self.rebuild()
                    }
                }
        }
        if statusListeners[gid] == nil {
            statusListeners[gid] = db.collection("groups").document(gid).collection("statuses")
                .addSnapshotListener { [weak self] snap, _ in
                    Task { @MainActor in
                        self?.statuses[gid] = snap?.documents.compactMap { try? $0.data(as: MemberStatusDoc.self) } ?? []
                        self?.rebuild()
                    }
                }
        }
    }

    /// Rebuilds the `RTGroup` list from raw docs + members + statuses.
    private func rebuild() {
        guard let uid = currentUid else { groups = []; return }
        groups = rawGroups.values
            .sorted { ($0.createdAt?.dateValue() ?? .distantPast) < ($1.createdAt?.dateValue() ?? .distantPast) }
            .compactMap { buildRTGroup($0, uid: uid) }
        seedUsageIfNeeded()
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

        func memberFor(_ memberUid: String) -> RTMember {
            let doc = memberDocs.first { $0.id == memberUid }
            let statusDoc = statusDocs.first { $0.id == memberUid }
            let isYou = memberUid == uid
            let status: RTStatus = statusDoc.map { RTStatus(storageKey: $0.status) }
                ?? (type == .event ? .noResponse : .waiting)
            let initials = doc?.initials ?? String((doc?.displayName ?? "?").prefix(1)).uppercased()
            let colorHex = doc?.avatarColorHex ?? RTAvatarPalette.hex(for: memberUid)
            let baseDetail = statusDoc?.detail ?? (type == .event ? "hasn't replied" : "no update yet")
            // For accountability, prepend the member's own alarm time.
            let detail: String
            if type == .accountability, let a = doc?.alarmTime, !a.isEmpty {
                detail = "\(a) AM · \(baseDetail)"
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
                alarm: doc?.alarmTime
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
                date: g.eventAt?.dateValue()
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
        let days = (type == .accountability
            ? memberDocs.first { $0.id == uid }?.alarmDays
            : g.alarmDays) ?? []

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
            alarmOnce: type == .shared && (g.alarmOnce ?? false)
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
        eventAt: Date? = nil
    ) async -> String? {
        guard let uid = currentUid else { return nil }
        if type == .event && !canCreateEvent {
            lastError = "Free event limit reached (5/5). Please purchase an Event Pack (+20 events for $10) to create more events."
            return nil
        }
        let code = Self.makeInviteCode()
        let groupRef = db.collection("groups").document()

        var payload: [String: Any] = [
            "type": type.rawValue,
            "name": name,
            "adminUids": [uid],
            "memberUids": [uid],
            "inviteCode": code,
            "createdBy": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        // For shared groups the alarm lives on the group; for accountability the
        // creator's own alarm lives on their member doc (written below).
        if type == .shared, let alarmTime {
            payload["alarmTime"] = alarmTime
            payload["alarmTimeZone"] = TimeZone.current.identifier
            payload["alarmAnchor"] = alarmAnchor.rawValue
            payload["alarmOnce"] = alarmOnce
            if !alarmDays.isEmpty { payload["alarmDays"] = alarmDays.sorted() }
        }
        if let eventTitle { payload["eventTitle"] = eventTitle }
        if let eventPlace { payload["eventPlace"] = eventPlace }
        if let eventAt { payload["eventAt"] = Timestamp(date: eventAt) }
        if type != .event { payload["lateThresholdMinutes"] = 15 }

        do {
            try await groupRef.setData(payload)
            let ownAlarm = type == .accountability ? alarmTime : nil
            let ownDays = type == .accountability ? alarmDays : []
            try await writeMyMemberDoc(
                groupId: groupRef.documentID, uid: uid, role: "admin",
                alarmTime: ownAlarm, alarmDays: ownDays
            )
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
                alarmDays: ownDays.isEmpty ? nil : ownDays.sorted()
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
            if type == .event {
                try? await db.collection("usage").document(uid)
                    .setData(["eventsCreated": FieldValue.increment(Int64(1))], merge: true)
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

    /// Sets the current member's own alarm (accountability) and notes it in the
    /// activity feed so the whole group is informed.
    func setMyAlarm(groupId: String, time: String, days: [Int] = []) async {
        guard let uid = currentUid else { return }
        do {
            try await db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .setData(["alarmTime": time, "alarmDays": days.sorted()], merge: true)
            await writeActivity(groupId: groupId, kind: "alarm_changed",
                                message: "\(currentDisplayName) set their alarm to \(time) AM")
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
        let fields: [String: Any] = [
            "alarmTime": time,
            "alarmTimeZone": TimeZone.current.identifier,
            "alarmAnchor": anchor.rawValue,
            "alarmDays": days.sorted(),
            "alarmOnce": once,
        ]
        do {
            try await db.collection("groups").document(groupId).updateData(fields)
            await refreshInvitePreview(groupId: groupId, fields: fields)
            await writeActivity(groupId: groupId, kind: "alarm_changed",
                                message: "\(currentDisplayName) changed the wake-up to \(time) AM")
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
    /// Returns whether the write succeeded.
    @discardableResult
    func setMyStatus(groupId: String, status: RTStatus, detail: String, eta: String? = nil, activity: String? = nil) async -> Bool {
        guard let uid = currentUid else {
            lastError = "You're not signed in."
            return false
        }
        var payload: [String: Any] = [
            "status": status.storageKey,
            "detail": detail,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let eta { payload["eta"] = eta }
        do {
            try await db.collection("groups").document(groupId)
                .collection("statuses").document(uid).setData(payload)
            lastError = nil
            await recordHistory(groupId: groupId, uid: uid, status: status, detail: detail)
            if let activity {
                await writeActivity(groupId: groupId, kind: "response", message: activity)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Appends today's alarm outcome to the member's per-day history, which
    /// backs the accountability dashboard. Only real wake-up outcomes are kept —
    /// event RSVPs and the neutral "waiting" state aren't accountability data.
    /// Best-effort: a missed history write must never fail the status update.
    private func recordHistory(groupId: String, uid: String, status: RTStatus, detail: String) async {
        guard [.wokeUp, .snoozed, .silentLate].contains(status) else { return }
        let day = Self.dayKey()
        do {
            try await db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .collection("history").document(day)
                .setData([
                    "status": status.storageKey,
                    "detail": detail,
                    "date": day,
                    "updatedAt": FieldValue.serverTimestamp(),
                ], merge: true)
        } catch {
            logger.error("history write failed: \(error.localizedDescription, privacy: .public)")
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
    func fetchDayOutcomes(groupId: String, day: String) async -> [String: RTStatus] {
        guard let g = rawGroups[groupId] else { return [:] }
        var result: [String: RTStatus] = [:]
        for uid in g.memberUids {
            if let snap = try? await db.collection("groups").document(groupId)
                .collection("members").document(uid)
                .collection("history").document(day).getDocument(),
               let s = snap.data()?["status"] as? String {
                result[uid] = RTStatus(storageKey: s)
            }
        }
        return result
    }

    /// Each member's outcomes across a month (uid → [dayKey → status]), for the
    /// dashboard's month view. `monthPrefix` is "yyyy-MM".
    func fetchMonthOutcomes(groupId: String, monthPrefix: String) async -> [String: [String: RTStatus]] {
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
                }
                result[uid] = days
            }
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

    func group(id: String) -> RTGroup? { groups.first { $0.id == id } }

    func groups(of type: RTGroupType) -> [RTGroup] { groups.filter { $0.type == type } }

    func inviteCode(for groupId: String) -> String? { rawGroups[groupId]?.inviteCode }

    // MARK: - Alarm bridge

    /// Maps a scheduled AlarmKit alarm's UUID to every group it covers, so a
    /// real dismiss/snooze on that alarm can be persisted to Firestore.
    ///
    /// One-to-many because groups sharing a wake-up time share a single alarm
    /// (see `RTAlarmSync`): dismissing 06:30 once means you woke up for every
    /// 06:30 group at the same moment.
    private var alarmGroupMap: [UUID: [String]] = [:]

    /// Wires an `AlarmStatusRecorder` so real alarm actions write the derived
    /// status to every group behind that alarm. Call once at app start.
    func bindAlarmRecorder(_ recorder: AlarmStatusRecorder) {
        recorder.onRecorded = { [weak self] alarmID, result in
            guard let self, let groupIds = self.alarmGroupMap[alarmID], !groupIds.isEmpty else { return }
            let rt = Self.rtStatus(from: result.status)
            // Computed once so every group records the same wake-up time rather
            // than drifting by however long the writes take.
            let detail = Self.detail(for: rt)
            Task {
                for groupId in groupIds {
                    await self.setMyStatus(groupId: groupId, status: rt, detail: detail)
                }
            }
        }
    }

    /// Associates an alarm UUID with every group it covers, before scheduling it.
    func registerAlarm(alarmID: UUID, groupIds: [String]) {
        alarmGroupMap[alarmID] = groupIds
    }

    /// Forgets an alarm's group mapping. Call when cancelling it, so a reused
    /// or stale UUID can't write a status to groups it no longer covers.
    func unregisterAlarm(alarmID: UUID) {
        alarmGroupMap[alarmID] = nil
    }

    static func rtStatus(from status: MemberStatus) -> RTStatus {
        switch status {
        case .respondedOnTime: return .wokeUp
        case .snoozed: return .snoozed
        case .silentLate: return .silentLate
        case .pending: return .waiting
        }
    }

    static func detail(for status: RTStatus) -> String {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        switch status {
        case .wokeUp: return "up at \(time)"
        case .snoozed: return "snoozed"
        case .silentLate: return "no dismiss or snooze"
        default: return ""
        }
    }

    // MARK: - Helpers

    private func writeMyMemberDoc(groupId: String, uid: String, role: String, alarmTime: String? = nil, alarmDays: [Int] = []) async throws {
        let initials = String(currentDisplayName.prefix(1)).uppercased()
        var data: [String: Any] = [
            "displayName": currentDisplayName,
            "initials": initials.isEmpty ? "?" : initials,
            "avatarColorHex": RTAvatarPalette.hex(for: uid),
            "role": role,
        ]
        if let alarmTime { data["alarmTime"] = alarmTime }
        if !alarmDays.isEmpty { data["alarmDays"] = alarmDays.sorted() }
        try await db.collection("groups").document(groupId)
            .collection("members").document(uid).setData(data, merge: true)
    }

    /// Appends an entry to the group's activity feed. This both informs the
    /// group in-app and serves as the trigger source for the (scaffolded) push
    /// Cloud Function.
    private func writeActivity(groupId: String, kind: String, message: String) async {
        guard let uid = currentUid else { return }
        do {
            try await db.collection("groups").document(groupId).collection("activity").addDocument(data: [
                "kind": kind,
                "message": message,
                "actorUid": uid,
                "createdAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            // Best-effort notification feed — never surface as a user-facing
            // error or block the primary write that triggered it.
            logger.error("activity write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
