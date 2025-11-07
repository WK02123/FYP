"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null) for (var k in mod) if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.placesText = exports.directions = exports.testPushNotification = exports.testScheduledNotifications = exports.runScheduledOnce = exports.checkScheduledNotifications = exports.sendTripReminder = exports.sendCancellationEmail = exports.sendBookingEmail = exports.refundPayment = exports.createPaymentIntent = exports.hello = exports.onStudentTripCreated = exports.reportDriverIssue = void 0;
// functions/src/index.ts
const https_1 = require("firebase-functions/v2/https");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const firestore_1 = require("firebase-functions/v2/firestore");
const v2_1 = require("firebase-functions/v2");
const dotenv = __importStar(require("dotenv"));
const admin = __importStar(require("firebase-admin"));
const params_1 = require("firebase-functions/params");
const path = __importStar(require("path"));
/* ========= Places Text Search Endpoint ========= */
/* ─────────────────────────────────────────────────────────────
   Environment bootstrap
   - Loads normal .env
   - Loads .env.local only when running the emulator
   - Provides readSecret() to unify emulator vs prod secrets
   ───────────────────────────────────────────────────────────── */
dotenv.config();
const IS_EMULATOR = process.env.FUNCTIONS_EMULATOR === "true" ||
    process.env.FIREBASE_EMULATOR_HUB !== undefined;
