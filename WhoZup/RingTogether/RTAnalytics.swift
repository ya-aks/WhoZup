//
//  RTAnalytics.swift
//  WhoZup
//
//  Product analytics (Firebase / Google Analytics). Every event and parameter
//  name lives here so iOS and Android (`analytics/Track.kt`) log the same thing;
//  the plan, and the decision each event serves, is in docs/analytics.md.
//
//  Rules: no names, phone numbers, emails, plan titles or places, ever. Ids are
//  the random Firestore group id only. Debug builds don't collect unless
//  launched with `-WhoZupAnalytics` (then use `-FIRDebugEnabled` for DebugView).
//

import FirebaseAnalytics
import Foundation

enum RTAnalytics {
    /// Called right after `FirebaseApp.configure()`.
    static func configure() {
        #if DEBUG
        let enabled = ProcessInfo.processInfo.arguments.contains("-WhoZupAnalytics")
        #else
        let enabled = true
        #endif
        Analytics.setAnalyticsCollectionEnabled(enabled)
    }

    // MARK: - Shared vocabulary

    /// What a group is, in one word: alarm, plan_once, plan_once_ring,
    /// plan_weekly, or the legacy in_sync / event.
    static func kind(type: RTGroupType, planKind: RTPlanKind?) -> String {
        switch planKind {
        case .once: return "plan_once"
        case .onceAlarm: return "plan_once_ring"
        case .repeating: return "plan_weekly"
        case nil:
            switch type {
            case .accountability: return "alarm"
            case .shared: return "in_sync"
            case .event: return "event"
            }
        }
    }

    static func kind(_ group: RTGroup) -> String { kind(type: group.type, planKind: group.planKind) }

