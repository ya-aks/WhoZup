/**
 * RingTogether Cloud Functions.
 *
 * Implements server-side notification & admin features:
 *
 *   1. activityPush — when ANY activity entry is added to a group (alarm change,
 *      member response, snooze, silent/late, member join, member leave, member remove),
 *      send an FCM push notification to all other group members. Cleans up stale tokens.
 *
 *   2. adminReminderPush — HTTPS callable function for event admins to nudge non-responders.
 *      Enforces server-side caps: max 5 reminders per event, minimum 5 minutes apart.
 *
 *   3. applyInviteAdminOnJoin — when a member joins via an admin-flagged invite,
 *      grants admin role.
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();
const db = getFirestore();

/**
 * Push a notification to all group members (except actor) for ANY activity entry.
 */
exports.activityPush = onDocumentCreated(
  "groups/{groupId}/activity/{activityId}",
  async (event) => {
    const activity = event.data?.data();
    if (!activity) return;

    const groupId = event.params.groupId;
    const groupSnap = await db.collection("groups").doc(groupId).get();
    const group = groupSnap.data();
    if (!group) return;

    // Filter recipients (exclude actor)
    const recipientUids = (group.memberUids || []).filter(
      (uid) => uid !== activity.actorUid
    );
    if (recipientUids.length === 0) return;

    // Batch fetch FCM tokens for all recipients
    const tokenRefs = recipientUids.map((uid) => db.collection("fcmTokens").doc(uid));
    const tokenSnaps = await db.getAll(...tokenRefs);

    const tokens = [];
    const tokenUidMap = []; // Keep track of which UID corresponds to each token index

    tokenSnaps.forEach((snap, idx) => {
      if (snap.exists && snap.data()?.token) {
        tokens.push(snap.data().token);
        tokenUidMap.push(recipientUids[idx]);
      }
    });

    if (tokens.length === 0) return;

    const groupName = group.name || "RingTogether";
    let title = groupName;
    let body = activity.message || "New activity in group";

    if (activity.kind === "alarm_changed") {
      title = `⏰ ${groupName}`;
    } else if (activity.kind === "response") {
      title = `📢 ${groupName}`;
    } else if (activity.kind === "joined") {
      title = `👋 ${groupName}`;
    } else if (activity.kind === "left" || activity.kind === "removed") {
      title = `👥 ${groupName}`;
    } else if (activity.kind === "alarm_silent") {
      title = `😴 ${groupName}`;
    }

    // iOS: a real alert + category so the RSVP action buttons appear.
    const aps = {
      alert: { title, body },
      sound: "default",
      badge: 1,
    };
    if (group.type === "event") {
      aps.category = "EVENT_REMINDER_CATEGORY";
    }

    // DATA-ONLY message (no top-level `notification`). On Android a message with
    // a `notification` block is drawn by the system when the app is backgrounded
    // or killed and `onMessageReceived` never runs — so the app can't attach the
    // Coming/Late/Can't action buttons. Sending data-only makes `onMessageReceived`
    // fire in every state, so the client always builds the notification (with its
    // RSVP actions for events) itself. `groupType` lets it decide without a lookup.
    const payload = {
      tokens,
      data: {
        groupId: groupId || "",
        activityId: event.params.activityId || "",
        kind: activity.kind || "",
        actorUid: activity.actorUid || "",
        groupType: group.type || "",
        title,
        body,
      },
      android: { priority: "high" },
      apns: {
        payload: {
          aps,
        },
      },
    };

    const batchResponse = await getMessaging().sendEachForMulticast(payload);

    // Diagnostic logging: surface per-token send outcomes so APNs/FCM errors
    // (invalid credentials, wrong environment, unregistered tokens) are visible
    // in Cloud Logging instead of failing silently.
    console.log(
      `activityPush group=${groupId} kind=${activity.kind} recipients=${recipientUids.length} ` +
      `tokens=${tokens.length} success=${batchResponse.successCount} failure=${batchResponse.failureCount}`
    );
    batchResponse.responses.forEach((resp, index) => {
      if (!resp.success) {
        console.error(
          `activityPush send failed uid=${tokenUidMap[index]} ` +
          `code=${resp.error?.code} message=${resp.error?.message}`
        );
      }
    });

    // Stale token cleanup
    const cleanupPromises = [];
    batchResponse.responses.forEach((resp, index) => {
      if (!resp.success) {
        const errorCode = resp.error?.code;
        if (
          errorCode === "messaging/registration-token-not-registered" ||
          errorCode === "messaging/invalid-registration-token"
        ) {
          const invalidUid = tokenUidMap[index];
          if (invalidUid) {
            cleanupPromises.push(db.collection("fcmTokens").doc(invalidUid).delete());
          }
        }
      }
    });

    if (cleanupPromises.length > 0) {
      await Promise.all(cleanupPromises);
    }
  }
);

/**
 * Admin nudge for event non-responders, triggered by the client writing a doc
 * to `groups/{groupId}/reminders/{reminderId}` = { byUid }.
 *
 * A Firestore trigger (not a callable) so neither client needs the Functions
 * SDK — they already write Firestore. The server is authoritative for the cap
 * (max 5 per event, >= 5 min apart) and persists `reminderCount` /
 * `lastReminderAt` on the GROUP doc, so the "N left" count survives app reload.
 *
 * Non-responders are computed from the `statuses` subcollection (a member has
 * "responded" only with an event status of coming/running_late/cant_make_it),
 * and the nudging admin is always excluded.
 */