if (IS_EMULATOR) {
    dotenv.config({ path: path.join(__dirname, "..", ".env.local") });
}
const readSecret = (name, param) => {
    if (IS_EMULATOR)
        return process.env[name] ?? "";
    return param ? param.value() : "";
};
/* ───────────────────────────────────────────────────────────── */
const REGION = "asia-southeast1";
// Firebase Admin — initialize once
if (!admin.apps.length) {
    admin.initializeApp();
    v2_1.logger.info("✅ firebase-admin initialized");
}
// Secrets (prod via CLI)
//   firebase functions:secrets:set STRIPE_SECRET
//   firebase functions:secrets:set SENDGRID_API_KEY
//   firebase functions:secrets:set GOOGLE_DIRECTIONS_KEY
const STRIPE_SECRET = (0, params_1.defineSecret)("STRIPE_SECRET");
const SENDGRID_API_KEY = (0, params_1.defineSecret)("SENDGRID_API_KEY");
const GOOGLE_DIRECTIONS_KEY = (0, params_1.defineSecret)("GOOGLE_DIRECTIONS_KEY");
// Small accessor so we never think about env again
// (underscored to silence ESLint unused-var rule)
const _getGoogleMapsKey = () => readSecret("GOOGLE_DIRECTIONS_KEY", GOOGLE_DIRECTIONS_KEY);
/* ------------------------------------------------------------------
   Callable: Driver reports an issue → notify affected students
-------------------------------------------------------------------*/
exports.reportDriverIssue = (0, https_1.onCall)({ region: REGION }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { origin, destination, date, time, type, note, delayMinutes } = (request.data ?? {});
    if (!origin || !destination || !date || !time) {
        throw new https_1.HttpsError("invalid-argument", "origin, destination, date, time are required");
    }
    try {
        const db = admin.firestore();
        const driverId = request.auth.uid;
        // 1) Log
        await db.collection("driver_issues").add({
            driverId,
            origin, destination, date, time,
            type: type ?? "Issue",
            note: note ?? "",
            delayMinutes: delayMinutes ?? 0,
            createdAt: new Date(),
        });
        // 2) Find students on that exact trip
        const qs = await db.collection("student_trips")
            .where("origin", "==", origin)
            .where("destination", "==", destination)
            .where("date", "==", date)
            .where("time", "==", time)
            .get();
        if (qs.empty) {
            v2_1.logger.info(`reportDriverIssue: no students for ${origin}→${destination} ${date} ${time}`);
            return { success: true, sent: 0 };
        }
        const delayText = delayMinutes && delayMinutes > 0 ? ` (~${delayMinutes} min delay)` : "";
        const body = `Route ${origin} → ${destination} at ${time} will be delayed${delayText}. ${type ?? "Issue"} reported by driver.`;
        // 3) Notify
        let sent = 0;
        for (const doc of qs.docs) {
            const trip = doc.data();
            const studentId = trip.studentId;
            if (!studentId)
                continue;
            const collectionsToCheck = ["users", "students", "profiles", "drivers"];
            let fcmToken = null;
            for (const col of collectionsToCheck) {
                const d = await db.collection(col).doc(studentId).get();
                if (d.exists) {
                    fcmToken = d.data()?.fcmToken ?? null;
                    if (fcmToken)
                        break;
                }
            }
            if (!fcmToken)
                continue;
            await admin.messaging().send({
                token: fcmToken,
                notification: { title: "⏱️ Route Delay Notice", body },
                data: {
                    type: "route_delay",
                    origin, destination, date, time,
                    channelId: "route_alerts",
                },
                android: { priority: "high", notification: { sound: "default", channelId: "route_alerts" } },
            });
            sent++;
        }
        v2_1.logger.info(`reportDriverIssue: sent ${sent} notifications for ${origin}→${destination} ${date} ${time}`);
        return { success: true, sent };
    }
    catch (e) {
        v2_1.logger.error("reportDriverIssue error:", e);
        throw new https_1.HttpsError("internal", e?.message ?? "Failed to process driver issue");
    }
});
/* ------------------------------------------------------------------
   Helpers for Stripe / SendGrid (kept same behavior as your code)
-------------------------------------------------------------------*/
const getStripe = () => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const Stripe = require("stripe");
    const isEmulator = process.env.FUNCTIONS_EMULATOR === "true" ||
        process.env.FIREBASE_EMULATOR_HUB !== undefined;
    const key = isEmulator ? process.env.STRIPE_SECRET : STRIPE_SECRET.value();
    if (!key)
        throw new Error("STRIPE_SECRET not configured");
    return new Stripe(key, { apiVersion: "2024-06-20" });
};
const getSendgridKey = () => {
    const isEmulator = process.env.FUNCTIONS_EMULATOR === "true" ||
        process.env.FIREBASE_EMULATOR_HUB !== undefined;
    const key = isEmulator ? process.env.SENDGRID_API_KEY : SENDGRID_API_KEY.value();
    if (!key)
        throw new Error("SENDGRID_API_KEY not configured");
    return key;
};
const getNodemailer = () => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    return require("nodemailer");
};
/* ------------------------------------------------------------------
   FCM token resolvers
-------------------------------------------------------------------*/
const resolveFcmToken = async (userId, isDriver = false) => {
    const db = admin.firestore();
    const tried = [];
    const cols = isDriver
        ? ["drivers", "users", "students", "profiles"]
        : ["users", "students", "profiles", "drivers"];
    for (const col of cols) {
        tried.push(`${col}/${userId}`);
        const doc = await db.collection(col).doc(userId).get();
        if (doc.exists) {
            const token = doc.data()?.fcmToken ?? null;
            if (token)
                return { fcmToken: token, tried };
        }
    }
    return { fcmToken: null, tried };
};
const resolveFcmTokenWith = async (_admin, userId, isDriver = false) => {
    const db = _admin.firestore();
    const tried = [];
    const cols = isDriver
        ? ["drivers", "users", "students", "profiles"]
        : ["users", "students", "profiles", "drivers"];
    for (const col of cols) {
        tried.push(`${col}/${userId}`);
        const doc = await db.collection(col).doc(userId).get();
        if (doc.exists) {
            const token = doc.data()?.fcmToken ?? null;
            if (token)
                return { fcmToken: token, tried };
        }
    }
    return { fcmToken: null, tried };
};
/* ------------------------------------------------------------------
   Firestore trigger: push "Booking confirmed" when student_trip is created
-------------------------------------------------------------------*/
exports.onStudentTripCreated = (0, firestore_1.onDocumentCreated)({ region: REGION, document: "student_trips/{tripId}" }, async (event) => {
    const snap = event.data;
    if (!snap)
        return;
    const trip = snap.data();
    const tripId = event.params.tripId;
    const studentId = trip?.studentId;
    if (!studentId) {
        v2_1.logger.warn(`onStudentTripCreated: missing studentId on ${tripId}`);
        return;
    }
    try {
        const logRef = admin.firestore()
            .collection("notification_logs")
            .doc(`booking_confirmed_${tripId}`);
        try {
            await logRef.create({
                type: "booking_confirmed",
                tripId,
                studentId,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        catch {
            v2_1.logger.info(`onStudentTripCreated: log exists for ${tripId}, skipping duplicate push.`);
            return;
        }
        const { fcmToken, tried } = await resolveFcmToken(studentId, false);
        if (!fcmToken) {
            v2_1.logger.warn(`onStudentTripCreated: no FCM token for ${studentId}. Tried: ${tried.join(", ")}`);
            await logRef.update({ status: "failed", reason: "no_fcm_token", tried });
            return;
        }
        const origin = trip.origin ?? "";
        const destination = trip.destination ?? "";
        const date = trip.date ?? "";
        const timeText = trip.time12 ?? trip.time ?? "";
        await admin.messaging().send({
            token: fcmToken,
            notification: { title: "✅ Booking confirmed", body: `${origin} → ${destination} on ${date} • ${timeText}` },
            data: {
                type: "booking_confirmed",
                origin, destination, date, time: timeText, tripId, channelId: "booking_updates",
            },
            android: { priority: "high", notification: { sound: "default", channelId: "booking_updates" } },
        });
        await logRef.update({ status: "sent", sentAt: new Date().toISOString() });
        v2_1.logger.info(`📣 Booking-confirmed push sent for ${tripId} to ${studentId}`);
    }
    catch (e) {
        v2_1.logger.error("onStudentTripCreated push failed:", e);
    }
}); // keep this closing );
/* ------------------------------------------------------------------
   Email template helpers
-------------------------------------------------------------------*/
const getEmailStyles = () => `
  body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f5f5f5; }
  .email-container { max-width: 600px; margin: 0 auto; background-color: #ffffff; }
  .header { background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); padding: 40px 20px; text-align: center; }
  .logo { font-size: 32px; font-weight: bold; color: #ffffff; margin: 0; }
  .content { padding: 40px 30px; }
  .title { font-size: 28px; font-weight: bold; color: #1f2937; margin: 0 0 10px 0; }
  .subtitle { font-size: 16px; color: #6b7280; margin: 0 0 30px 0; }
  .card { background-color: #f9fafb; border-radius: 12px; padding: 24px; margin-bottom: 24px; border: 1px solid #e5e7eb; }
  .route { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; padding: 16px; background-color: #ffffff; border-radius: 8px; }
  .location { font-size: 18px; font-weight: 600; color: #1f2937; }
  .arrow { font-size: 24px; color: #ef4444; margin: 0 10px; }
  .info-row { display: flex; justify-content: space-between; padding: 12px 0; border-bottom: 1px solid #e5e7eb; }
  .info-row:last-child { border-bottom: none; }
  .info-label { font-size: 14px; color: #6b7280; font-weight: 500; }
  .info-value { font-size: 14px; color: #1f2937; font-weight: 600; }
`;
const getBookingEmailHTML = (origin, destination, date, time, seats, totalAmount) => `
<!DOCTYPE html>
<html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>${getEmailStyles()}</style>
</head>
<body>
  <div class="email-container">
    <div class="header"><h1 class="logo">🚌 Ridemate</h1></div>
    <div class="content">
      <h1 class="title">🎉 Booking Confirmed!</h1>
      <p class="subtitle">Your shuttle reservation is all set. Get ready for a comfortable ride!</p>
      <div class="card">
        <div class="route"><div class="location">${origin}</div><div class="arrow">→</div><div class="location">${destination}</div></div>
        <div class="info-row"><span class="info-label">📅 Date</span><span class="info-value">${date}</span></div>
        <div class="info-row"><span class="info-label">🕐 Time</span><span class="info-value">${time}</span></div>
        <div class="info-row"><span class="info-label">💺 Seat(s)</span><span class="info-value">${seats}</span></div>
      </div>
      <div class="card">
        <div class="info-row"><span class="info-label">Total Paid</span><span class="info-value">RM ${totalAmount}</span></div>
      </div>
    </div>
    <div class="footer">
      <p>Need help? Contact us at <a href="mailto:heartx8880@gmail.com">heartx8880@gmail.com</a></p>
      <p style="margin-top: 16px;">© ${new Date().getFullYear()} Ridemate Shuttle</p>
    </div>
  </div>
</body></html>
`;
const getCancellationEmailHTML = (origin, destination, date, time, refundAmount) => `
<!DOCTYPE html>
<html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>${getEmailStyles()}</style>
</head>
<body>
  <div class="email-container">
    <div class="header"><h1 class="logo">🚌 Ridemate</h1></div>
    <div class="content">
      <h1 class="title">Booking Cancelled</h1>
      <div class="card">
        <div class="route"><div class="location">${origin}</div><div class="arrow">→</div><div class="location">${destination}</div></div>
        <div class="info-row"><span class="info-label">📅 Date</span><span class="info-value">${date}</span></div>
        <div class="info-row"><span class="info-label">🕐 Time</span><span class="info-value">${time}</span></div>
        <div class="info-row"><span class="info-label">📋 Status</span><span class="info-value" style="color:#dc2626;">Cancelled</span></div>
      </div>
      <div class="card">
        <div class="info-row"><span class="info-label">Refund Amount</span><span class="info-value">RM ${refundAmount}</span></div>
        <div class="info-row"><span class="info-label">Processing</span><span class="info-value">5–10 business days</span></div>
      </div>
    </div>
    <div class="footer">
      <p>Need help? Contact us at <a href="mailto:heartx8880@gmail.com">heartx8880@gmail.com</a></p>
      <p style="margin-top: 16px;">© ${new Date().getFullYear()} Ridemate Shuttle</p>
    </div>
  </div>
</body></html>
`;
/* ------------------------------------------------------------------
   Health check
-------------------------------------------------------------------*/
exports.hello = (0, https_1.onRequest)({ region: REGION }, (_req, res) => {
    res.status(200).send("ok");
});
/* ------------------------------------------------------------------
   Stripe: Create Payment Intent / Refund
-------------------------------------------------------------------*/
exports.createPaymentIntent = (0, https_1.onCall)({ region: REGION, secrets: [STRIPE_SECRET] }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { amount, currency = "myr", description = "Bus ticket payment" } = (request.data ?? {});
    const numAmount = Number(amount);
    if (!Number.isFinite(numAmount) || numAmount <= 0) {
        throw new https_1.HttpsError("invalid-argument", "amount must be > 0");
    }
    try {
        const stripe = getStripe();
        const pi = await stripe.paymentIntents.create({
            amount: Math.trunc(numAmount),
            currency: currency.toLowerCase(),
            description,
            automatic_payment_methods: { enabled: true },
            metadata: { userId: request.auth.uid, description },
        });
        return { clientSecret: pi.client_secret };
    }
    catch (err) {
        const e = err;
        v2_1.logger.error("Stripe error:", e);
        throw new https_1.HttpsError("internal", e?.message ?? "Payment processing failed");
    }
});
exports.refundPayment = (0, https_1.onCall)({ region: REGION, secrets: [STRIPE_SECRET] }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { paymentIntentId, amount } = (request.data ?? {});
    if (!paymentIntentId)
        throw new https_1.HttpsError("invalid-argument", "paymentIntentId is required");
    try {
        const stripe = getStripe();
        const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
        const latestCharge = pi.latest_charge;
        if (!latestCharge)
            throw new https_1.HttpsError("failed-precondition", "No charge found for this payment");
        const chargeId = typeof latestCharge === "string" ? latestCharge : latestCharge.id;
        const refund = await stripe.refunds.create({
            charge: chargeId,
            amount: amount && amount > 0 ? Math.trunc(amount) : undefined,
            metadata: { userId: request.auth.uid, refundedAt: new Date().toISOString() },
        });
        v2_1.logger.info("Refund created:", refund.id);
        return { success: true, refundId: refund.id, amount: refund.amount, status: refund.status };
    }
    catch (err) {
        const e = err;
        v2_1.logger.error("Refund error:", e);
        throw new https_1.HttpsError("internal", e?.message ?? "Refund processing failed");
    }
});
/* ------------------------------------------------------------------
   SendGrid emails (SMTP via Nodemailer)
-------------------------------------------------------------------*/
exports.sendBookingEmail = (0, https_1.onCall)({ region: REGION, secrets: [SENDGRID_API_KEY] }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { email, origin, destination, date, time, seats, totalAmount } = (request.data ?? {});
    if (!email)
        throw new https_1.HttpsError("invalid-argument", "Email is required");
    try {
        const nodemailer = getNodemailer();
        const transporter = nodemailer.createTransport({
            host: "smtp.sendgrid.net",
            port: 587,
            secure: false,
            auth: { user: "apikey", pass: getSendgridKey() },
        });
        const from = { name: "Ridemate Shuttle", address: "heartx8880@gmail.com" };
        await transporter.sendMail({
            from,
            to: email,
            subject: "🎉 Your Ridemate Booking is Confirmed!",
            html: getBookingEmailHTML(origin || "Origin", destination || "Destination", date || "Date", time || "Time", seats || "N/A", totalAmount || "0.00"),
        });
        v2_1.logger.info(`✅ Booking email sent to: ${email} (from ${from.address})`);
        return { success: true };
    }
    catch (err) {
        v2_1.logger.error("Email error:", err);
        throw new https_1.HttpsError("internal", err?.message ?? "Failed to send email");
    }
});
exports.sendCancellationEmail = (0, https_1.onCall)({ region: REGION, secrets: [SENDGRID_API_KEY] }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { email, origin, destination, date, time, refundAmount } = (request.data ?? {});
    if (!email)
        throw new https_1.HttpsError("invalid-argument", "Email is required");
    try {
        const nodemailer = getNodemailer();
        const transporter = nodemailer.createTransport({
            host: "smtp.sendgrid.net",
            port: 587,
            secure: false,
            auth: { user: "apikey", pass: getSendgridKey() },
        });
        const from = { name: "Ridemate Shuttle", address: "heartx8880@gmail.com" };
        await transporter.sendMail({
            from,
            to: email,
            subject: "🔄 Booking Cancelled - Refund Processing",
            html: getCancellationEmailHTML(origin || "Origin", destination || "Destination", date || "Date", time || "Time", refundAmount || "0.00"),
        });
        v2_1.logger.info(`✅ Cancellation email sent to: ${email} (from ${from.address})`);
        return { success: true };
    }
    catch (err) {
        v2_1.logger.error("Email error:", err);
        throw new https_1.HttpsError("internal", err?.message ?? "Failed to send email");
    }
});
/* ------------------------------------------------------------------
   Push: sendTripReminder (callable)
-------------------------------------------------------------------*/
exports.sendTripReminder = (0, https_1.onCall)({ region: REGION }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { userId, origin, destination, time, isDriver } = (request.data ?? {});
    if (!userId)
        throw new https_1.HttpsError("invalid-argument", "userId is required");
    try {
        const { fcmToken, tried } = await resolveFcmToken(userId, !!isDriver);
        if (!fcmToken) {
            v2_1.logger.warn(`sendTripReminder: no FCM token for ${userId}. Tried: ${tried.join(", ")}`);
            return { success: false, message: "No FCM token / user not found", tried };
        }
        await admin.messaging().send({
            token: fcmToken,
            notification: {
                title: "🚌 Trip Reminder",
                body: `Your trip ${origin ?? ""} → ${destination ?? ""} departs at ${time ?? ""}. Don't be late!`,
            },
            data: {
                type: "trip_reminder",
                origin: origin ?? "",
                destination: destination ?? "",
                time: time ?? "",
                channelId: "trip_reminders",
            },
            android: { priority: "high", notification: { sound: "default", channelId: "trip_reminders" } },
        });
        v2_1.logger.info(`Reminder sent to ${userId}`);
        return { success: true };
    }
    catch (e) {
        v2_1.logger.error("sendTripReminder error:", e);
        throw new https_1.HttpsError("internal", e?.message ?? "Failed to send notification");
    }
});
/* ------------------------------------------------------------------
   Scheduled Notification Scanner (runs every 1 minute)
-------------------------------------------------------------------*/
async function runScheduledScan(backfillMs = 5 * 60 * 1000, lookaheadMs = 1 * 60 * 1000) {
    // Lazy-load admin here for isolation
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const _admin = require("firebase-admin");
    if (!_admin.apps.length)
        _admin.initializeApp();
    const db = _admin.firestore();
    const now = Date.now();
    const fromTs = _admin.firestore.Timestamp.fromDate(new Date(now - backfillMs));
    const toTs = _admin.firestore.Timestamp.fromDate(new Date(now + lookaheadMs));
    // Requires composite index: status ASC, reminderTime ASC on scheduled_notifications
    const snapshot = await db
        .collection("scheduled_notifications")
        .where("status", "==", "scheduled")
        .where("reminderTime", ">=", fromTs)
        .where("reminderTime", "<=", toTs)
        .get();
    v2_1.logger.info(`🔎 scan window ${fromTs.toDate().toISOString()} → ${toTs.toDate().toISOString()} | found ${snapshot.size}`);
    await Promise.all(snapshot.docs.map(async (doc) => {
        const data = doc.data();
        const userId = data.userId ?? "";
        const origin = data.origin ?? "";
        const destination = data.destination ?? "";
        const time = data.time ?? "";
        const isDriver = !!data.isDriver;
        try {
            let fcmToken = data.snapshotFcmToken || "";
            let tried = ["snapshotFcmToken"];
            if (!fcmToken) {
                const resolved = await resolveFcmTokenWith(_admin, userId, isDriver);
                fcmToken = resolved.fcmToken ?? "";
                tried = resolved.tried;
            }
            if (!fcmToken) {
                v2_1.logger.warn(`Scheduled notif: no FCM for ${userId}. Tried: ${tried.join(", ")}`);
                await doc.ref.update({ status: "failed", error: "No FCM token / user not found", tried });
                return;
            }
            await _admin.messaging().send({
                token: fcmToken,
                notification: {
                    title: "🚌 Trip Reminder",
                    body: `Your trip ${origin} → ${destination} departs at ${time}.`,
                },
                data: {
                    type: data.type || "trip_reminder",
                    origin,
                    destination,
                    time,
                    channelId: "trip_reminders",
                },
                android: { priority: "high", notification: { sound: "default", channelId: "trip_reminders" } },
            });
            await doc.ref.update({ status: "sent", sentAt: new Date().toISOString() });
            v2_1.logger.info(`✅ Reminder sent to ${userId} for ${origin} → ${destination} @ ${time}`);
        }
        catch (err) {
            v2_1.logger.error(`Error sending notification for ${doc.id}:`, err);
            await doc.ref.update({ status: "failed", error: String(err) });
        }
    }));
}
// Cron every minute
exports.checkScheduledNotifications = (0, scheduler_1.onSchedule)({ schedule: "every 1 minutes", region: REGION, timeZone: "Asia/Kuala_Lumpur", minInstances: 1 }, async () => {
    await runScheduledScan(5 * 60 * 1000, 1 * 60 * 1000);
});
// Manual HTTP trigger for testing
exports.runScheduledOnce = (0, https_1.onRequest)({ region: REGION }, async (_req, res) => {
    try {
        await runScheduledScan(30 * 60 * 1000, 10 * 60 * 1000);
        res.status(200).send("ok");
    }
    catch (e) {
        v2_1.logger.error(e);
        res.status(500).send(e?.message ?? "error");
    }
});
/* ------------------------------------------------------------------
   Test endpoints
-------------------------------------------------------------------*/
exports.testScheduledNotifications = (0, https_1.onRequest)({ region: REGION }, async (_req, res) => {
    try {
        const db = admin.firestore();
        const now = new Date();
        const tenMinutesFromNow = new Date(now.getTime() + 10 * 60 * 1000);
        const notificationsSnapshot = await db
            .collection("scheduled_notifications")
            .where("status", "==", "scheduled")
            .get();
        const results = [];
        for (const doc of notificationsSnapshot.docs) {
            const data = doc.data();
            const { userId, origin, destination, time, type, isDriver, reminderTime } = data;
            let reminderDate;
            if (reminderTime && reminderTime.toDate) {
                reminderDate = reminderTime.toDate();
            }
            else {
                v2_1.logger.warn(`Document ${doc.id} has invalid reminderTime`);
                continue;
            }
            if (reminderDate < now || reminderDate > tenMinutesFromNow)
                continue;
            try {
                let fcmToken = data.snapshotFcmToken || "";
                let tried = ["snapshotFcmToken"];
                if (!fcmToken) {
                    const resolved = await resolveFcmToken(userId, !!isDriver);
                    fcmToken = resolved.fcmToken ?? "";
                    tried = resolved.tried;
                }
                if (!fcmToken) {
                    await doc.ref.update({ status: "failed", error: "No FCM token / user not found", tried });
                    results.push({ id: doc.id, status: "failed", error: "No FCM token", tried });
                    continue;
                }
                await admin.messaging().send({
                    token: fcmToken,
                    notification: {
                        title: "🚌 Trip Reminder",
                        body: `Your trip ${origin} → ${destination} departs at ${time}. Departure in 30 minutes!`,
                    },
                    data: { type: type || "trip_reminder", origin, destination, time, channelId: "trip_reminders" },
                    android: { priority: "high", notification: { sound: "default", channelId: "trip_reminders" } },
                });
                await doc.ref.update({ status: "sent", sentAt: new Date().toISOString() });
                results.push({ id: doc.id, status: "sent", userId });
            }
            catch (error) {
                await doc.ref.update({ status: "failed", error: String(error) });
                results.push({ id: doc.id, status: "failed", error: String(error) });
            }
        }
        res.status(200).json({
            success: true,
            message: "Notification check completed",
            totalChecked: notificationsSnapshot.size,
            results,
        });
    }
    catch (error) {
        v2_1.logger.error("Error in test function:", error);
        res.status(500).json({ success: false, error: String(error) });
    }
});
exports.testPushNotification = (0, https_1.onRequest)({ region: REGION }, async (req, res) => {
    try {
        const userId = req.query.userId || "test-user-123";
        const { fcmToken, tried } = await resolveFcmToken(userId, false);
        if (!fcmToken) {
            res.status(400).json({ success: false, error: "No FCM token / user not found", userId, tried });
            return;
        }
        await admin.messaging().send({
            token: fcmToken,
            notification: {
                title: "🚌 Test Notification",
                body: "Your trip from USM → Penang Sentral departs at 14:30. This is a test!",
            },
            data: { type: "trip_reminder", origin: "USM", destination: "Penang Sentral", time: "14:30", channelId: "trip_reminders" },
            android: { priority: "high", notification: { sound: "default", channelId: "trip_reminders" } },
        });
        res.status(200).json({
            success: true,
            message: "Push notification sent!",
            userId,
            fcmToken: fcmToken.substring(0, 20) + "...",
        });
    }
    catch (error) {
        v2_1.logger.error("Error:", error);
        res.status(500).json({ success: false, error: String(error) });
    }
});
/* ------------------------------------------------------------------
   Maps: Directions proxy (uses auto env key)
-------------------------------------------------------------------*/
exports.directions = (0, https_1.onRequest)({ region: REGION, secrets: [GOOGLE_DIRECTIONS_KEY] }, async (req, res) => {
    try {
        const origin = String((req.query.origin ?? "") || (req.body?.origin ?? ""));
        const destination = String((req.query.destination ?? "") || (req.body?.destination ?? ""));
        const mode = String((req.query.mode ?? "") || (req.body?.mode ?? "driving")).toLowerCase();
        const waypoints = (req.query.waypoints ?? req.body?.waypoints)
            ? `&waypoints=${encodeURIComponent(String(req.query.waypoints ?? req.body?.waypoints))}`
            : "";
        if (!origin || !destination) {
            res.status(400).json({
                status: "INVALID_REQUEST",
                error: "origin and destination are required",
            });
            return;
        }
        const key = GOOGLE_DIRECTIONS_KEY.value();
        if (!key) {
            res.status(500).json({
                status: "INTERNAL",
                error: "GOOGLE_DIRECTIONS_KEY not configured",
            });
            return;
        }
        const url = "https://maps.googleapis.com/maps/api/directions/json" +
            `?origin=${encodeURIComponent(origin)}` +
            `&destination=${encodeURIComponent(destination)}` +
            `&mode=${encodeURIComponent(mode)}` +
            waypoints +
            `&key=${key}`;
        const gRes = await fetch(url);
        const gJson = (await gRes.json());
        if (gJson.status !== "OK")
            console.error("Directions error:", gJson);
        res.status(200).json(gJson);
    }
    catch (e) {
        res.status(500).json({
            status: "INTERNAL",
            error: e?.message ?? String(e),
        });
    }
});
/* ========= Places Text Search Endpoint ========= */
exports.placesText = (0, https_1.onRequest)({ region: REGION, secrets: [GOOGLE_DIRECTIONS_KEY] }, async (req, res) => {
    try {
        const query = String((req.query.query ?? "") || (req.body?.query ?? ""));
        if (!query) {
            res.status(400).json({
                status: "INVALID_REQUEST",
                error: "query required",
            });
            return;
        }
        const region = String((req.query.region ?? "") || (req.body?.region ?? "my"));
        const location = (req.query.location ?? req.body?.location)
            ? `&location=${encodeURIComponent(String(req.query.location ?? req.body?.location))}`
            : "";
        const radius = String((req.query.radius ?? "") || (req.body?.radius ?? "40000"));
        const key = GOOGLE_DIRECTIONS_KEY.value();
        if (!key) {
            res.status(500).json({
                status: "INTERNAL",
                error: "GOOGLE_DIRECTIONS_KEY not configured",
            });
            return;
        }
        const url = "https://maps.googleapis.com/maps/api/place/textsearch/json" +
            `?query=${encodeURIComponent(query)}` +
            `&region=${encodeURIComponent(region)}` +
            location +
            `&radius=${encodeURIComponent(radius)}` +
            `&key=${key}`;
        const gRes = await fetch(url);
        const gJson = (await gRes.json());
        if (gJson.status && gJson.status !== "OK")
            console.error("Places error:", gJson);
        res.status(200).json(gJson);
    }
    catch (e) {
        res.status(500).json({
            status: "INTERNAL",
            error: e?.message ?? String(e),
        });
    }
});
