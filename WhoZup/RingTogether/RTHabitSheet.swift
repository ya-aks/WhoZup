//
//  RTHabitSheet.swift
//  WhoZup
//
//  Building and editing a personal habit on a Check-ins group: a name, up to
//  three steps you type yourself (each with an optional tiny version), how
//  long the routine stays open after the alarm stops, and whether the group
//  sees your step names or only "2 of 3".
//
//  The same editor builds a one-time alarm's checklist (`checklist` mode): an
//  optional name, up to five items, no tiny versions.
//

import SwiftUI

/// Editable copy of a habit while it's being built.
struct RTHabitDraft: Equatable {
    struct Step: Identifiable, Equatable {
        let id = UUID()
        var title = ""
        var tiny = ""
    }

    var name = ""
    var steps: [Step] = [Step()]
    var windowMinutes = 30
    var showSteps = true
    /// Building a one-time alarm's checklist rather than a habit.
    var checklist = false

    var maxSteps: Int { checklist ? MemberHabit.maxChecklistItems : MemberHabit.maxSteps }

    init(checklist: Bool = false) {
        self.checklist = checklist
    }

    init(_ habit: MemberHabit) {
        checklist = habit.checklist
        name = habit.name
        steps = habit.steps.map { Step(title: $0.title, tiny: $0.tiny ?? "") }
        if steps.isEmpty { steps = [Step()] }
        windowMinutes = min(max(habit.windowMinutes, MemberHabit.windowRange.lowerBound), MemberHabit.windowRange.upperBound)
        showSteps = habit.showSteps
    }

    /// The habit, or nil until it has a name and at least one step. A
    /// checklist needs only one item: its name defaults to "Checklist", and it
    /// has no tiny versions.
    var habit: MemberHabit? {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if checklist && name.isEmpty { name = MemberHabit.defaultChecklistName }
        let steps = steps
            .map { HabitStep(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                             tiny: checklist ? "" : $0.tiny.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.title.isEmpty }
            .map { HabitStep(title: $0.title, tiny: ($0.tiny ?? "").isEmpty ? nil : $0.tiny) }
        guard !name.isEmpty, !steps.isEmpty else { return nil }
        let plan = MemberHabit(name: name, steps: Array(steps.prefix(maxSteps)),
                               windowMinutes: windowMinutes, showSteps: showSteps)
        return checklist ? plan.asChecklist : plan
    }
}

/// The habit fields, shared by group creation and the edit sheet.
struct RTHabitFields: View {
    @Binding var draft: RTHabitDraft
    var accent: Color = RT.dotOnTime

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                label(draft.checklist ? "Name (optional)" : "My habit")
                field(draft.checklist ? "e.g. Airport run" : "e.g. Morning run", text: $draft.name, size: 16)
            }

            VStack(alignment: .leading, spacing: 8) {
                label(draft.checklist ? "After this alarm stops, I need to…" : "After my alarm stops, I'll…")
                ForEach($draft.steps) { $step in
                    stepRow($step, number: (draft.steps.firstIndex { $0.id == step.id } ?? 0) + 1)
                }
                HStack {
                    Button {
                        draft.steps.append(.init())
                    } label: {
                        Text(draft.checklist ? "+ Add an item" : "+ Add a step")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(canAddStep ? accent : RT.inkFaint)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                    .foregroundStyle(RT.dotIdle)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAddStep)
                    Spacer()
                    Text("\(draft.steps.count) of \(draft.maxSteps) · max \(draft.maxSteps) \(draft.checklist ? "items" : "steps")")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(RT.inkSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                label("Finish within")
                Picker("Finish within", selection: $draft.windowMinutes) {
                    ForEach(MemberHabit.windowRange, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 120)
                .clipped()
                .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
                Text("Your \(draft.checklist ? "checklist" : "routine") stays open for \(draft.windowMinutes) min after the alarm stops.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
            }

            Toggle(isOn: $draft.showSteps) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.checklist ? "Show my item names" : "Show my step names")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RT.ink)
                    Text("Off: the group sees \"2 of 3\" only")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }
            }
            .tint(accent)
        }
    }

    private var canAddStep: Bool { draft.steps.count < draft.maxSteps }

    private func stepRow(_ step: Binding<RTHabitDraft.Step>, number: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accent))
                .padding(.top, 10)
            VStack(spacing: 6) {
                field(draft.checklist ? "Item \(number)" : "Step \(number)", text: step.title, size: 15)
                if !draft.checklist {
                    field("Tiny version (optional), e.g. step outside", text: step.tiny, size: 13, dashed: true)
                }
            }
            Button {
                draft.steps.removeAll { $0.id == step.wrappedValue.id }
                if draft.steps.isEmpty { draft.steps = [.init()] }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RT.inkMuted)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove step \(number)")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(RT.inkSecondary)
    }

    private func field(_ placeholder: String, text: Binding<String>, size: CGFloat, dashed: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: size, weight: dashed ? .regular : .semibold))
            .foregroundStyle(RT.ink)
            .tint(accent)
            .padding(.horizontal, 12)
            .frame(minHeight: dashed ? 38 : 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(dashed ? Color.clear : RT.card))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
                    .foregroundStyle(dashed ? RT.dotIdle : RT.cardBorder)
            )
    }
}

/// Add, edit or remove your habit in one group — or, when your alarm there
/// rings once, your checklist for it.
struct RTHabitSheet: View {
    let groupId: String
    var checklist: Bool = false

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RTHabitDraft()
    private var noun: String { checklist ? "checklist" : "habit" }
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmRemove = false

    private var existing: MemberHabit? {
        checklist ? repository.myChecklist(groupId: groupId) : repository.myHabit(groupId: groupId)
    }

    private func save(_ plan: MemberHabit?) async -> Bool {
        checklist ? await repository.setMyChecklist(groupId: groupId, checklist: plan)
            : await repository.setMyHabit(groupId: groupId, habit: plan)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(checklist
                         ? "This alarm rings once. List what you need to get done after it — the group sees you tick them off."
                         : "Your alarm is the cue. Keep the steps small — it's doing them every day that builds the habit.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                    RTHabitFields(draft: $draft)
                    if existing != nil {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Text("Remove \(noun)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(RT.dotLate)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .background(RT.canvas)
            .navigationTitle(existing == nil ? "Add a \(noun)" : "Edit \(noun)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        guard let habit = draft.habit else { return }
                        saving = true
                        Task {
                            if await save(habit) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(draft.habit == nil || saving)
                }
            }
            .alert("Remove this \(noun)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) {
                    Task {
                        if await save(nil) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your alarm stays. Past routines stay in the Rise Report.")
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let existing { draft = RTHabitDraft(existing) } else { draft = RTHabitDraft(checklist: checklist) }
        }
    }
}
