/**
 * Plans: headcount asks.
 *
 *   headcountScheduler — every 5 minutes, sends each plan's scheduled asks
 *     (`groups/{id}.headcountAsks`) that came due, once per session.
 *   headcountAskNow — when a host writes `groups/{id}/asks/{askId}` with
 *     `{byUid, audience, question, note?, sessionKey}`, sends it now
 *     (admins only, at most 5 per session).
 *
 * Every send is logged as an `asks` doc (`sentAt`, `sentCount`), which is also
 * what keeps a scheduled ask from going twice. Pushes are data-only on Android
 * (the app builds the notification with answer buttons) and carry the
 * HEADCOUNT_CATEGORY on iOS. See docs/plans-build.md.
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

const db = getFirestore();
const DEFAULT_ZONE = "Asia/Kolkata";
const MAX_ASK_NOW_PER_SESSION = 5;
const SESSION_GRACE_MS = 2 * 60 * 60 * 1000;
const EVENT_YES = ["coming", "running_late"];
const EVENT_ANSWERED = ["coming", "running_late", "cant_make_it"];

// MARK: Time zones (no date library in this project)

/** The UTC instant for a wall-clock time in `zone`. */
function zonedInstant(y, m, d, h, min, zone) {
  let guess = Date.UTC(y, m - 1, d, h, min);
  for (let i = 0; i < 2; i++) {
    const p = parts(new Date(guess), zone);
    const asUtc = Date.UTC(p.y, p.m - 1, p.d, p.h, p.min);
    guess += Date.UTC(y, m - 1, d, h, min) - asUtc;
  }
  return new Date(guess);
}

/** Wall-clock parts of `date` in `zone`, with weekday 1=Sunday … 7=Saturday. */
function parts(date, zone) {
  const f = new Intl.DateTimeFormat("en-US", {
    timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", weekday: "short", hourCycle: "h23",
  });
  const o = {};
  for (const { type, value } of f.formatToParts(date)) o[type] = value;
  const weekdays = { Sun: 1, Mon: 2, Tue: 3, Wed: 4, Thu: 5, Fri: 6, Sat: 7 };
  return { y: +o.year, m: +o.month, d: +o.day, h: +o.hour % 24, min: +o.minute, weekday: weekdays[o.weekday] };
}

const pad = (n) => String(n).padStart(2, "0");
const dayKey = (date, zone) => { const p = parts(date, zone); return `${p.y}-${pad(p.m)}-${pad(p.d)}`; };

// MARK: Sessions (mirrors GroupRepository.planSessions on both clients)

/** The next session start of a plan, or null. Events (one-time plans) use `eventAt`. */
function nextSession(group, now, zone) {
  if (group.planKind === "once") {
    const at = group.eventAt?.toDate();
    return at && at.getTime() + SESSION_GRACE_MS > now.getTime() ? at : null;
  }
  if (group.planKind === "onceAlarm") {
    const at = group.meetAt?.toDate();
    return at && at.getTime() + SESSION_GRACE_MS > now.getTime() ? at : null;
  }
  if (group.planKind === "repeat" && group.startTime) {
    const [h, min] = group.startTime.split(":").map(Number);
    const lead = group.hasAlarm === false ? 0 : (group.alarmLeadMinutes || 0);
    const crosses = h * 60 + min - lead < 0;
    const days = new Set((group.alarmDays || []).map((d) => (crosses ? (d === 7 ? 1 : d + 1) : d)));
    for (let offset = 0; offset < 21; offset++) {
      const p = parts(new Date(now.getTime() + offset * 86400000), zone);
      const start = zonedInstant(p.y, p.m, p.d, h, min, zone);
      if ((days.size === 0 || days.has(p.weekday)) && start.getTime() + SESSION_GRACE_MS > now.getTime()) return start;
    }
  }
  return null;
}

/** When a scheduled ask is due for a session starting at `start`. */
function dueAt(ask, start, zone) {
  if (typeof ask.offsetMinutes === "number") return new Date(start.getTime() + ask.offsetMinutes * 60000);
  if (ask.dayBeforeAt) {
    const [h, min] = ask.dayBeforeAt.split(":").map(Number);
    const p = parts(new Date(start.getTime() - 86400000), zone);
    return zonedInstant(p.y, p.m, p.d, h, min, zone);
  }
  return null; // "invite" / "alarmRings" aren't sent on a clock
}

// MARK: Audience

/**
 * Who an ask goes to. One-time plans read event answers from `statuses`;
 * plans with sessions read `sessions/{key}/responses`. Skippers never get asked.
 */
async function audienceFor(groupRef, group, sessionKey, audience, excludeUid) {
  const members = (group.memberUids || []).filter((uid) => uid !== excludeUid);
  const answers = {};
  if (group.planKind === "once" || group.type === "event") {
    (await groupRef.collection("statuses").get()).forEach((doc) => { answers[doc.id] = doc.data()?.status; });
  } else {
    (await groupRef.collection("sessions").doc(sessionKey).collection("responses").get())
      .forEach((doc) => { answers[doc.id] = doc.data()?.status; });
  }
  const inByDefault = group.planKind === "repeat" && group.attendanceDefault !== "ask";
  const answered = (uid) => EVENT_ANSWERED.includes(answers[uid]) || answers[uid] === "skipping" || (inByDefault && answers[uid] !== undefined);
  const saidYes = (uid) => EVENT_YES.includes(answers[uid]) || (inByDefault && answers[uid] === undefined);
  const skipping = (uid) => answers[uid] === "skipping" || answers[uid] === "cant_make_it";
  return members.filter((uid) => {
    if (skipping(uid)) return false;
    if (audience === "unanswered") return !answered(uid) && !(inByDefault);
    if (audience === "yes") return saidYes(uid);
    return true;
  });
}

