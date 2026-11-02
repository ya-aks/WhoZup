//
//  RTCreateGroupSheet.swift
//  WhoZup
//
//  The redesigned "New group" screen (used by all three tabs). Collects the
//  group name and — for accountability/shared groups — a wake-up time via a
//  custom stepper, or — for events — a date & time. "Next · Add members"
//  creates the group and opens the Add-members screen.
//

import SwiftUI

struct RTCreateGroupSheet: View {
    let type: RTGroupType

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var detailedDescription = ""
    @State private var alarmTime = Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: Date()) ?? Date()
    // Defaults to local time: for a wake-up alarm "06:30" almost always means
    // 06:30 in your own morning, and getting that wrong wakes someone at 1 AM.
    // Same-moment is the deliberate choice, not the accident.
    @State private var alarmAnchor: RTAlarmAnchor = .localTime
    @State private var selectedDays: Set<Int> = Set(RTWeekday.all)
    /// Shared alarms can be a single one-off; accountability always repeats.
    @State private var repeats = true
    @State private var eventTitle = ""
    @State private var eventPlace = ""
    @State private var eventAt = Calendar.current.date(byAdding: .hour, value: 3, to: Date()) ?? Date()
    @State private var hasEndTime = true
    @State private var eventEndAt = Calendar.current.date(byAdding: .hour, value: 5, to: Date()) ?? Date()
    @State private var isWorking = false
    @State private var createdCode: String?
    /// Check-ins only: build a personal habit with your alarm.
    @State private var buildHabit = false
    @State private var habitDraft = RTHabitDraft()
    @State private var showAddMembers = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RT.inkMuted)
                    Spacer()
                    RTBadge(text: badgeLabel, color: type.eyebrow, background: type.badgeBackground)
                }

                Text("New group")
                    .font(.rtDisplay(28, .bold))
                    .foregroundStyle(RT.ink)
                    .padding(.top, 20)

                Text(type.blurb)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
                    .padding(.top, 4)

                fieldLabel("Group name")
                styledField(placeholder: namePlaceholder, text: $name)

                fieldLabel("Description (optional)")
                styledField(placeholder: "e.g. Purpose of the group, rules, or details", text: $detailedDescription)

                switch type {
                case .accountability, .shared:
                    fieldLabel(type == .accountability ? "Your alarm time" : "Group alarm time")
                    wheelTime($alarmTime)
                    if type == .shared {
                        fieldLabel("Schedule")
                        Picker("Schedule", selection: $repeats) {
                            Text("Once").tag(false)
                            Text("Repeat").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    if repeats {
                        fieldLabel("Repeat")
                        RTWeekdayRow(selected: $selectedDays, accent: type.accent, badgeBackground: type.badgeBackground)
                    } else {
                        Text("Rings once, on the next \(RTAlarmTime.display(RTAlarmTime.string(from: alarmTime))).")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RT.inkMuted)
                            .padding(.top, 8)
                    }
                    if type == .accountability {
                        habitCard.padding(.top, 26)
                    }
                    // Only shared groups have a common time to interpret; an
                    // accountability alarm is always the member's own local one.
                    if type == .shared {
                        fieldLabel("Across time zones")
                        Picker("Across time zones", selection: $alarmAnchor) {
                            ForEach(RTAlarmAnchor.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(alarmAnchor.explanation)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(RT.inkMuted)
                            .padding(.top, 2)
                    }
                case .event:
                    fieldLabel("What's happening")
                    styledField(placeholder: "e.g. Trivia night", text: $eventTitle)
                    fieldLabel("Where")
                    styledField(placeholder: "e.g. The Anchor Pub", text: $eventPlace)

                    fieldLabel("Event date")
                    HStack {
                        Text("On")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RT.inkSecondary)
                        Spacer()
                        DatePicker("", selection: $eventAt, in: Date()..., displayedComponents: .date)
                            .labelsHidden()
                            .tint(type.accent)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))

                    fieldLabel("Event time")
                    wheelTime($eventAt)

                    fieldLabel("Ends")
                    VStack(spacing: 0) {
                        Toggle(isOn: $hasEndTime) {
                            Text("Set an end time")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(RT.inkSecondary)
                        }
                        .tint(type.accent)
                        .onChange(of: eventAt) { _, newStart in
                            if eventEndAt <= newStart {
                                eventEndAt = Calendar.current.date(byAdding: .hour, value: 2, to: newStart) ?? newStart
                            }
                        }
                        if hasEndTime {
                            Divider().padding(.vertical, 12)
                            HStack {
                                Text("On")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(RT.inkSecondary)
                                Spacer()
                                DatePicker("", selection: $eventEndAt, in: eventAt..., displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                                    .tint(type.accent)
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
                }

                if let error = repository.lastError {
                    Text(error)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.top, 14)
                }

                Button {
                    Task { await createAndContinue() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text("Next · Add members")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(type.accent))
                }
                .buttonStyle(RTPressStyle())
                .disabled(!canCreate || isWorking)
                .opacity(canCreate ? 1 : 0.5)
                .padding(.top, 26)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 30)
        }
        .background(RT.canvas)
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showAddMembers, onDismiss: { dismiss() }) {
            if let code = createdCode {
                RTAddMembersView(code: code, groupName: name, accent: type.accent)
            }
        }
    }

    // MARK: - Pieces

    /// "Build a habit with my alarm" — optional and personal.
    private var habitCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $buildHabit.animation()) {
                HStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 11).fill(RT.dotOnTime))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Build a habit with my alarm")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(RT.ink)
                        Text("Just for you · others in the group choose for themselves")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color(hex: "#4a6b5e"))
                    }
                }
            }
            .tint(RT.dotOnTime)
            .padding(16)
            .background(Color(hex: "#e3f3ec"))

            if buildHabit {
                RTHabitFields(draft: $habitDraft)
                    .padding(16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: "#b9dccd"), lineWidth: 1.5))
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(RT.inkSecondary)
            .padding(.top, 26)
            .padding(.bottom, 10)
    }

    /// The native wheel time picker — a smooth, fast scroll, replacing the old
    /// +/- stepper. Clipped into the card style so it matches the fields.
    private func wheelTime(_ binding: Binding<Date>) -> some View {
        DatePicker("", selection: binding, displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            // Force a 12-hour AM/PM wheel regardless of the device's 24-hour
            // setting — clearer for an alarm and consistent with everywhere else.
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(maxWidth: .infinity)
            .tint(type.accent)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 22).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(RT.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func styledField(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(RT.ink)
            .tint(type.accent)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
    }

    private var badgeLabel: String {
        switch type {
        case .accountability: return "Check-ins"
        case .shared: return "In Sync"
        case .event: return "Event"
        }
    }

    private var namePlaceholder: String {
        switch type {
        case .accountability: return "e.g. Med School Crew"
        case .shared: return "e.g. Sunrise Runners"
        case .event: return "e.g. Trivia Night"
        }
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if type == .event {
            return !eventTitle.trimmingCharacters(in: .whitespaces).isEmpty && eventAt > Date()
        }
        if type == .accountability && buildHabit && habitDraft.habit == nil { return false }
        return true
    }

    private func createAndContinue() async {
        isWorking = true
        defer { isWorking = false }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDesc = detailedDescription.trimmingCharacters(in: .whitespaces)
        let code: String?
        switch type {
        case .accountability, .shared:
            code = await repository.createGroup(
                type: type, name: trimmedName,
                alarmTime: RTAlarmTime.string(from: alarmTime),
                alarmAnchor: alarmAnchor,
                alarmDays: repeats ? (selectedDays.count == RTWeekday.all.count ? [] : Array(selectedDays)) : [],
                alarmOnce: type == .shared && !repeats,
                detailedDescription: trimmedDesc,
                habit: (type == .accountability && buildHabit) ? habitDraft.habit : nil
            )
        case .event:
            code = await repository.createGroup(
                type: type, name: trimmedName,
                eventTitle: eventTitle.trimmingCharacters(in: .whitespaces),
                eventPlace: eventPlace.trimmingCharacters(in: .whitespaces),
                eventAt: eventAt,
                eventEndAt: hasEndTime ? eventEndAt : nil,
                detailedDescription: trimmedDesc
            )
        }
        if let code {
            createdCode = code
            showAddMembers = true
        }
    }
}

struct RTJoinGroupSheet: View {
    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isWorking = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite code") {
                    TextField("6-character code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    // For anyone who arrived via the web landing page, which
                    // stages the code on the clipboard. A PasteButton is an
                    // explicit user action, so it reads the pasteboard without
                    // triggering the system "Allow Paste?" prompt.
                    PasteButton(payloadType: String.self) { items in
                        guard let pasted = items.first,
                              let parsed = InviteLink.code(fromPastedText: pasted)
                        else { return }
                        Task { @MainActor in code = parsed }
                    }
                    .labelStyle(.titleAndIcon)
                }
                Section {
                    Button {
                        Task { await join() }
                    } label: {
                        HStack {
                            if isWorking { ProgressView() }
                            Text("Join group")
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 4 || isWorking)
                }
                if failed, let error = repository.lastError {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Join a group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func join() async {
        isWorking = true
        failed = false
        defer { isWorking = false }
        if await repository.joinGroup(inviteCode: code) {
            dismiss()
        } else {
            failed = true
        }
    }
}
