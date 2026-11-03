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

/// Horizontal step bar: one segment per step, filled when done.
struct RTRoutineBar: View {
    let done: [Bool]
    var tiny: Bool = false
    var height: CGFloat = 6

    var body: some View {
        HStack(spacing: 3) {
            ForEach(done.indices, id: \.self) { i in
                Capsule()
                    .fill(tiny ? Color(hex: "#8fc4ae") : (done[i] ? RT.dotOnTime : Color(hex: "#e1d9c8")))
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(tiny ? "Routine done, tiny version" : "Routine \(done.filter { $0 }.count) of \(done.count)")
    }
}

/// "Today's routine" on the group screen, for your own habit.
struct RTTodayRoutineCard: View {
    let groupId: String
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
        let deadline = session?.deadline ?? routine?.deadline?.dateValue()
        let complete = session?.isComplete ?? routine?.isComplete ?? false
        let open = !complete && (deadline.map { now <= $0 } ?? false)

        VStack(alignment: .leading, spacing: 10) {
            if let done {
                HStack(spacing: 10) {
                    RTRoutineBar(done: done, tiny: tiny, height: 8)
                    Text(tiny ? "Tiny" : "\(done.filter { $0 }.count)/\(done.count)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(RT.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Today's routine")
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
                    Text(tiny ? "Done with the tiny version" : "Done — that's another rep")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RT.dotOnTime)
                } else if done != nil {
                    Text("Window closed for today")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                } else {
                    Text("Opens when you stop your \(RTAlarmTime.display(alarm)) alarm on the first ring")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }
            }
            if open, session != nil {
                Button { coordinator.presentRoutine = true } label: {
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
                    Text("Add a habit to my alarm")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(RT.ink)
                    Text(othersWithHabit > 0
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
            content(now: context.date)
        }
        .background(RT.canvas.ignoresSafeArea())
        // "Close · keep going later" must leave something to come back to.
        .onDisappear { Task { await coordinator.routineLeftOpen() } }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let s = coordinator.session, s.day == GroupRepository.dayKey(now) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ALARM STOPPED · ON TIME")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(RT.dotOnTime)
                    Text(s.isComplete ? "Routine done. That counts." : s.habit.name)
                        .font(.rtDisplay(28, .heavy))
                        .foregroundStyle(RT.ink)
                    Text(s.isComplete
                         ? "Every rep makes the next one more automatic."
                         : "\(s.groupName) · each step cues the next")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    RTRoutineBar(done: s.done, tiny: s.tiny, height: 10)
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

                if !s.isComplete, s.habit.hasTinyVersion, now <= s.deadline {
                    Button {
                        Task { await coordinator.useTinyVersion() }
                    } label: {
                        Text("Do the tiny version instead")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(RT.ink)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.dotIdle, lineWidth: 1))
                    }
                    .buttonStyle(RTPressStyle())
                }
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

    private func stepButton(_ step: HabitStep, index: Int, session s: RoutineSession, now: Date) -> some View {
        let done = s.tiny || s.done[index]
        return Button {
            Task { await coordinator.setStep(index, done: !s.done[index]) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 26))
                    .foregroundStyle(done ? RT.dotOnTime : RT.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(done ? Color(hex: "#1f5f48") : RT.ink)
                    if let tiny = step.tiny, !tiny.isEmpty {
                        Text("Tiny version: \(tiny)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RT.inkMuted)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 68)
            .background(RoundedRectangle(cornerRadius: 16).fill(done ? Color(hex: "#e3f1ec") : RT.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(done ? Color(hex: "#b9dccd") : RT.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(s.tiny || (now > s.deadline && !s.isComplete))
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
