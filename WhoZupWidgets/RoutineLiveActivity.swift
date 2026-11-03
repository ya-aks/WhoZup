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

/// The WhoZup app icon, clipped to an app-icon-style rounded square.
private struct AppIconBadge: View {
    var size: CGFloat

    var body: some View {
        Image("WhoZupIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
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
                    HStack(spacing: 6) {
                        AppIconBadge(size: 20)
                        Text(context.attributes.habitName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 8)
                    .padding(.leading, 6)
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.doneCount)/\(context.attributes.steps.count)")
                        .font(.caption.weight(.bold))
                        .padding(.top, 8)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StepRow(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                AppIconBadge(size: 20)
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
                AppIconBadge(size: 22)
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
            .padding(.top, 4)

            StepRow(attributes: attributes, state: state)

            HStack(spacing: 4) {
                ForEach(state.done.indices, id: \.self) { i in
                    Capsule().fill(state.done[i] || state.tiny
                                   ? (state.isTiny(i) ? Palette.green.opacity(0.55) : Palette.green)
                                   : Palette.track)
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
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
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
                // A step with a tiny version can be marked either way.
                if attributes.tinyVersion(of: next) != nil {
                    Button(intent: RoutineStepDoneIntent(groupId: attributes.groupId, step: next, tiny: true)) {
                        Text("Tiny")
                            .font(.callout.weight(.bold))
                            .padding(.horizontal, 6)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.green)
                }
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