    private static func yes(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func log(_ name: String, _ params: [String: Any] = [:]) {
        Analytics.logEvent(name, parameters: params.isEmpty ? nil : params)
    }

    // MARK: - Accounts

    /// First time we see this account (`users/{uid}` didn't exist), else a sign-in.
    /// `method`: phone, google, apple, email.
    static func signedIn(method: String, isNew: Bool) {
        log(isNew ? AnalyticsEventSignUp : AnalyticsEventLogin, [AnalyticsParameterMethod: method])
    }

    static func profileCompleted() { log("profile_completed") }

    // MARK: - Creating

    static func planCreateStarted() { log("plan_create_started") }

    /// The two quick questions answered (the funnel step between started and created).
    static func planQuestionsAnswered(weekly: Bool, ring: Bool) {
        log("plan_questions_answered", ["how_often": weekly ? "weekly" : "once", "ring": yes(ring)])
    }

    /// A plan was created. `customAsks`: the host changed the default headcount asks.
    static func planCreated(groupId: String, kind: RTPlanKind, ring: Bool, leadMinutes: Int, customLead: Bool,
                            flagNotUp: Bool, everyoneIn: Bool, asks: Int, customAsks: Bool, hasPlace: Bool,
                            days: Int, weeklyPlansHosted: Int) {
        log("group_created", [
            "group_id": groupId, "kind": self.kind(type: kind.groupType, planKind: kind),
            "ring": yes(ring), "lead_min": ring ? leadMinutes : -1, "lead_custom": yes(customLead),
            "flag_not_up": yes(flagNotUp), "everyone_in": yes(everyoneIn), "asks": asks,
            "custom_asks": yes(customAsks), "has_place": yes(hasPlace), "days": days,
        ])
        // Moments the pricing proposal (docs/pricing.md) would charge for. Logged,
        // never enforced: they size the paid tier before anyone sees a paywall.
        if kind == .repeating && weeklyPlansHosted >= 1 { pricingTrigger("second_weekly_plan", groupId: groupId) }
        if customAsks { pricingTrigger("custom_headcount", groupId: groupId) }
        if flagNotUp { pricingTrigger("flag_not_up", groupId: groupId) }
    }

    /// An Alarms group (or a legacy In Sync / Event) was created.
    static func groupCreated(groupId: String, type: RTGroupType, repeats: Bool, habit: Bool) {
        log("group_created", [
            "group_id": groupId, "kind": kind(type: type, planKind: nil),
            "repeats": yes(repeats), "habit": yes(habit),
        ])
    }

    // MARK: - Growth

    /// The invite share sheet was opened. `method`: link, text.
    static func inviteShareOpened(method: String, kind: String) {
        log("invite_share_opened", ["method": method, "kind": kind])
    }

    static func appShareOpened() { log(AnalyticsEventShare, [AnalyticsParameterContentType: "app"]) }

    /// Someone joined by code or link; `groupSize` counts them in.
    static func groupJoined(groupId: String, kind: String, groupSize: Int) {
        log(AnalyticsEventJoinGroup, [AnalyticsParameterGroupID: groupId, "kind": kind, "group_size": groupSize])
        if kind.hasPrefix("plan"), groupSize > 12 { pricingTrigger("plan_over_12", groupId: groupId) }
    }

    // MARK: - Using

    /// A member answered a plan date (or an RSVP). `answer`: in, late, skip.
    static func planAnswered(groupId: String, kind: String, answer: String, ahead: Bool) {
        log("plan_answered", ["group_id": groupId, "kind": kind, "answer": answer, "ahead": yes(ahead)])
    }

    /// Your own alarm outcome was recorded in the app. `status`: the storage key.
    static func alarmResponse(groupId: String, kind: String, status: String) {
        log("alarm_response", ["group_id": groupId, "kind": kind, "status": status])
    }

    static func headcountPeopleViewed(groupId: String, bucket: String) {
        log("headcount_people_viewed", ["group_id": groupId, "bucket": bucket])
    }

    /// `audience`: unanswered, yes, everyone. `manualIndex`: this host's nth Ask now this session.
    static func askNowSent(groupId: String, audience: String, manualIndex: Int) {
        log("ask_now_sent", ["group_id": groupId, "audience": audience, "nth": manualIndex])
        if manualIndex >= 2 { pricingTrigger("extra_ask_now", groupId: groupId) }
    }

    static func nudgeSent(groupId: String, all: Bool) {
        log("nudge_sent", ["group_id": groupId, "all": yes(all)])
    }

    /// `scope`: group (from a group's screen) or all (More → Rise Reports).
    static func riseReportViewed(scope: String) { log("rise_report_viewed", ["scope": scope]) }

    /// `tab`: alarms, plans, more.
    static func howItWorksOpened(tab: String) { log("how_it_works_opened", ["tab": tab]) }

    /// `category`: idea, problem, other. (The text itself goes to Firestore, never here.)
    static func feedbackSent(category: String) { log("feedback_sent", ["category": category]) }

    // MARK: - Money

    static func tipSheetOpened() { log("tip_sheet_opened") }

    static func tipPurchased(productId: String, value: Double, currency: String) {
        log(AnalyticsEventPurchase, [
            AnalyticsParameterItemID: productId, AnalyticsParameterValue: value,
            AnalyticsParameterCurrency: currency,
        ])
    }

    /// A moment the pricing proposal would have shown a paywall. Never blocks.
    static func pricingTrigger(_ trigger: String, groupId: String? = nil) {
        var params: [String: Any] = ["trigger": trigger]
        if let groupId { params["group_id"] = groupId }
        log("pricing_trigger", params)
    }

    // MARK: - Who the user is (user properties, bucketed)

    /// Called when the groups list changes. Buckets keep these usable as audiences.
    static func updateUserProperties(alarmGroups: Int, plansHosted: Int, plansJoined: Int, weeklyPlansHosted: Int) {
        func bucket(_ n: Int) -> String { n == 0 ? "0" : n == 1 ? "1" : n <= 3 ? "2-3" : n <= 9 ? "4-9" : "10+" }
        Analytics.setUserProperty(bucket(alarmGroups), forName: "alarm_groups")
        Analytics.setUserProperty(bucket(plansHosted), forName: "plans_hosted")
        Analytics.setUserProperty(bucket(plansJoined), forName: "plans_joined")
        Analytics.setUserProperty(bucket(weeklyPlansHosted), forName: "weekly_plans_hosted")
    }
}
