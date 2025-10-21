// seed-emulator.js
// ──────────────────────────────────────────────
// Seeds Firestore EMULATOR with users, drivers, and scheduled_notifications.
// Run this while your Firebase emulators are running.
// Usage: node seed-emulator.js
// ──────────────────────────────────────────────

process.env.FIRESTORE_EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";

const admin = require("firebase-admin");

// Initialize emulator connection
try {
  admin.app();
} catch {
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || "demo-project" });
}

const db = admin.firestore();

(async () => {
  const now = Date.now();
  const tsIn = (ms) => admin.firestore.Timestamp.fromDate(new Date(ms));

  // ───────── USERS ─────────
  const users = [
    // ✅ Your real FCM token (replace below if regenerated)
    {
      id: "test-user-123",
      fcmToken:
        "f-1umC-2TLykIHqNkmi5nY:APA91bGyJo0kvlzD1Tp42eKkZMmESTXMQIQd87P74UccPIuvsSCYHWOFyLJRfkf2bXYSKmBDceoZiVPsEHFkHadgYdKPzHUsDX9khjUFusa4LbV7l6XVMso",
    },
    // ❌ No token (to test failure case)
    { id: "test-user-no-token" },
  ];

  // ───────── DRIVERS ─────────
  const drivers = [
    {
      id: "driver-007",
      fcmToken:
        "f-1umC-2TLykIHqNkmi5nY:APA91bGyJo0kvlzD1Tp42eKkZMmESTXMQIQd87P74UccPIuvsSCYHWOFyLJRfkf2bXYSKmBDceoZiVPsEHFkHadgYdKPzHUsDX9khjUFusa4LbV7l6XVMso",
    },
  ];

  // ───────── WRITE USERS / DRIVERS ─────────
  await Promise.all(users.map((u) => db.collection("users").doc(u.id).set(u, { merge: true })));
  await Promise.all(drivers.map((d) => db.collection("drivers").doc(d.id).set(d, { merge: true })));

  // ───────── SCHEDULED NOTIFICATIONS ─────────
  const docs = [
    // ✅ In-window (~8 min from now) → should send successfully
    {
      id: "sched-user-in-window",
      userId: "test-user-123",
      isDriver: false,
      origin: "USM",
      destination: "Penang Sentral",
      time: "14:30",
      type: "trip_reminder",
      status: "scheduled",
      reminderTime: tsIn(now + 8 * 60 * 1000),
    },
    // ✅ In-window (~9 min from now) → driver
    {
      id: "sched-driver-in-window",
      userId: "driver-007",
      isDriver: true,
      origin: "KDU",
      destination: "Queensbay Mall",
      time: "15:00",
      type: "trip_reminder",
      status: "scheduled",
      reminderTime: tsIn(now + 9 * 60 * 1000),
    },
    // ⏭ Out-of-window (tomorrow) → should be skipped
    {
      id: "sched-future-skip",
      userId: "test-user-123",
      isDriver: false,
      origin: "INTI Penang",
      destination: "Gurney Plaza",
      time: "10:00",
      type: "trip_reminder",
      status: "scheduled",
      reminderTime: tsIn(now + 24 * 60 * 60 * 1000),
    },
    // ❌ In-window but user has NO token → fail “No FCM token”
    {
      id: "sched-no-token",
      userId: "test-user-no-token",
      isDriver: false,
      origin: "USM",
      destination: "KOMTAR",
      time: "16:00",
      type: "trip_reminder",
      status: "scheduled",
      reminderTime: tsIn(now + 7 * 60 * 1000),
    },
    // ❌ In-window, missing user → fail “User not found”
    {
      id: "sched-user-missing",
      userId: "ghost-user-999",
      isDriver: false,
      origin: "Penang Sentral",
      destination: "Airport",
      time: "18:00",
      type: "trip_reminder",
      status: "scheduled",
      reminderTime: tsIn(now + 6 * 60 * 1000),
    },
  ];

  await Promise.all(docs.map((d) => db.collection("scheduled_notifications").doc(d.id).set(d)));

  console.log("\n✅ Firestore emulator seeded successfully!");
  console.log("──────────────────────────────────────────");
  console.table(
    docs.map((d) => ({
      id: d.id,
      userId: d.userId,
      isDriver: d.isDriver,
      minutesUntilSend: Math.round((d.reminderTime.toDate() - new Date()) / 60000),
    }))
  );
  process.exit(0);
})();
