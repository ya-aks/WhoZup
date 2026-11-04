//
//  RTGroupListView.swift
//  WhoZup
//
//  A tab's group list (Accountability / Shared / Events), backed by the live
//  Firestore repository. Tapping a card pushes the matching detail screen;
//  the "+ New group" button and a "Join by code" action create/join real
//  Firestore groups.
//

import StoreKit
import SwiftUI

struct RTGroupListView: View {
    let type: RTGroupType
    /// The Plans tab: In Sync (`shared`) and Events (`event`) groups together,
    /// created through the plan-kind picker.
    var plans = false

    @Environment(GroupRepository.self) private var repository
    @Environment(PendingGroupStore.self) private var pendingGroup
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showHelp = false
    @State private var showFabMenu = false
    @State private var showPaywall = false
    /// Whether the paywall was opened from the "New group" create gate (so a
    /// purchase should proceed into the create form) rather than from the
    /// Events-tab "add events" banner (where it should just dismiss).
    @State private var paywallOpensCreate = false
    /// A group id pushed programmatically by a notification tap (vs. a card tap).
    @State private var pushedGroupId: String?
    /// Events tab: show active (running/upcoming) or completed events.
    @State private var eventFilter: RTEventFilter = .active
    @State private var showKindPicker = false
    /// The plan kind picked for the create form (Plans tab).
    @State private var createKind: RTPlanKind?

    private var groups: [RTGroup] {
        plans ? repository.groups(of: .shared) + repository.groups(of: .event) : repository.groups(of: type)
    }

    /// The accent of this list: the Plans tab uses the events orange.
    private var accent: Color { plans ? RTGroupType.event.accent : type.accent }

    /// Events and Plans split by completion so what's still ahead stays front
    /// and centre; other tabs show everything. A plan is past once its event
    /// ended or its one-time alarm has rung.
    private var displayedGroups: [RTGroup] {
        guard plans || type == .event else { return groups }
        return groups.filter { group in
            let completed = group.event?.isCompleted ?? RTAlarmSync.onceIsOver(group)
            return eventFilter == .completed ? completed : !completed
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        if plans {
                            Text("PLANS")
                                .font(.system(size: 13, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(RTGroupType.event.eyebrow)
                        } else {
                            RTEyebrow(type: type)
                        }
                        Spacer()
                        Button {
                            showHelp = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "questionmark.circle")
                                Text("How it works")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                        }
                    }

                    Text(plans ? "Plans" : type.listTitle)
                        .font(.rtDisplay(28, .bold))
                        .foregroundStyle(RT.ink)
                        .padding(.top, 8)

                    Text(plans ? "Shared times, one-off or every week. See who's coming and who's up." : type.listSubtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.top, 4)

                    if plans || type == .event {
                        RTFreeEventsBanner(remaining: repository.eventsRemaining) {
                            // Buying from the banner offers the same choice —
                            // event pack or the lifetime unlock — via the paywall.
                            paywallOpensCreate = false
                            showPaywall = true
                        }
                        .padding(.top, 16)

                        Picker("", selection: $eventFilter) {
                            Text(plans ? "Upcoming" : "Active").tag(RTEventFilter.active)
                            Text(plans ? "Past" : "Completed").tag(RTEventFilter.completed)
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 14)
                    }

                    VStack(spacing: 14) {
                        if displayedGroups.isEmpty {
                            RTEmptyState(type: type, plans: plans)
                                .padding(.top, 8)
                        }

                        ForEach(displayedGroups) { group in
                            VStack(spacing: 0) {
                                NavigationLink {
                                    destination(for: group)
                                } label: {
                                    RTGroupCard(group: group)
                                }
                                .buttonStyle(RTPressStyle())

                                if group.type != .event {
                                    RTCheckInCard(groupId: group.id, accent: group.type.accent, topSpacing: 10)
                                }
                            }
                        }
                    }
                    .padding(.top, 18)
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(RT.canvas)
            .scrollIndicators(.hidden)
            // Programmatic push for a notification tap (card taps use their own
            // NavigationLink). Only the list whose type matches acts on it.
            .navigationDestination(item: $pushedGroupId) { id in
                // Only this list's types ever push (see tryOpen), so route by type.
                if repository.group(id: id)?.type == .event {
                    RTEventDetailView(groupId: id)
                } else {
                    RTGroupDetailView(groupId: id)
                }
            }
            .onChange(of: pendingGroup.groupId) { _, id in tryOpen(id) }
            .onChange(of: repository.groups.map(\.id)) { _, _ in tryOpen(pendingGroup.groupId) }
            .onAppear { tryOpen(pendingGroup.groupId) }
            // A floating "＋" pinned above the tab bar. It hosts both ways to
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    if showFabMenu {
                        // Top option: "New group" (appears second with slight delay)
                        Button {
                            withAnimation { showFabMenu = false }
                            // Plans: pick the kind first.
                            if plans {
                                showKindPicker = true
                                return
                            }
                            // Paywall gate: creating an event over the free limit
                            // shows the purchase options instead of the form.
                            if type == .event && !repository.canCreateEvent {
                                paywallOpensCreate = true
                                showPaywall = true
                            } else {
                                showCreate = true
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 14, weight: .bold))
                                Text(plans ? "New plan" : "New group")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(RT.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).animation(.spring(response: 0.3, dampingFraction: 0.75).delay(0.06)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))
                        ))

