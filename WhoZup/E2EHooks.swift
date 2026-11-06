//
//  E2EHooks.swift
//  WhoZup
//
//  DEBUG-only hooks the end-to-end suite (tools/e2e) uses to drive the real
//  alarm and habit code paths against the local Firebase emulator with mock
//  data. Never compiled into release builds. Each hook calls the same function
//  the UI or the system calls, then writes an "E2E:" line to the Routine log so
//  the runner can assert on it. Scenarios: docs/testing.md.
//
//  Launch environment (via SIMCTL_CHILD_*):
//    WHOZUP_E2E_EMAIL / WHOZUP_E2E_PASSWORD  sign in as this mock user
//    WHOZUP_E2E_SNOOZE=HH:mm                 Snooze that alarm first (E11)
//    WHOZUP_E2E_STOP=HH:mm                   Stop that alarm at launch, as the
//                                            Stop intent does on a cold launch
//    WHOZUP_E2E_CHECKIN=<groupId>:<wokeUp|snoozed>  answer the check-in card
//    WHOZUP_E2E_START=<groupId>              tap Start habit on Today's routine
//    WHOZUP_E2E_OPEN=<groupId>               tap Continue / Routine pending
//

#if DEBUG
import FirebaseAuth
import Foundation

@MainActor
enum E2EHooks {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var ranAfterLoad = false

    /// True when the runner launched the app for a test.
    static var active: Bool { env.keys.contains { $0.hasPrefix("WHOZUP_E2E_") } }

    /// At launch, before any UI or group data: sign in, then Stop if asked. The
    /// Stop runs immediately, exactly like `StopAlarmOpenIntent` on a cold
    /// launch, so it races the first alarm sync the same way.
    static func atLaunch() {
        guard active else { return }
        Task {
            FirebaseBootstrap.ensureConfigured()
            if let email = env["WHOZUP_E2E_EMAIL"], let password = env["WHOZUP_E2E_PASSWORD"],
               Auth.auth().currentUser?.email != email {
                try? Auth.auth().signOut()
                do {
                    _ = try await Auth.auth().signIn(withEmail: email, password: password)
                    RoutineLog.add("E2E: signed in \(email)")
                } catch {
                    RoutineLog.add("E2E: sign-in failed \(error.localizedDescription)")
                }
            }
            // Snooze this ring first (a minute ago), then the Stop below is a re-ring Stop (E11).
            if let time = env["WHOZUP_E2E_SNOOZE"] {
                RoutineLog.add("E2E: snooze \(time)")
                await AlarmActionHandler.capture(alarmID: RTAlarmSync.alarmID(forTime: time), kind: .snooze, at: Date().addingTimeInterval(-60))
            }
            if let time = env["WHOZUP_E2E_STOP"] {
                RoutineLog.add("E2E: stop \(time)")
                await AlarmActionHandler.capture(alarmID: RTAlarmSync.alarmID(forTime: time), kind: .dismiss, at: Date())
            }
        }
    }

    /// Once groups and member docs have loaded: the in-app actions.
    static func afterLoad(_ repository: GroupRepository) async {
        guard active, repository.alarmDataReady, !ranAfterLoad else { return }
        ranAfterLoad = true
        if let spec = env["WHOZUP_E2E_CHECKIN"] {
            let parts = spec.split(separator: ":").map(String.init)
            let gid = parts.first ?? ""
            let status: RTStatus = parts.last == "snoozed" ? .snoozed : .wokeUp
            if let pending = repository.pendingCheckIn(groupId: gid) {
                let (outcome, _) = await RoutineEntry.answerCheckIn(
                    repository: repository, groupId: gid, pending: pending, status: status)
                RoutineLog.add("E2E: checkin \(outcome.rawValue)")
            } else {
                RoutineLog.add("E2E: checkin none-pending")
            }
        }
        if let gid = env["WHOZUP_E2E_START"] {
            if let group = repository.group(id: gid), let me = group.roster.first(where: { $0.isYou }),
               let habit = group.alarmOnce ? me.checklist : me.habit {
                let started = await RoutineEntry.startFromCard(group: group, habit: habit)
                RoutineLog.add("E2E: start \(started ? "started" : "unavailable")")
            } else {
                RoutineLog.add("E2E: start no-habit")
            }
        }
        if let gid = env["WHOZUP_E2E_OPEN"], let group = repository.group(id: gid) {
            RoutineCoordinator.shared.open(group: group)
            let s = RoutineCoordinator.shared.session
            RoutineLog.add("E2E: open session=\(s?.groupId == gid ? "yes" : "no") done=\(s?.doneCount ?? -1)")
        }
        // Plans. createplan="<once|onceAlarm|repeat>|<start minutes from now>|<lead>|<days csv or ->|<alarm 1/0>|<flag minutes or ->"
        if let spec = env["WHOZUP_E2E_CREATEPLAN"] {
            let p = spec.split(separator: "|").map(String.init)
            if p.count == 6, let kind = RTPlanKind(rawValue: p[0]), let offset = Int(p[1]), let lead = Int(p[2]) {
                let start = Date().addingTimeInterval(TimeInterval(offset * 60))
                let startMinute = Calendar.current.date(bySetting: .second, value: 0, of: start) ?? start
                let days = p[3] == "-" ? [] : p[3].split(separator: ",").compactMap { Int($0) }
                let gid = await repository.createPlan(
                    kind: kind, name: "E2E \(kind.rawValue)", place: "", start: startMinute, days: days,
                    hasAlarm: p[4] == "1", alarmLeadMinutes: lead, flagNotUpMinutes: Int(p[5]),
                    attendanceDefault: "in", headcountAsks: [], weeklyLookahead: false)
                RoutineLog.add("E2E: createplan \(gid ?? "failed")")
            } else {
                RoutineLog.add("E2E: createplan bad-spec")
            }
        }
        // answer="<groupId>|<coming|running_late|skipping>|<dayKey or ->"
        if let spec = env["WHOZUP_E2E_ANSWER"] {
            let p = spec.split(separator: "|").map(String.init)
            if p.count == 3, let answer = RTSessionAnswer(rawValue: p[1]),
               let day = p[2] != "-" ? p[2] : repository.group(id: p[0])?.session?.dayKey {
                repository.setSessionAnswer(groupId: p[0], dayKey: day, answer: answer, eta: answer == .runningLate ? "+10" : nil)
                RoutineLog.add("E2E: answer \(p[1]) \(day)")
            } else {
                RoutineLog.add("E2E: answer no-session")
            }
        }
        // morning="<groupId>": the morning-of state from the live roster.
        if let gid = env["WHOZUP_E2E_MORNING"] {
            // Statuses and session answers arrive on their own listeners after the members.
            for _ in 0..<20 where repository.group(id: gid)?.roster.contains(where: { $0.status != .waiting }) != true {
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(1))
            if let group = repository.group(id: gid), let session = group.session, let alarmAt = session.alarmAt {
                let st = RTMorningOfCard.state(group: group, session: session, alarmAt: alarmAt, now: Date())
                let ids = { (m: [RTMember]) in m.map(\.uid).sorted().joined(separator: ",") }
                RoutineLog.add("E2E: morning expected=\(ids(st.expected)) up=\(ids(st.up)) flagged=\(ids(st.flagged))")
            } else {
                RoutineLog.add("E2E: morning no-session")
            }
        }
        RoutineLog.add("E2E: done")
    }
}
#endif
