//
//  RTYourHabitSection.swift
//  WhoZup
//
//  "Your habit" on a Check-ins group detail: what the routine is (name,
//  numbered steps with tiny versions, window, visibility), kept separate from
//  the alarm hero and from today's status further down.
//

import SwiftUI

struct RTYourHabitSection: View {
    let habit: MemberHabit
    /// Stored "HH:mm" alarm, shown as "6:30 AM" in the footer.
    let alarm: String
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your habit")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(RT.ink)
                Spacer()
                Button(action: onEdit) {
                    Label("Edit habit", systemImage: "pencil")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(RT.dotOnTime)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RTPressStyle())
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(habit.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(RT.ink)
                    Spacer(minLength: 8)
                    Text("Finish within \(habit.windowMinutes) min")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RT.inkSecondary)
                }

                ForEach(Array(habit.steps.enumerated()), id: \.offset) { index, step in
                    stepRow(number: index + 1, step: step)
                }

                Text(footer)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(RT.cardBorder, lineWidth: 1))
        }
    }

    private func stepRow(number: Int, step: HabitStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "#1f7a5c"))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(hex: "#e3f3ec")))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RT.ink)
                if let tiny = step.tiny, !tiny.isEmpty {
                    Text("Tiny version: \(tiny)")
                        .font(.system(size: 12))
                        .foregroundStyle(RT.inkSecondary)
                }
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number): \(step.title)"
            + ((step.tiny?.isEmpty == false) ? ". Tiny version: \(step.tiny!)" : "")))
    }

    private var footer: String {
        let visibility = habit.showSteps
            ? "step names visible to the group"
            : "the group sees only how many steps are done"
        return "Opens when you stop your \(RTAlarmTime.display(alarm)) alarm on the first ring · \(visibility)"
    }
}