// MARK: Sending

async function sendAsk({ groupId, group, sessionKey, question, note, uids }) {
  if (uids.length === 0) return 0;
  const snaps = await db.getAll(...uids.map((uid) => db.collection("fcmTokens").doc(uid)));
  const tokens = [];
  const owners = [];
  snaps.forEach((snap, i) => {
    if (snap.exists && snap.data()?.token) { tokens.push(snap.data().token); owners.push(uids[i]); }
  });
  if (tokens.length === 0) return 0;

  const name = group.name || "WhoZup";
  const title = `${name}: ${question}`;
  const body = note || (group.planKind === "once" ? "Tap to answer." : "Tap to answer for this session.");
  const response = await getMessaging().sendEachForMulticast({
    tokens,
    data: {
      kind: "headcount", groupId, sessionKey, question, title, body,
      groupType: group.type || "", planKind: group.planKind || "",
    },
    android: { priority: "high" },
    apns: { payload: { aps: { alert: { title, body }, sound: "default", category: "HEADCOUNT_CATEGORY" } } },
  });
  const cleanup = [];
  response.responses.forEach((r, i) => {
    const code = r.error?.code;
    if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token") {
      cleanup.push(db.collection("fcmTokens").doc(owners[i]).delete());
    }
  });
  await Promise.all(cleanup);
  return response.successCount;
}

// MARK: Functions

exports.headcountScheduler = onSchedule({ schedule: "every 5 minutes", region: "asia-south1" }, async () => {
  const now = new Date();
  const windowStart = now.getTime() - 5 * 60000;
  const plans = await db.collection("groups").where("planKind", "in", ["once", "onceAlarm", "repeat"]).get();
  for (const doc of plans.docs) {
    const group = doc.data();
    const asks = group.headcountAsks || [];
    if (asks.length === 0) continue;
    const zone = group.alarmTimeZone || DEFAULT_ZONE;
    const start = nextSession(group, now, zone);
    if (!start) continue;
    const sessionKey = dayKey(start, zone);
    for (const ask of asks) {
      const due = dueAt(ask, start, zone);
      if (!due || due.getTime() > now.getTime() || due.getTime() <= windowStart - 10 * 60000) continue;
      // Once per session and ask: the log doc's id is the guard.
      const logRef = doc.ref.collection("asks").doc(`${sessionKey}_${ask.id}`);
      const created = await logRef.create({
        scheduled: true, askId: ask.id, sessionKey, audience: ask.audience, question: ask.question,
        createdAt: FieldValue.serverTimestamp(),
      }).then(() => true, () => false);
      if (!created) continue;
      const uids = await audienceFor(doc.ref, group, sessionKey, ask.audience, null);
      const sent = await sendAsk({ groupId: doc.id, group, sessionKey, question: ask.question, note: null, uids });
      await logRef.update({ sentAt: FieldValue.serverTimestamp(), sentCount: sent, targetCount: uids.length });
      console.log(`headcountScheduler group=${doc.id} ask=${ask.id} session=${sessionKey} targets=${uids.length} sent=${sent}`);
    }
  }
});

exports.headcountAskNow = onDocumentCreated(
  { document: "groups/{groupId}/asks/{askId}", region: "asia-south1" },
  async (event) => {
    const ask = event.data?.data();
    const ref = event.data?.ref;
    if (!ask || ask.scheduled || !ref) return; // scheduled asks are sent by the scheduler
    const groupRef = db.collection("groups").doc(event.params.groupId);
    const group = (await groupRef.get()).data();
    if (!group || !(group.adminUids || []).includes(ask.byUid)) {
      await ref.update({ rejected: "not an admin" });
      return;
    }
    const sessionKey = ask.sessionKey;
    const earlier = await groupRef.collection("asks")
      .where("sessionKey", "==", sessionKey).where("manual", "==", true).get();
    if (earlier.size > MAX_ASK_NOW_PER_SESSION) {
      await ref.update({ rejected: "limit" });
      return;
    }
    const uids = await audienceFor(groupRef, group, sessionKey, ask.audience || "unanswered", ask.byUid);
    const sent = await sendAsk({
      groupId: event.params.groupId, group, sessionKey,
      question: ask.question || "Can you make it?", note: ask.note || null, uids,
    });
    await ref.update({ sentAt: FieldValue.serverTimestamp(), sentCount: sent, targetCount: uids.length });
    console.log(`headcountAskNow group=${event.params.groupId} session=${sessionKey} targets=${uids.length} sent=${sent}`);
  }
);

// Exposed for tests.
exports._internal = { zonedInstant, parts, nextSession, dueAt, dayKey, Timestamp };