const RESPONDED_EVENT_STATUSES = ["coming", "running_late", "cant_make_it"];
const MAX_REMINDERS = 5;
const MIN_MINUTES_BETWEEN_REMINDERS = 5;

exports.sendEventReminder = onDocumentCreated(
  "groups/{groupId}/reminders/{reminderId}",
  async (event) => {
    const groupId = event.params.groupId;
    const trigger = event.data?.data();
    const triggerRef = event.data?.ref;
    if (!trigger) return;

    // The trigger doc is single-use bookkeeping; always clean it up on exit.
    const done = async () => {
      if (triggerRef) await triggerRef.delete().catch(() => {});
    };

    const byUid = trigger.byUid;
    const groupRef = db.collection("groups").doc(groupId);
    const groupSnap = await groupRef.get();
    const group = groupSnap.data();
    if (!group) return done();

    // Only admins may nudge.
    if (!byUid || !(group.adminUids || []).includes(byUid)) return done();

    // Server-enforced cap: max 5 per event, >= 5 minutes apart.
    const reminderCount = group.reminderCount || 0;
    const lastReminderAt = group.lastReminderAt ? group.lastReminderAt.toDate() : null;
    if (reminderCount >= MAX_REMINDERS) return done();
    if (lastReminderAt) {
      const elapsedMinutes = (Date.now() - lastReminderAt.getTime()) / (1000 * 60);
      if (elapsedMinutes < MIN_MINUTES_BETWEEN_REMINDERS) return done();
    }

    // Non-responders = members with no "responded" event status, minus the admin.
    const memberUids = group.memberUids || [];
    const statusesSnap = await groupRef.collection("statuses").get();
    const responded = new Set();
    statusesSnap.forEach((doc) => {
      if (RESPONDED_EVENT_STATUSES.includes(doc.data()?.status)) responded.add(doc.id);
    });
    const targetUids = memberUids.filter((uid) => uid !== byUid && !responded.has(uid));

    if (targetUids.length > 0) {
      const tokenSnaps = await db.getAll(
        ...targetUids.map((uid) => db.collection("fcmTokens").doc(uid))
      );
      const tokens = [];
      const tokenUidMap = [];
      tokenSnaps.forEach((snap, idx) => {
        if (snap.exists && snap.data()?.token) {
          tokens.push(snap.data().token);
          tokenUidMap.push(targetUids[idx]);
        }
      });

      if (tokens.length > 0) {
        const groupName = group.name || "WhoZup";
        const eventTitle = group.eventTitle || groupName;
        const title = `🔔 ${groupName}`;
        const body = `Reminder: please respond to "${eventTitle}"`;
        // Data-only for Android (so onMessageReceived fires when killed and the
        // RSVP buttons are attached); alert + category for iOS. See activityPush.
        const batchResponse = await getMessaging().sendEachForMulticast({
          tokens,
          data: {
            groupId: groupId || "",
            kind: "event_reminder",
            groupType: "event",
            title,
            body,
          },
          android: { priority: "high" },
          apns: {
            payload: {
              aps: {
                alert: { title, body },
                sound: "default",
                badge: 1,
                category: "EVENT_REMINDER_CATEGORY",
              },
            },
          },
        });

        console.log(
          `sendEventReminder group=${groupId} targets=${targetUids.length} ` +
          `tokens=${tokens.length} success=${batchResponse.successCount} failure=${batchResponse.failureCount}`
        );

        const cleanupPromises = [];
        batchResponse.responses.forEach((resp, index) => {
          if (!resp.success) {
            console.error(
              `sendEventReminder send failed uid=${tokenUidMap[index]} ` +
              `code=${resp.error?.code} message=${resp.error?.message}`
            );
            const code = resp.error?.code;
            if (
              code === "messaging/registration-token-not-registered" ||
              code === "messaging/invalid-registration-token"
            ) {
              cleanupPromises.push(db.collection("fcmTokens").doc(tokenUidMap[index]).delete());
            }
          }
        });
        if (cleanupPromises.length > 0) await Promise.all(cleanupPromises);
      }
    }

    // Persist the cap state on the group doc so "N left" is authoritative and
    // survives reload. Done even when no tokens resolved, so a nudge to members
    // who happen to have no token still counts against the cap.
    await groupRef.update({
      reminderCount: FieldValue.increment(1),
      lastReminderAt: FieldValue.serverTimestamp(),
    });

    return done();
  }
);

/**
 * When a member joins via an admin-flagged invite, grant them admin.
 */
exports.applyInviteAdminOnJoin = onDocumentCreated(
  "groups/{groupId}/members/{memberId}",
  async (event) => {
    const groupId = event.params.groupId;
    const memberId = event.params.memberId;

    const groupSnap = await db.collection("groups").doc(groupId).get();
    const group = groupSnap.data();
    if (!group) return;
    if ((group.adminUids || []).includes(memberId)) return;

    const inviteSnap = await db.collection("invites").doc(group.inviteCode).get();
    const invite = inviteSnap.data();
    if (invite?.asAdmin === true) {
      await db.collection("groups").doc(groupId).update({
        adminUids: FieldValue.arrayUnion(memberId),
      });
    }
  }
);

// Plans: headcount asks (scheduled + Ask now). Required after initializeApp().
const headcount = require("./headcount");
exports.headcountScheduler = headcount.headcountScheduler;
exports.headcountAskNow = headcount.headcountAskNow;
