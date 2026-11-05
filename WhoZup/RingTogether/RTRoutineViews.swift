//
//  RTRoutineViews.swift
//  WhoZup
//
//  The habit routine in the app: the full-screen checklist (opened from the
//  lock-screen card, the "Start your routine" notification, or a Stop that
//  opens the app when Live Activities are off), the group screen's
//  "Today's routine" card, the add-a-habit card, and the step bar.
//

import FirebaseCore
import FirebaseFirestore
import SwiftUI

extension RT {
    /// A routine step still to do while the window is open.
    static let stepTodo = Color(hex: "#e1d9c8")
    /// A routine step left undone after the window closed: a pale late-red.
    static let stepMissed = Color(hex: "#f0c9c0")
    /// Text for a routine that closed unfinished.
    static let stepMissedText = Color(hex: "#a83f2e")
    static let stepTiny = Color(hex: "#8fc4ae")
}

/// Horizontal step bar: one segment per step, filled when done.
struct RTRoutineBar: View {
    let done: [Bool]
    var tiny: Bool = false
    /// Steps done with their tiny version, shown lighter.
    var tinySteps: [Bool]? = nil
    /// The window closed: undone steps show as missed instead of to-do.
    var missed: Bool = false
    var height: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            ForEach(done.indices, id: \.self) { i in
                Capsule()
                    .fill(tiny || (done[i] && tinySteps?.indices.contains(i) == true && tinySteps![i])
                          ? RT.stepTiny : (done[i] ? RT.dotOnTime : (missed ? RT.stepMissed : RT.stepTodo)))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(tiny ? "Routine done, tiny version"
                            : "Routine \(done.filter { $0 }.count) of \(done.count)\(missed ? ", rest missed" : "")")
    }
}

/// "Today's routine" on the group screen, for your own habit.
struct RTTodayRoutineCard: View {
    let group: RTGroup
    private var groupId: String { group.id }
    let habit: MemberHabit
    /// Today's routine as synced (from your status doc), if it started.
    let routine: RoutineProgress?
    let alarm: String

    private var coordinator: RoutineCoordinator { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(now: context.date)
        }
    }

    @ViewBuilder private func card(now: Date) -> some View {
        // The local session is freshest; fall back to the synced copy.
        let session = coordinator.session.flatMap { $0.groupId == groupId && $0.day == GroupRepository.dayKey(now) ? $0 : nil }
        let done = session?.done ?? routine?.done
        let tiny = session?.tiny ?? routine?.tiny ?? false
        let tinySteps = session?.tinySteps ?? routine?.tinySteps
        let deadline = session?.deadline ?? routine?.deadline?.dateValue()
        let complete = session?.isComplete ?? routine?.isComplete ?? false
        let open = !complete && (deadline.map { now <= $0 } ?? false)

        VStack(alignment: .leading, spacing: 10) {
            if let done {
                HStack(spacing: 10) {
                    RTRoutineBar(done: done, tiny: tiny, tinySteps: tinySteps, missed: !complete && !open, height: 8)
                    Text(tiny ? "Tiny" : "\(done.filter { $0 }.count)/\(done.count)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(RT.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.checklist ? "Today's checklist" : "Today's routine")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(RT.ink)
                if let done, open, let next = done.firstIndex(of: false), habit.steps.indices.contains(next) {
                    Text("Next: \(habit.steps[next].title)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                    if let deadline {
                        Text("\(max(0, Int(deadline.timeIntervalSince(now) / 60))) min left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RTStatus.snoozed.chipColor)
                    }
                } else if complete {
                    Text(habit.checklist ? "All done" : (tiny ? "Done with the tiny version" : "Done — that's another rep"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RT.dotOnTime)
                } else if let done {
                    let left = done.filter { !$0 }.count
                    Text("Window closed · \(left) step\(left == 1 ? "" : "s") missed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RT.stepMissedText)
                } else {
                    Text(habit.checklist
                         ? "Opens when you stop your \(RTAlarmTime.display(alarm)) alarm"
                         : "Opens when you stop your \(RTAlarmTime.display(alarm)) alarm on the first ring")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }
            }
            // Open here or synced from your other device: either way it can be
            // finished from this phone while there's time left.
            if open, session != nil || routine?.isOpen(now: now) == true {
                Button { coordinator.open(group: group, now: Date()) } label: {
                    Text("Continue")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(RT.dotOnTime))
                }
                .buttonStyle(RTPressStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "#b9dccd"), lineWidth: 1.5))
    }
}

/// Offered on a Check-ins group when you haven't built a habit there.
struct RTAddHabitCard: View {
    let othersWithHabit: Int
    let memberCount: Int
    /// Your alarm rings once: offer a one-off checklist instead of a habit.
    var checklist: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(RT.dotOnTime)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#e3f3ec")))
                VStack(alignment: .leading, spacing: 2) {
                    Text(checklist ? "Add a checklist to this alarm" : "Add a habit to my alarm")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(RT.ink)
                    Text(checklist
                         ? "Optional · up to \(MemberHabit.maxChecklistItems) things to do after it rings"
                         : othersWithHabit > 0
                         ? "Optional · \(othersWithHabit) of \(memberCount) in this group already do"
                         : "Optional · a small routine right after you wake")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Color(hex: "#b9dccd"))
            )
        }
        .buttonStyle(RTPressStyle())
    }
}

