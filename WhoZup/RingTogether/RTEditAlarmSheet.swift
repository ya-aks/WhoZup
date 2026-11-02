//
//  RTEditAlarmSheet.swift
//  WhoZup
//
//  Edit a group's wake-up time. For accountability groups each member edits
//  their own alarm; for shared groups only an admin edits the common time.
//  Saving writes to Firestore, which live-propagates to every member and each
//  device reschedules its local AlarmKit alarm (via RTAlarmSync).
//

import SwiftUI

struct RTEditAlarmSheet: View {
    let group: RTGroup

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var time: Date
    @State private var anchor: RTAlarmAnchor
    @State private var selectedDays: Set<Int>
    /// Whether the alarm repeats. Only offered on shared alarms; accountability
    /// alarms always repeat.
    @State private var repeats: Bool
    @State private var isWorking = false

    init(group: RTGroup) {
        self.group = group
        _time = State(initialValue: group.alarm.isEmpty ? Date() : RTAlarmTime.date(from: group.alarm))
        _anchor = State(initialValue: group.alarmAnchor)
        _selectedDays = State(initialValue: group.alarmDays.isEmpty ? Set(RTWeekday.all) : Set(group.alarmDays))
        _repeats = State(initialValue: !(group.type == .shared && group.alarmOnce))
    }

    private var isShared: Bool { group.type == .shared }

    /// A repeating alarm needs at least one day; a one-off doesn't.
    private var saveDisabled: Bool { isWorking || (repeats && selectedDays.isEmpty) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(isShared ? "Group alarm time" : "Your alarm time")
                    .font(.rtDisplay(20, .bold))
                    .foregroundStyle(RT.ink)
                    .padding(.top, 8)

                Text(isShared
                     ? "Changing this updates the alarm for everyone in \(group.name)."
                     : "Only your alarm changes. Your group is notified you updated it.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                DatePicker("Alarm", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    // Force a 12-hour AM/PM wheel regardless of the device's
                    // 24-hour setting — clearer for an alarm and consistent with
                    // how times are shown everywhere else.
                    .environment(\.locale, Locale(identifier: "en_US"))

                // Shared alarms can be a single one-off or repeat; accountability
                // alarms always repeat.
                if isShared {
                    Picker("Schedule", selection: $repeats) {
                        Text("Once").tag(false)
                        Text("Repeat").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                }

                if repeats {
                    daysPicker
                } else {
                    Text("Rings once, on the next \(RTAlarmTime.display(RTAlarmTime.string(from: time))).")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.horizontal, 20)
                }

                if isShared {
                    anchorPicker
                }

                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text("Save alarm")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(saveDisabled ? RT.inkFaint : group.type.accent))
                }
                .disabled(saveDisabled)
                .padding(.horizontal, 20)

                Spacer()
            }
            .padding(.top, 12)
            .background(RT.canvas)
            .navigationTitle("Edit alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// Which weekdays the alarm rings. All seven selected = every day.
    private var daysPicker: some View {
        VStack(spacing: 10) {
            Text("Repeat")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RT.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            RTWeekdayRow(selected: $selectedDays, accent: group.type.accent, badgeBackground: group.type.badgeBackground)
        }
        .padding(.horizontal, 20)
    }

    /// The stored form of the selection: `[]` when all seven days are on, so the
    /// "every day" default stays empty; otherwise the sorted selected days.
    private var normalizedDays: [Int] {
        selectedDays.count == RTWeekday.all.count ? [] : selectedDays.sorted()
    }

    /// Only meaningful when members span time zones, but shown always — an
    /// admin can't see where everyone is, and the choice has to be made before
    /// someone travels rather than after their alarm has already gone wrong.
    private var anchorPicker: some View {
        VStack(spacing: 6) {
            Picker("Across time zones", selection: $anchor) {
                ForEach(RTAlarmAnchor.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(anchor.explanation)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 20)
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        let timeString = RTAlarmTime.string(from: time)
        if isShared {
            await repository.setGroupAlarm(groupId: group.id, time: timeString, anchor: anchor,
                                           days: repeats ? normalizedDays : [], once: !repeats)
        } else {
            await repository.setMyAlarm(groupId: group.id, time: timeString, days: normalizedDays)
        }
        dismiss()
    }
}

/// A reusable weekday selector: seven letter toggles (S M T W T F S) plus
/// Every day / Weekdays / Weekends presets and a live summary. `selected` holds
/// `1=Sunday … 7=Saturday`; all seven selected reads as "every day".
struct RTWeekdayRow: View {
    @Binding var selected: Set<Int>
    let accent: Color
    let badgeBackground: Color

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(RTWeekday.all, id: \.self) { d in
                    let on = selected.contains(d)
                    Button {
                        if on { selected.remove(d) } else { selected.insert(d) }
                    } label: {
                        Text(RTWeekday.letter(d))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(on ? .white : RT.inkSecondary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(on ? accent : RT.card))
                            .overlay(Circle().stroke(RT.cardBorder, lineWidth: on ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                preset("Every day", RTWeekday.all)
                preset("Weekdays", RTWeekday.weekdays)
                preset("Weekends", RTWeekday.weekends)
                Spacer(minLength: 0)
            }

            Text(selected.isEmpty ? "Pick at least one day" : RTWeekday.summary(selected.count == RTWeekday.all.count ? [] : Array(selected)))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected.isEmpty ? RT.dotLate : accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func preset(_ title: String, _ days: [Int]) -> some View {
        let active = Set(days) == selected
        return Button { selected = Set(days) } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? accent : RT.inkMuted)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(active ? badgeBackground : RT.card))
                .overlay(Capsule().stroke(RT.cardBorder, lineWidth: active ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}
