//
//  RoutineLiveActivity.swift
//  WhoZupWidgets
//
//  The habit routine on the lock screen and in the Dynamic Island after the
//  alarm is stopped: one step at a time with a single Done button, the step
//  count, the deadline, and a link into the full routine in the app.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WhoZupWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RoutineLiveActivity()
    }
}

private enum Palette {
    static let green = Color(red: 0.18, green: 0.65, blue: 0.49)
    static let amber = Color(red: 0.95, green: 0.76, blue: 0.48)
    static let track = Color.white.opacity(0.22)
}

struct RoutineLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RoutineActivityAttributes.self) { context in
            RoutineLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(RoutineLink.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.habitName, systemImage: "alarm")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.doneCount)/\(context.attributes.steps.count)")
                        .font(.caption.weight(.bold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StepRow(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.isComplete ? "checkmark.circle.fill" : "alarm")
                    .foregroundStyle(Palette.green)
            } compactTrailing: {
                Text("\(context.state.doneCount)/\(context.attributes.steps.count)")
                    .font(.caption2.weight(.bold))
            } minimal: {
                Text("\(context.state.doneCount)/\(context.attributes.steps.count)")
                    .font(.caption2.weight(.bold))
            }
            .widgetURL(RoutineLink.url)
        }
    }
}

private struct RoutineLockScreenView: View {
    let attributes: RoutineActivityAttributes
    let state: RoutineActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "alarm")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.25, green: 0.44, blue: 0.64)))
                Text("\(attributes.habitName) · \(attributes.groupName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                if !state.isComplete {
                    Text("by \(attributes.deadline, style: .time)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.amber)
                }
            }

            StepRow(attributes: attributes, state: state)

            HStack(spacing: 4) {
                ForEach(state.done.indices, id: \.self) { i in
                    Capsule().fill(state.tiny || state.done[i] ? Palette.green : Palette.track)
                        .frame(height: 5)
                }
            }

            HStack {
                Spacer()
                Link(destination: RoutineLink.url) {
                    Text("Open routine ›")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

/// The current step and its one button, or the finished state.
private struct StepRow: View {
    let attributes: RoutineActivityAttributes
    let state: RoutineActivityAttributes.ContentState

    var body: some View {
        if let next = state.nextIndex, !state.isComplete, attributes.steps.indices.contains(next) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("STEP \(next + 1) OF \(attributes.steps.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(attributes.steps[next])
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(intent: RoutineStepDoneIntent(groupId: attributes.groupId, step: next)) {
                    Label("Done", systemImage: "checkmark")
                        .font(.body.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.green)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.green)
                Text(state.tiny ? "Routine done · tiny version" : "Routine done · \(attributes.steps.count) of \(attributes.steps.count)")
                    .font(.headline)
            }
        }
    }
}
