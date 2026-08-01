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
 *      Enforces server-side caps: max 2 reminders per event, minimum 5 minutes apart.
 *
 *   3. applyInviteAdminOnJoin — when a member joins via an admin-flagged invite,
 *      grants admin role.
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
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
    }

    const payload = {
      tokens,
      notification: {
        title,
        body,
      },
      data: {
        groupId: groupId || "",
        activityId: event.params.activityId || "",
        kind: activity.kind || "",
        actorUid: activity.actorUid || "",
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
    };

    const batchResponse = await getMessaging().sendEachForMulticast(payload);

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
 * HTTPS Callable: Admin nudge/reminder for event non-responders.
 * Enforces max 2 reminders per event, min 5 minutes apart.
 */
exports.adminReminderPush = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const callerUid = request.auth.uid;
  const { groupId, eventId } = request.data || {};

  if (!groupId || !eventId) {
    throw new HttpsError("invalid-argument", "groupId and eventId are required.");
  }

  const groupSnap = await db.collection("groups").doc(groupId).get();
  const group = groupSnap.data();

  if (!group) {
    throw new HttpsError("not-found", "Group not found.");
  }

  // Check caller is admin
  const isAdmin = (group.adminUids || []).includes(callerUid);
  if (!isAdmin) {
    throw new HttpsError("permission-denied", "Only group admins can send reminders.");
  }

  const eventRef = db.collection("groups").doc(groupId).collection("events").doc(eventId);
  const eventSnap = await eventRef.get();
  const eventData = eventSnap.data();

  if (!eventData) {
    throw new HttpsError("not-found", "Event not found.");
  }

  const reminderCount = eventData.reminderCount || 0;
  const lastReminderTime = eventData.lastReminderAt ? eventData.lastReminderAt.toDate() : null;

  if (reminderCount >= 2) {
    throw new HttpsError("resource-exhausted", "Maximum of 2 reminders per event reached.");
  }

  const now = new Date();
  if (lastReminderTime) {
    const elapsedMinutes = (now.getTime() - lastReminderTime.getTime()) / (1000 * 60);
    if (elapsedMinutes < 5) {
      const waitTime = Math.ceil(5 - elapsedMinutes);
      throw new HttpsError(
        "failed-precondition",
        `Please wait ${waitTime} more minute(s) before sending another reminder.`
      );
    }
  }

  // Find members who haven't responded yet
  const responses = eventData.responses || {};
  const nonResponders = (group.memberUids || []).filter(
    (uid) => !responses[uid] || responses[uid] === "no_response"
  );

  if (nonResponders.length === 0) {
    return { success: true, sentCount: 0, message: "All members have already responded." };
  }

  // Fetch FCM tokens for non-responders
  const tokenRefs = nonResponders.map((uid) => db.collection("fcmTokens").doc(uid));
  const tokenSnaps = await db.getAll(...tokenRefs);
  const tokens = [];

  tokenSnaps.forEach((snap) => {
    if (snap.exists && snap.data()?.token) {
      tokens.push(snap.data().token);
    }
  });

  if (tokens.length > 0) {
    const title = `🔔 ${group.name || "RingTogether"} Reminder`;
    const body = `Admin reminder: Please respond to event "${eventData.title || "Event"}"`;

    await getMessaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      data: { groupId, eventId, kind: "event_reminder" },
      apns: { payload: { aps: { sound: "default" } } },
    });
  }

  // Update reminder count & last timestamp
  await eventRef.update({
    reminderCount: FieldValue.increment(1),
    lastReminderAt: FieldValue.serverTimestamp(),
  });

  return {
    success: true,
    sentCount: tokens.length,
    remainingReminders: 2 - (reminderCount + 1),
  };
});

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
