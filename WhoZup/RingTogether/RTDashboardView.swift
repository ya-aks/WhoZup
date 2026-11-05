//
//  RTDashboardView.swift
//  WhoZup
//
//  Created by Antigravity on 01/08/26.
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
    /// Habit routines by group → member (→ day for the month view).
    @State private var dayRoutines: [String: [String: RoutineProgress]] = [:]
    @State private var monthRoutines: [String: [String: [String: RoutineProgress]]] = [:]
    @State private var loading = false
    @State private var selectedType: RTGroupType = .accountability

    private var groupsToShow: [RTGroup] {
        if let groupId { return repository.group(id: groupId).map { [$0] } ?? [] }
        return repository.groups(of: selectedType).filter(\.hasRiseReport)
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
                        Text(selectedType == .accountability ? "No repeating alarms yet." : "No recurring meetups yet.")
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
            .navigationTitle(groupId == nil ? "" : "Rise Reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if groupId == nil {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Button("Alarms") { selectedType = .accountability }
                            Button("Plans") { selectedType = .shared }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedType == .accountability ? "Rise Reports: Alarms" : "Rise Reports: Plans")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(RT.ink)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(RT.inkSecondary)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if loading { ProgressView().padding(.top, 8) }
            }
        }
        .onAppear {
            if let groupId, let group = repository.group(id: groupId) {
                selectedType = group.type
            }
        }
        .task(id: fetchSignature) { await fetch() }
    }

    /// Re-fetches when the period or groups change, and also whenever anyone's
    /// live status does — so a response made (or synced) while the report is
    /// open shows up instead of the report going stale until reopened.
    private var fetchSignature: String {
        let ids = groupsToShow.map(\.id).sorted().joined(separator: ",")
        let live = groupsToShow
            .flatMap { g in g.roster.map { "\(g.id).\($0.uid)=\($0.status.rawValue)" } }
            .sorted()
            .joined(separator: ",")
        return "\(mode.rawValue)#\(mode == .day ? Self.dayKey(refDate) : Self.monthKey(refDate))#\(ids)#\(live)"
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
                HStack {
                    Text(group.name)
                        .font(.rtDisplay(17, .bold))
                        .foregroundStyle(RT.ink)
                    Spacer()
                }
            }

            if mode == .day {
                VStack(spacing: 2) {
                    ForEach(group.roster) { member in
                        dayRow(group: group, member: member)
                        if member.id != group.roster.last?.id { Divider().overlay(RT.divider) }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(group.roster) { member in
                        memberPerformanceCard(group: group, member: member)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RT.cardBorder, lineWidth: 1))
    }

    private func dayRow(group: RTGroup, member: RTMember) -> some View {
        let status = dayData[group.id]?[member.uid]
        // The routine only exists on a day the alarm was stopped on time.
        // (A one-time alarm's checklist also follows a late stop.)
        let routine = status == .wokeUp || status == .runningLate ? dayRoutines[group.id]?[member.uid] : nil
        return HStack(spacing: 10) {
            RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(member.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RT.ink)
                if let routine {
                    let missed = routine.isMissed()
                    RTRoutineBar(done: routine.done, tiny: routine.tiny, tinySteps: routine.tinySteps, missed: missed)
                        .frame(width: 120)
                    Text("Routine \(routine.isComplete && !routine.tiny ? "done" : routine.summary(now: Date()).lowercased())")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(routine.isComplete ? RT.dotOnTime : (missed ? RT.stepMissedText : RT.inkSecondary))
                }
            }
            Spacer()
            if let status {
                RTStatusChip(status: status)
            } else {
                Text("No data")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RT.inkFaint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(RT.cardBorder))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Member Performance Card (Month View)

    private func memberPerformanceCard(group: RTGroup, member: RTMember) -> some View {
        let monthLength = daysInMonth(refDate)
        let isCurrentMonth = Calendar.current.isDate(refDate, equalTo: Date(), toGranularity: .month)
        let today = isCurrentMonth ? Calendar.current.component(.day, from: Date()) : monthLength
        let outcomes = monthData[group.id]?[member.uid] ?? [:]
        let routines = monthRoutines[group.id]?[member.uid] ?? [:]

        // Every day of the month, in order (1 → last), with its recorded outcome.
        // Days past today (current month) are marked future so the timeline shows
        // the whole month while the stats and streak only count elapsed days.
        let dayStatuses: [(day: Int, status: RTStatus?, isFuture: Bool, routine: RoutineProgress?)] = (1...monthLength).map { d in
            let key = dayKeyFor(day: d, in: refDate)
            let status = outcomes[key]
            return (d, status, d > today, status == .wokeUp || status == .runningLate ? routines[key] : nil)
        }

        var wokeCount = 0
        var snoozeCount = 0
        var lateCount = 0
        var recordedDays = 0
        for entry in dayStatuses where !entry.isFuture {
            guard let status = entry.status else { continue }
            recordedDays += 1
            switch status {
            case .wokeUp: wokeCount += 1
            case .snoozed: snoozeCount += 1
            case .silentLate, .runningLate: lateCount += 1
            default: break
            }
        }

        let onTimeRate = recordedDays > 0 ? Int(round(Double(wokeCount) / Double(recordedDays) * 100)) : 0
        // Members with a habit are measured by their routine, not just waking.
        let routineEntries = dayStatuses.compactMap { $0.isFuture ? nil : $0.routine }
        let routineDays = routineEntries.count
        let routineDone = routineEntries.filter(\.isComplete).count
        let routineRate = recordedDays > 0 ? Int(round(Double(routineDone) / Double(recordedDays) * 100)) : 0
        let streak = currentStreak(dayStatuses.map { ($0.day, $0.status) })

        return VStack(alignment: .leading, spacing: 8) {
            // Header Row: Avatar + Name + On-time % + current streak
            HStack(spacing: 8) {
                RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(RT.ink)
                    Text(routineDays > 0 ? "\(routineRate)% routine done" : "\(onTimeRate)% on-time")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(onTimeRate >= 80 ? RTStatus.wokeUp.chipColor : (onTimeRate >= 50 ? RTStatus.snoozed.chipColor : RT.inkMuted))
                }
                Spacer()
                streakBadge(streak)
            }

            RTMonthTimeline(days: dayStatuses, today: today, isCurrentMonth: isCurrentMonth)
                .accessibilityLabel(routineDays > 0 ? "\(routineDone) of \(recordedDays) routines done" : "")

            // Stat counters
            Text(routineDays > 0
                 ? "\(routineDone) routines done · \(snoozeCount) snoozed · \(lateCount) late"
                 : "\(wokeCount) woke · \(snoozeCount) snoozed · \(lateCount) late")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RT.inkMuted)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(RT.canvas.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 0.8))
    }

    /// Consecutive on-time (woke-up) days counting back from the most recent
    /// recorded day. Days with no alarm/outcome are skipped rather than treated
    /// as a break, so an off day doesn't reset a genuine streak; the first
    /// recorded non-woke day ends it.
    private func currentStreak(_ days: [(day: Int, status: RTStatus?)]) -> Int {
        var streak = 0
        for entry in days.reversed() {
            guard let status = entry.status else { continue }
            if status == .wokeUp { streak += 1 } else { break }
        }
        return streak
    }

    @ViewBuilder private func streakBadge(_ streak: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 11, weight: .bold))
            Text(streak > 0 ? "\(streak)" : "0")
                .font(.system(size: 13, weight: .heavy))
        }
        .foregroundStyle(streak > 0 ? Color(hex: "#e0742a") : RT.inkFaint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(streak > 0 ? Color(hex: "#fbeed6") : RT.cardBorder.opacity(0.5)))
    }

    private var legend: some View {
        HStack(spacing: selectedType == .accountability ? 10 : 14) {
            legendDot(RTStatus.wokeUp.chipColor, "Woke up")
            legendDot(RTStatus.snoozed.chipColor, "Snoozed")
            legendDot(RTStatus.silentLate.chipColor, "Late")
            // Habit routines only exist on Check-ins.
            if selectedType == .accountability { legendDot(RT.stepMissed, "Missed step") }
            legendDot(RT.cardBorder, "No data")
        }
        .frame(maxWidth: .infinity)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
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
            var routines: [String: [String: RoutineProgress]] = [:]
            for group in groupsToShow {
                var r: [String: RoutineProgress] = [:]
                out[group.id] = await repository.fetchDayOutcomes(groupId: group.id, day: day) { uid, p in r[uid] = p }
                routines[group.id] = r
            }
            dayData = out
            dayRoutines = routines
        } else {
            let month = Self.monthKey(refDate)
            var out: [String: [String: [String: RTStatus]]] = [:]
            var routines: [String: [String: [String: RoutineProgress]]] = [:]
            for group in groupsToShow {
                var r: [String: [String: RoutineProgress]] = [:]
                out[group.id] = await repository.fetchMonthOutcomes(groupId: group.id, monthPrefix: month) { uid, day, p in
                    r[uid, default: [:]][day] = p
                }
                routines[group.id] = r
            }
            monthData = out
            monthRoutines = routines
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

/// The month heatmap timeline as its own view so it can track scroll position
/// and render a live scroll indicator beneath the strip — signalling that the
/// row scrolls and where in the month you currently are.
private struct RTMonthTimeline: View {
    let days: [(day: Int, status: RTStatus?, isFuture: Bool, routine: RoutineProgress?)]
    let today: Int
    let isCurrentMonth: Bool

    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollX: CGFloat = 0

    private let cellWidth: CGFloat = 15

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(days, id: \.day) { cell($0) }
                }
                .padding(.vertical, 1)
            }
            .onScrollGeometryChange(for: Metrics.self) { geo in
                Metrics(offset: geo.contentOffset.x,
                        content: geo.contentSize.width,
                        viewport: geo.containerSize.width)
            } action: { _, m in
                scrollX = m.offset
                contentWidth = m.content
                viewportWidth = m.viewport
            }
            .onAppear { proxy.scrollTo(today, anchor: .center) }
        }
        .frame(height: 40)
        .overlay(alignment: .leading) { edgeArrow(pointsLeft: true) }
        .overlay(alignment: .trailing) { edgeArrow(pointsLeft: false) }
    }

    private func cell(_ entry: (day: Int, status: RTStatus?, isFuture: Bool, routine: RoutineProgress?)) -> some View {
        let isToday = isCurrentMonth && entry.day == today
        // A number for day 1, every 5th day, and today — enough to orient.
        let showLabel = entry.day == 1 || entry.day % 5 == 0 || isToday
        return VStack(spacing: 4) {
            cellBar(entry)
                .frame(width: cellWidth, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(RT.ink, lineWidth: isToday ? 2 : 0)
                )
            Text(showLabel ? "\(entry.day)" : " ")
                .font(.system(size: 9, weight: isToday ? .bold : .medium))
                .foregroundStyle(isToday ? RT.ink : RT.inkFaint)
        }
        .frame(width: cellWidth)
        .id(entry.day)
    }

    /// A day you woke up with a habit is split into its routine steps; any
    /// other day is one solid block, as before.
    @ViewBuilder private func cellBar(_ entry: (day: Int, status: RTStatus?, isFuture: Bool, routine: RoutineProgress?)) -> some View {
        // Undone steps are pale red once the window has closed, to-do beige while open.
        let undone = entry.routine?.isMissed() == true ? RT.stepMissed : RT.stepTodo
        if let routine = entry.routine, !routine.tiny, routine.total > 1 {
            VStack(spacing: 1) {
                ForEach(routine.done.indices, id: \.self) { i in
                    Rectangle().fill(routine.done[i]
                                     ? (routine.isTiny(i) ? RT.stepTiny : RT.dotOnTime)
                                     : undone)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        } else if let routine = entry.routine {
            RoundedRectangle(cornerRadius: 3)
                .fill(routine.tiny ? RT.stepTiny : (routine.isComplete ? RT.dotOnTime : undone))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(fill(entry))
        }
    }

    private func fill(_ entry: (day: Int, status: RTStatus?, isFuture: Bool, routine: RoutineProgress?)) -> Color {
        if let status = entry.status { return status.reportColor }
        return RT.cardBorder.opacity(entry.isFuture ? 0.25 : 0.55)
    }

    /// A small chevron floating at an edge to signal there are more days that
    /// way. Shown only when the strip actually overflows in that direction, so
    /// it appears trailing when more days sit to the right and leading when
    /// earlier days sit to the left (the common case, since we open on today).
    @ViewBuilder private func edgeArrow(pointsLeft: Bool) -> some View {
        let maxScroll = max(contentWidth - viewportWidth, 0)
        let scrollable = contentWidth > viewportWidth + 1
        let show = scrollable && (pointsLeft ? scrollX > 1 : scrollX < maxScroll - 1)
        if show {
            Image(systemName: pointsLeft ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RT.inkMuted)
                .frame(width: 18, height: 18)
                .background(Circle().fill(RT.card))
                .overlay(Circle().stroke(RT.cardBorder, lineWidth: 0.8))
                .offset(y: -9)
                .allowsHitTesting(false)
        }
    }

    private struct Metrics: Equatable {
        let offset: CGFloat
        let content: CGFloat
        let viewport: CGFloat
    }
}