/// The full routine checklist.
struct RTRoutineView: View {
    @Environment(\.dismiss) private var dismiss
    private var coordinator: RoutineCoordinator { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let close = closeKey(now: context.date)
            content(now: context.date)
                // Finished, or time ran out: show the result for a moment, then
                // close by itself — no "Done" tap on an empty checklist.
                .task(id: close) {
                    guard close != 0 else { return }
                    try? await Task.sleep(for: .seconds(close == 1 ? 1.6 : 2.5))
                    if close == 2 { coordinator.expireIfNeeded() }
                    dismiss()
                }
        }
        .background(RT.canvas.ignoresSafeArea())
        // "Close · keep going later" must leave something to come back to.
        .onDisappear { Task { await coordinator.routineLeftOpen() } }
    }

    /// 0 while there's work to do, 1 once finished, 2 once the window closed.
    private func closeKey(now: Date) -> Int {
        guard let s = coordinator.session else { return 0 }
        if s.isComplete { return 1 }
        return now > s.deadline ? 2 : 0
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let s = coordinator.session, s.day == GroupRepository.dayKey(now) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.habit.checklist ? "ALARM STOPPED · CHECKLIST" : "ALARM STOPPED · ON TIME")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(RT.dotOnTime)
                    Text(s.isComplete ? (s.habit.checklist ? "All done. Nice." : "Routine done. That counts.") : s.habit.name)
                        .font(.rtDisplay(28, .heavy))
                        .foregroundStyle(RT.ink)
                    Text(s.isComplete
                         ? (s.habit.checklist ? "Everything on your list is checked off." : "Every rep makes the next one more automatic.")
                         : "\(s.groupName) · \(s.habit.checklist ? "one at a time, in order" : "each step cues the next")")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    RTRoutineBar(done: s.done, tiny: s.tiny, tinySteps: s.tinySteps, missed: !s.isComplete && now > s.deadline, height: 10)
                    HStack {
                        Text(s.tiny ? "Tiny version" : "\(s.doneCount) of \(s.done.count) done")
                        Spacer()
                        if !s.isComplete {
                            Text(now <= s.deadline
                                 ? "\(max(0, Int(s.deadline.timeIntervalSince(now) / 60))) min left"
                                 : "Window closed")
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                }

                VStack(spacing: 10) {
                    ForEach(Array(s.habit.steps.enumerated()), id: \.offset) { index, step in
                        stepButton(step, index: index, session: s, now: now)
                    }
                }

                Spacer()

                Button { dismiss() } label: {
                    Text(s.isComplete ? "Done" : "Close · keep going later")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(RoundedRectangle(cornerRadius: 16).fill(s.isComplete ? RT.dotOnTime : RT.ink))
                }
                .buttonStyle(RTPressStyle())
            }
            .padding(20)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Text("No routine running")
                    .font(.rtDisplay(22, .bold))
                    .foregroundStyle(RT.ink)
                Text("Your routine opens when you stop your alarm on the first ring.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .multilineTextAlignment(.center)
                Spacer()
                Button("Close") { dismiss() }
                    .font(.system(size: 16, weight: .bold))
            }
            .padding(24)
        }
    }

    /// One step. Steps go in order and stay done: only the next step can be
    /// marked; done steps are locked as done; later steps wait their turn.
    /// A step with a tiny version offers both: the full step, or the tiny one.
    @ViewBuilder
    private func stepButton(_ step: HabitStep, index: Int, session s: RoutineSession, now: Date) -> some View {
        let done = s.tiny || s.done[index]
        let didTiny = s.tiny || (done && (s.tinySteps?.indices.contains(index) == true && s.tinySteps![index]))
        let isNext = !done && index == s.nextIndex && s.isOpen(now: now)
        let waiting = !done && !isNext
        let tinyText = (step.tiny ?? "").isEmpty ? nil : step.tiny

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: done ? "checkmark.square.fill" : (waiting ? "lock.fill" : "square"))
                    .font(.system(size: waiting ? 18 : 26))
                    .foregroundStyle(done ? (didTiny ? Color(hex: "#5aa587") : RT.dotOnTime) : (isNext ? RT.ink : RT.inkFaint))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(done ? Color(hex: "#1f5f48") : (waiting ? RT.inkFaint : RT.ink))
                    if done, didTiny, let tinyText {
                        Text("Did the tiny version: \(tinyText)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: "#3d7a62"))
                    } else if waiting, index > 0, s.isOpen(now: now) {
                        Text("After step \(index)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RT.inkFaint)
                    } else if isNext, let tinyText {
                        Text("Tiny version: \(tinyText)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RT.inkMuted)
                    }
                }
                Spacer()
            }
            if isNext {
                HStack(spacing: 10) {
                    Button { Task { await coordinator.completeStep(index) } } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(RT.dotOnTime))
                    }
                    .buttonStyle(RTPressStyle())
                    if tinyText != nil {
                        Button { Task { await coordinator.completeStep(index, tiny: true) } } label: {
                            Text("Did tiny version")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(RT.dotOnTime)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#e3f3ec")))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#b9dccd"), lineWidth: 1))
                        }
                        .buttonStyle(RTPressStyle())
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(done ? Color(hex: "#e3f1ec") : RT.card))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(done ? Color(hex: "#b9dccd") : (isNext ? RT.dotOnTime : RT.cardBorder), lineWidth: isNext ? 1.5 : 1)
        )
        .opacity(waiting ? 0.7 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityValue(done ? (didTiny ? "Done, tiny version" : "Done") : (isNext ? "Next step" : "Not yet"))
    }
}

#if DEBUG
/// What the routine did on this phone, for diagnosing a card that doesn't show.
struct RTRoutineLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = RoutineLog.read()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "Nothing logged yet. Stop an alarm that has a habit, then come back." : text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Routine log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear", role: .destructive) { RoutineLog.clear(); text = "" }
                }
            }
        }
    }
}
#endif