                        // Bottom option: "Join by code" (appears first)
                        Button {
                            withAnimation { showFabMenu = false }
                            showJoin = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "number")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Join by code")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(RT.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).animation(.spring(response: 0.3, dampingFraction: 0.75)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))
                        ))
                    }

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            showFabMenu.toggle()
                        }
                    } label: {
                        Image(systemName: showFabMenu ? "xmark" : "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(accent))
                            .shadow(color: accent.opacity(0.35), radius: 12, y: 6)
                            .rotationEffect(.degrees(showFabMenu ? 90 : 0))
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 74)
            }
        }
        .sheet(isPresented: $showCreate) {
            if plans, let createKind {
                RTCreatePlanSheet(kind: createKind)
            } else {
                RTCreateGroupSheet(type: type)
            }
        }
        .sheet(isPresented: $showKindPicker) {
            RTPlanKindSheet { kind in
                createKind = kind
                // A get-together is an event: over the free limit, the paywall first.
                if kind == .once && !repository.canCreateEvent {
                    paywallOpensCreate = true
                    showPaywall = true
                } else {
                    showCreate = true
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showJoin) {
            RTJoinGroupSheet()
        }
        .sheet(isPresented: $showHelp) {
            RTHowItWorksSheet(type: plans ? .event : type)
        }
        .sheet(isPresented: $showPaywall) {
            RTEventPaywallSheet(
                subtitle: paywallOpensCreate
                    ? "You've used all \(GroupRepository.freeEventLimit) free events. Add more or go unlimited."
                    : "Add an event pack, or unlock unlimited events forever."
            ) {
                // Only the create-gate path proceeds into the create form; a buy
                // from the banner just dismisses.
                if paywallOpensCreate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showCreate = true }
                }
            }
        }
    }

    @ViewBuilder private func destination(for group: RTGroup) -> some View {
        if group.type == .event {
            RTEventDetailView(groupId: group.id)
        } else {
            RTGroupDetailView(groupId: group.id)
        }
    }

    /// Push the pending group's detail if it belongs to this list's type, then
    /// clear the store so it fires once.
    private func tryOpen(_ id: String?) {
        guard let id, let group = repository.group(id: id),
              plans ? group.type != .accountability : group.type == type else { return }
        pushedGroupId = id
        pendingGroup.groupId = nil
    }
}

/// Purchase options shown when creating an event past the free limit: a +20
/// Event Pack or the lifetime "unlimited events" unlock. `onUnlocked` fires
/// after a successful purchase (the sheet then dismisses).
struct RTEventPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = EventPackStore.shared
    var subtitle: String = "You've used all \(GroupRepository.freeEventLimit) free events. Add more or go unlimited."
    var onUnlocked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock more events")
                .font(.rtDisplay(24, .bold))
                .foregroundStyle(RT.ink)
            Text(subtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RT.inkMuted)

            // Only surface a purchase option when its real StoreKit product
            // loaded — never a fallback price behind a button that can't complete
            // (App Store review rejects non-functional IAP).
            if store.eventPackProduct == nil && store.lifetimeProduct == nil {
                Text("Purchases are temporarily unavailable. Please try again later.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
            }
            if let pack = store.eventPackProduct {
                option(
                    title: "Event Pack",
                    subtitle: "+20 events",
                    price: pack.displayPrice,
                    accent: RTGroupType.event.accent
                ) { Task { if await store.purchaseEventPack() { onUnlocked(); dismiss() } } }
            }
            if let lifetime = store.lifetimeProduct {
                option(
                    title: "Lifetime Unlimited",
                    subtitle: "Create events forever",
                    price: lifetime.displayPrice,
                    accent: Color(hex: "#1f7a5c")
                ) { Task { if await store.purchaseLifetime() { onUnlocked(); dismiss() } } }
            }

            if store.isPurchasing {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Button { dismiss() } label: {
                Text("Not now")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RT.inkMuted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    private func option(
        title: String, subtitle: String, price: String, accent: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(RT.ink)
                    Text(subtitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(RT.inkMuted)
                }
                Spacer()
                Text(price)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(accent))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(RT.cardBorder, lineWidth: 1))
        }
        .buttonStyle(RTPressStyle())
        .disabled(store.isPurchasing)
    }
}

/// Subtle scale-on-press to match the design's `transform: scale(0.985)`.
struct RTPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shown when a tab has no groups yet.
struct RTEmptyState: View {
    let type: RTGroupType
    var plans = false

    private var message: String {
        if plans { return "No plans yet. Tap ＋ for a one-time or repeating plan." }
        switch type {
        case .accountability: return "No alarm groups yet. Create one and invite friends to keep each other on time."
        case .shared: return "No In Sync groups yet. Create one common alarm for the whole crew."
        case .event: return "No events yet. Start one to send a one-tap “are you coming?” check."
        }
    }

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(RT.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
    }
}

/// The "N of 5 free events used" banner on the Events tab.
/// Events tab list filter.
enum RTEventFilter { case active, completed }

/// Shows how many events the user can still create (or "Unlimited"), with a
/// one-tap buy for more. `remaining == nil` means the lifetime unlock is on.
/// Tapping the buy pill opens the paywall (`onBuy`), which offers both the +20
/// event pack and the lifetime unlock — so lifetime is discoverable here too.
struct RTFreeEventsBanner: View {
    let remaining: Int?
    var onBuy: () -> Void
    @StateObject private var eventPackStore = EventPackStore.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if let remaining {
                        Text(remaining == 0 ? "No events left" : "\(remaining) event\(remaining == 1 ? "" : "s") left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(hex: "#9a6410"))
                        Text("Add 20 more anytime · never resets")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "#a9702a"))
                    } else {
                        Text("Unlimited events")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(hex: "#1f7a5c"))
                        Text("Lifetime unlock active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "#3a8f6f"))
                    }
                }
                Spacer()
                if remaining != nil {
                    Button(action: onBuy) {
                        Text("Get more ›")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color(hex: "#d98c3a")))
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(remaining == nil ? Color(hex: "#e3f3ec") : Color(hex: "#fbeed6")))
    }
}
