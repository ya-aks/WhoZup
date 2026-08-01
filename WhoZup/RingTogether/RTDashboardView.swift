//
//  RTDashboardView.swift
//  WhoZup
//
//  The accountability dashboard: who woke up, snoozed, or slept through, day by
//  day and across a month, so a group can hold each other accountable. Reads the
//  per-day history recorded on each alarm outcome (see GroupRepository). Works
//  for a single group (opened from its detail) or across every accountability
//  group (opened from the More tab) when `groupId` is nil.
//

import SwiftUI

struct RTDashboardView: View {
    /// A single group to show, or nil for all of the user's accountability groups.
    let groupId: String?

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable { case day = "Day", month = "Month" }

    @State private var mode: Mode = .day
    @State private var refDate = Date()
    // groupId -> uid -> status (day view); groupId -> uid -> dayKey -> status (month).
    @State private var dayData: [String: [String: RTStatus]] = [:]
    @State private var monthData: [String: [String: [String: RTStatus]]] = [:]
    @State private var loading = false

    private var groupsToShow: [RTGroup] {
        if let groupId { return repository.group(id: groupId).map { [$0] } ?? [] }
        return repository.groups(of: .accountability)
    }

    /// Never let the user page into the future.
    private var atLatest: Bool {
        let cal = Calendar.current
        return mode == .day
            ? cal.isDate(refDate, inSameDayAs: Date()) || refDate > Date()
            : cal.isDate(refDate, equalTo: Date(), toGranularity: .month) || refDate > Date()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    periodNav

                    if groupsToShow.isEmpty {
                        Text("No accountability groups yet.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(RT.inkMuted)
                            .padding(.top, 20)
                    } else {
                        ForEach(groupsToShow) { group in
                            groupSection(group)
                        }
                        legend.padding(.top, 4)
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .background(RT.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(groupId == nil ? "Accountability" : "Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if loading { ProgressView().padding(.top, 8) }
            }
        }
        .task(id: fetchSignature) { await fetch() }
    }

    private var fetchSignature: String {
        let ids = groupsToShow.map(\.id).sorted().joined(separator: ",")
        return "\(mode.rawValue)#\(mode == .day ? Self.dayKey(refDate) : Self.monthKey(refDate))#\(ids)"
    }

    // MARK: Period navigation

    private var periodNav: some View {
        HStack {
            navButton("chevron.left") { shift(-1) }
            Spacer()
            Text(periodLabel)
                .font(.rtDisplay(17, .bold))
                .foregroundStyle(RT.ink)
            Spacer()
            navButton("chevron.right") { shift(1) }
                .opacity(atLatest ? 0.3 : 1)
                .disabled(atLatest)
        }
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(RT.inkSecondary)
                .frame(width: 40, height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(RT.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RT.cardBorder, lineWidth: 1))
        }
    }

    private var periodLabel: String {
        let f = DateFormatter()
        if mode == .day {
            if Calendar.current.isDateInToday(refDate) { return "Today" }
            f.dateFormat = "EEE, MMM d"
        } else {
            f.dateFormat = "MMMM yyyy"
        }
        return f.string(from: refDate)
    }

    private func shift(_ by: Int) {
        let cal = Calendar.current
        let comp: Calendar.Component = mode == .day ? .day : .month
        if let d = cal.date(byAdding: comp, value: by, to: refDate) {
            if by > 0 && d > Date() { return }
            refDate = d
        }
    }

    // MARK: Group section

    @ViewBuilder private func groupSection(_ group: RTGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if groupId == nil {
                Text(group.name)
                    .font(.rtDisplay(18, .bold))
                    .foregroundStyle(RT.ink)
            }

            if mode == .day {
                ForEach(group.roster) { member in
                    dayRow(group: group, member: member)
                    if member.id != group.roster.last?.id { Divider().overlay(RT.divider) }
                }
            } else {
                ForEach(group.roster) { member in
                    monthRow(group: group, member: member)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
    }

    private func dayRow(group: RTGroup, member: RTMember) -> some View {
        let status = dayData[group.id]?[member.uid]
        return HStack(spacing: 12) {
            RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 34)
            Text(member.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RT.ink)
            Spacer()
            if let status {
                RTStatusChip(status: status)
            } else {
                Text("No data")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RT.inkFaint)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(RT.cardBorder))
            }
        }
        .padding(.vertical, 8)
    }

    private func monthRow(group: RTGroup, member: RTMember) -> some View {
        let days = daysInMonth(refDate)
        let outcomes = monthData[group.id]?[member.uid] ?? [:]
        return VStack(alignment: .leading, spacing: 6) {
            Text(member.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RT.ink)
            // A compact strip: one small square per day of the month.
            HStack(spacing: 3) {
                ForEach(1...days, id: \.self) { d in
                    let key = dayKeyFor(day: d, in: refDate)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(outcomes[key]?.chipColor ?? RT.cardBorder)
                        .frame(width: 8, height: 14)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(RTStatus.wokeUp.chipColor, "Woke up")
            legendDot(RTStatus.snoozed.chipColor, "Snoozed")
            legendDot(RTStatus.silentLate.chipColor, "Late")
            legendDot(RT.cardBorder, "No data")
        }
        .frame(maxWidth: .infinity)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(RT.inkSecondary)
        }
    }

    // MARK: Fetch

    private func fetch() async {
        guard !groupsToShow.isEmpty else { return }
        loading = true
        defer { loading = false }
        if mode == .day {
            let day = Self.dayKey(refDate)
            var out: [String: [String: RTStatus]] = [:]
            for group in groupsToShow {
                out[group.id] = await repository.fetchDayOutcomes(groupId: group.id, day: day)
            }
            dayData = out
        } else {
            let month = Self.monthKey(refDate)
            var out: [String: [String: [String: RTStatus]]] = [:]
            for group in groupsToShow {
                out[group.id] = await repository.fetchMonthOutcomes(groupId: group.id, monthPrefix: month)
            }
            monthData = out
        }
    }

    // MARK: Date helpers

    private static func dayKey(_ date: Date) -> String { GroupRepository.dayKey(date) }
    private static func monthKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }
    private func daysInMonth(_ date: Date) -> Int {
        Calendar.current.range(of: .day, in: .month, for: date)?.count ?? 30
    }
    private func dayKeyFor(day: Int, in monthDate: Date) -> String {
        String(format: "%@-%02d", Self.monthKey(monthDate), day)
    }
}
