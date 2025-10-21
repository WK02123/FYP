"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.testPushNotification = exports.testScheduledNotifications = exports.checkScheduledNotifications = exports.sendTripReminder = exports.sendCancellationEmail = exports.sendBookingEmail = exports.refundPayment = exports.createPaymentIntent = exports.hello = void 0;
// functions/src/index.ts
const https_1 = require("firebase-functions/v2/https");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const v2_1 = require("firebase-functions/v2");
/** ───────────────────────────────
 *  Load .env.local only in local/dev
 *  ─────────────────────────────── */
(() => {
    try {
        const isEmulator = process.env.FUNCTIONS_EMULATOR === "true" ||
            process.env.FIREBASE_EMULATOR_HUB !== undefined;
        if (isEmulator) {
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            const path = require("path");
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            const dotenv = require("dotenv");
            dotenv.config({ path: path.join(__dirname, "..", ".env.local") });
            v2_1.logger.info("✅ .env.local loaded for emulator");
        }
    }
    catch (e) {
        v2_1.logger.warn("⚠️ .env.local load skipped:", e);
    }
})();
/** ---------- Helpers ---------- */
const REGION = "asia-southeast1";
const getEnv = (key, required = true) => {
    const v = process.env[key];
    if (!v && required)
        throw new Error(`${key} not configured`);
    return v ?? "";
};
/** Lazy loaders (avoid top-level imports) */
const getStripe = () => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const Stripe = require("stripe");
    const secret = getEnv("STRIPE_SECRET");
    return new Stripe(secret, { apiVersion: "2024-06-20" });
};
const getNodemailer = () => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    return require("nodemailer");
};
const getAdmin = () => {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const admin = require("firebase-admin");
    if (!admin.apps.length) {
        admin.initializeApp();
    }
    return admin;
};
/** ---------- Email Template Helpers ---------- */
const getEmailStyles = () => `
  body {
    margin: 0;
    padding: 0;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    background-color: #f5f5f5;
  }
  .email-container {
    max-width: 600px;
    margin: 0 auto;
    background-color: #ffffff;
  }
  .header {
    background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
    padding: 40px 20px;
    text-align: center;
  }
  .logo {
    font-size: 32px;
    font-weight: bold;
    color: #ffffff;
    margin: 0;
  }
  .content {
    padding: 40px 30px;
  }
  .title {
    font-size: 28px;
    font-weight: bold;
    color: #1f2937;
    margin: 0 0 10px 0;
  }
  .subtitle {
    font-size: 16px;
    color: #6b7280;
    margin: 0 0 30px 0;
  }
  .card {
    background-color: #f9fafb;
    border-radius: 12px;
    padding: 24px;
    margin-bottom: 24px;
    border: 1px solid #e5e7eb;
  }
  .route {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 20px;
    padding: 16px;
    background-color: #ffffff;
    border-radius: 8px;
  }
  .location {
    font-size: 18px;
    font-weight: 600;
    color: #1f2937;
  }
  .arrow {
    font-size: 24px;
    color: #ef4444;
    margin: 0 10px;
  }
  .info-row {
    display: flex;
    justify-content: space-between;
    padding: 12px 0;
    border-bottom: 1px solid #e5e7eb;
  }
  .info-row:last-child {
    border-bottom: none;
  }
  .info-label {
    font-size: 14px;
    color: #6b7280;
    font-weight: 500;
  }
  .info-value {
    font-size: 14px;
    color: #1f2937;
    font-weight: 600;
  }
  .qr-section {
    background: linear-gradient(135deg, #fef3c7 0%, #fde68a 100%);
    border-radius: 12px;
    padding: 24px;
    text-align: center;
    margin: 24px 0;
  }
  .qr-icon {
    font-size: 48px;
    margin-bottom: 12px;
  }
  .qr-text {
    font-size: 16px;
    color: #92400e;
    font-weight: 600;
    margin: 0;
  }
  .qr-subtext {
    font-size: 14px;
    color: #78350f;
    margin: 8px 0 0 0;
  }
  .total-section {
    background: linear-gradient(135deg, #dbeafe 0%, #bfdbfe 100%);
    border-radius: 12px;
    padding: 20px 24px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-top: 24px;
  }
  .total-label {
    font-size: 16px;
    color: #1e40af;
    font-weight: 600;
  }
  .total-amount {
    font-size: 32px;
    color: #1e3a8a;
    font-weight: bold;
  }
  .tips {
    background-color: #ecfdf5;
    border-left: 4px solid #10b981;
    padding: 16px 20px;
    margin-top: 24px;
    border-radius: 8px;
  }
  .tips-title {
    font-size: 14px;
    font-weight: 600;
    color: #065f46;
    margin: 0 0 8px 0;
  }
  .tips-list {
    margin: 0;
    padding-left: 20px;
    color: #047857;
    font-size: 14px;
    line-height: 1.8;
  }
  .footer {
    background-color: #1f2937;
    padding: 30px;
    text-align: center;
    color: #9ca3af;
    font-size: 14px;
  }
  .footer-link {
    color: #ef4444;
    text-decoration: none;
  }
  .cancel-banner {
    background: linear-gradient(135deg, #fee2e2 0%, #fecaca 100%);
    border-radius: 12px;
    padding: 20px 24px;
    text-align: center;
    margin-bottom: 24px;
  }
  .cancel-icon {
    font-size: 48px;
    margin-bottom: 8px;
  }
  .cancel-text {
    font-size: 18px;
    color: #991b1b;
    font-weight: 600;
    margin: 0;
  }
  .refund-section {
    background: linear-gradient(135deg, #d1fae5 0%, #a7f3d0 100%);
    border-radius: 12px;
    padding: 24px;
    text-align: center;
    margin: 24px 0;
  }
  .refund-icon {
    font-size: 48px;
    margin-bottom: 12px;
  }
  .refund-amount {
    font-size: 36px;
    color: #065f46;
    font-weight: bold;
    margin: 8px 0;
  }
  .refund-text {
    font-size: 14px;
    color: #047857;
    margin: 0;
  }
  .cta-button {
    display: inline-block;
    background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
    color: white;
    text-decoration: none;
    padding: 12px 32px;
    border-radius: 8px;
    font-weight: 600;
    font-size: 16px;
  }
`;
const getBookingEmailHTML = (origin, destination, date, time, seats, totalAmount) => `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>${getEmailStyles()}</style>
</head>
<body>
  <div class="email-container">
    <div class="header">
      <h1 class="logo">🚌 Ridemate</h1>
    </div>
    <div class="content">
      <h1 class="title">🎉 Booking Confirmed!</h1>
      <p class="subtitle">Your shuttle reservation is all set. Get ready for a comfortable ride!</p>
      <div class="card">
        <div class="route">
          <div class="location">${origin}</div>
          <div class="arrow">→</div>
          <div class="location">${destination}</div>
        </div>
        <div class="info-row">
          <span class="info-label">📅 Date</span>
          <span class="info-value">${date}</span>
        </div>
        <div class="info-row">
          <span class="info-label">🕐 Time</span>
          <span class="info-value">${time}</span>
        </div>
        <div class="info-row">
          <span class="info-label">💺 Seat(s)</span>
          <span class="info-value">${seats}</span>
        </div>
      </div>
      <div class="qr-section">
        <div class="qr-icon">📱</div>
        <p class="qr-text">Show Your QR Code</p>
        <p class="qr-subtext">Present this booking confirmation to the driver</p>
      </div>
      <div class="total-section">
        <span class="total-label">Total Paid</span>
        <span class="total-amount">RM ${totalAmount}</span>
      </div>
      <div class="tips">
        <p class="tips-title">✨ Travel Tips</p>
        <ul class="tips-list">
          <li>Arrive at the pickup point 5 minutes early</li>
          <li>Have your booking QR code ready to show</li>
          <li>Keep your belongings secure during the trip</li>
          <li>Follow the driver's safety instructions</li>
        </ul>
      </div>
    </div>
    <div class="footer">
      <p>Need help? Contact us at <a href="mailto:support@ridemate.com" class="footer-link">support@ridemate.com</a></p>
      <p style="margin-top: 16px;">© ${new Date().getFullYear()} Ridemate Shuttle. Safe travels! 🚌</p>
    </div>
  </div>
</body>
</html>
`;
const getCancellationEmailHTML = (origin, destination, date, time, refundAmount) => `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>${getEmailStyles()}</style>
</head>
<body>
  <div class="email-container">
    <div class="header">
      <h1 class="logo">🚌 Ridemate</h1>
    </div>
    <div class="content">
      <div class="cancel-banner">
        <div class="cancel-icon">🔄</div>
        <p class="cancel-text">Booking Cancelled</p>
      </div>
      <h1 class="title">We're Sorry to See You Go</h1>
      <p class="subtitle">Your booking has been successfully cancelled. Here are the details:</p>
      <div class="card">
        <div class="route">
          <div class="location">${origin}</div>
          <div class="arrow">→</div>
          <div class="location">${destination}</div>
        </div>
        <div class="info-row">
          <span class="info-label">📅 Date</span>
          <span class="info-value">${date}</span>
        </div>
        <div class="info-row">
          <span class="info-label">🕐 Time</span>
          <span class="info-value">${time}</span>
        </div>
        <div class="info-row">
          <span class="info-label">📋 Status</span>
          <span class="info-value" style="color: #dc2626;">Cancelled</span>
        </div>
      </div>
      <div class="refund-section">
        <div class="refund-icon">💰</div>
        <p style="font-size: 14px; color: #047857; font-weight: 600; margin: 0;">Refund Amount</p>
        <div class="refund-amount">RM ${refundAmount}</div>
        <p class="refund-text">Processing time: 5-10 business days</p>
      </div>
      <div class="tips">
        <p class="tips-title">ℹ️ Refund Information</p>
        <ul class="tips-list" style="color: #065f46;">
          <li>Refund will be credited to your original payment method</li>
          <li>You'll receive a notification once processed</li>
          <li>Bank processing may take an additional 3-5 days</li>
          <li>Contact support if you don't see the refund within 10 days</li>
        </ul>
      </div>
      <div style="text-align: center; margin-top: 32px;">
        <p style="color: #6b7280; margin-bottom: 16px;">Changed your mind? Book another trip anytime!</p>
        <a href="https://ridemate.com" class="cta-button">Browse Routes</a>
      </div>
    </div>
    <div class="footer">
      <p>Need help? Contact us at <a href="mailto:support@ridemate.com" class="footer-link">support@ridemate.com</a></p>
      <p style="margin-top: 16px;">© ${new Date().getFullYear()} Ridemate Shuttle. We hope to serve you again soon! 🚌</p>
    </div>
  </div>
</body>
</html>
`;
/** ---------- Health check ---------- */
exports.hello = (0, https_1.onRequest)({ region: REGION }, (_req, res) => {
    res.status(200).send("ok");
});
/** ---------- Create Payment Intent (Stripe) ---------- */
exports.createPaymentIntent = (0, https_1.onCall)({ region: REGION }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { amount, currency = "myr", description = "Bus ticket payment", } = (request.data ?? {});
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
/** ---------- Refund Payment (Stripe) ---------- */
exports.refundPayment = (0, https_1.onCall)({ region: REGION }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { paymentIntentId, amount } = (request.data ?? {});
    if (!paymentIntentId)
        throw new https_1.HttpsError("invalid-argument", "paymentIntentId is required");
    try {
        const stripe = getStripe();
        const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
        const latestCharge = pi.latest_charge;
        if (!latestCharge) {
            throw new https_1.HttpsError("failed-precondition", "No charge found for this payment");
        }
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
/** ---------- Booking Confirmation Email (SendGrid SMTP) ---------- */
exports.sendBookingEmail = (0, https_1.onCall)({ region: REGION }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { email, origin, destination, date, time, seats, totalAmount, } = (request.data ?? {});
    if (!email)
        throw new https_1.HttpsError("invalid-argument", "Email is required");
    try {
        const nodemailer = getNodemailer();
        const transporter = nodemailer.createTransport({
            host: "smtp.sendgrid.net",
            port: 587,
            secure: false,
            auth: { user: "apikey", pass: getEnv("SENDGRID_API_KEY") },
        });
        const fromEmail = getEnv("FROM_EMAIL", false) || "noreply@ridemate.com";
        await transporter.sendMail({
            from: `"Ridemate Shuttle" <${fromEmail}>`,
            to: email,
            subject: "🎉 Your Ridemate Booking is Confirmed!",
            html: getBookingEmailHTML(origin || "Origin", destination || "Destination", date || "Date", time || "Time", seats || "N/A", totalAmount || "0.00"),
        });
        v2_1.logger.info("Booking email sent to:", email);
        return { success: true };
    }
    catch (err) {
        const e = err;
        v2_1.logger.error("Email error:", e);
        throw new https_1.HttpsError("internal", e?.message ?? "Failed to send email");
    }
});
/** ---------- Cancellation Email (SendGrid SMTP) ---------- */
exports.sendCancellationEmail = (0, https_1.onCall)({ region: REGION }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { email, origin, destination, date, time, refundAmount, } = (request.data ?? {});
    if (!email)
        throw new https_1.HttpsError("invalid-argument", "Email is required");
    try {
        const nodemailer = getNodemailer();
        const transporter = nodemailer.createTransport({
            host: "smtp.sendgrid.net",
            port: 587,
            secure: false,
            auth: { user: "apikey", pass: getEnv("SENDGRID_API_KEY") },
        });
        const fromEmail = getEnv("FROM_EMAIL", false) || "noreply@ridemate.com";
        await transporter.sendMail({
            from: `"Ridemate Shuttle" <${fromEmail}>`,
            to: email,
            subject: "🔄 Booking Cancelled - Refund Processing",
            html: getCancellationEmailHTML(origin || "Origin", destination || "Destination", date || "Date", time || "Time", refundAmount || "0.00"),
        });
        v2_1.logger.info("Cancellation email sent to:", email);
        return { success: true };
    }
    catch (err) {
        const e = err;
        v2_1.logger.error("Email error:", e);
        throw new https_1.HttpsError("internal", e?.message ?? "Failed to send email");
    }
});
/** ---------- Trip Reminder (FCM via Admin) ---------- */
exports.sendTripReminder = (0, https_1.onCall)({ region: REGION }, async (request) => {
    if (!request.auth)
        throw new https_1.HttpsError("unauthenticated", "Sign in required");
    const { userId, origin, destination, time, isDriver } = (request.data ?? {});
    if (!userId)
        throw new https_1.HttpsError("invalid-argument", "userId is required");
    try {
        const admin = getAdmin();
        const collection = isDriver ? "drivers" : "users";
        const userDoc = await admin.firestore().collection(collection).doc(userId).get();
        if (!userDoc.exists)
            throw new https_1.HttpsError("not-found", "User not found");
        const userData = userDoc.data();
        const fcmToken = userData?.fcmToken;
        if (!fcmToken) {
            v2_1.logger.warn(`User ${userId} has no FCM token`);
            return { success: false, message: "No FCM token" };
        }
        await admin.messaging().send({
            token: fcmToken,
            notification: {
                title: "🚌 Trip Reminder",
                body: `Your trip ${origin} → ${destination} departs at ${time}. Don't be late!`,
            },
            data: {
                type: "trip_reminder",
                origin: origin ?? "",
                destination: destination ?? "",
                time: time ?? "",
            },
        });
        v2_1.logger.info(`Reminder sent to user ${userId}`);
        return { success: true };
    }
    catch (err) {
        const e = err;
        v2_1.logger.error("Notification error:", e);
        throw new https_1.HttpsError("internal", e?.message ?? "Failed to send notification");
    }
});
/** ---------- Scheduled Notification Checker ---------- */
// Runs every 10 minutes to check for upcoming trip reminders
exports.checkScheduledNotifications = (0, scheduler_1.onSchedule)({
    schedule: "every 10 minutes",
    region: REGION,
    timeZone: "Asia/Kuala_Lumpur",
}, async (event) => {
    v2_1.logger.info("🕐 Checking for scheduled notifications...");
    try {
        const admin = getAdmin();
        const now = admin.firestore.Timestamp.now();
        const tenMinutesFromNow = admin.firestore.Timestamp.fromDate(new Date(Date.now() + 10 * 60 * 1000));
        // Find all scheduled notifications that should be sent in the next 10 minutes
        const notificationsSnapshot = await admin
            .firestore()
            .collection("scheduled_notifications")
            .where("status", "==", "scheduled")
            .where("reminderTime", ">=", now)
            .where("reminderTime", "<=", tenMinutesFromNow)
            .get();
        v2_1.logger.info(`Found ${notificationsSnapshot.size} notifications to send`);
        const promises = notificationsSnapshot.docs.map(async (doc) => {
            const data = doc.data();
            const { userId, origin, destination, time, type, isDriver } = data;
            try {
                // Get user's FCM token
                const collection = isDriver ? "drivers" : "users";
                const userDoc = await admin
                    .firestore()
                    .collection(collection)
                    .doc(userId)
                    .get();
                if (!userDoc.exists) {
                    v2_1.logger.warn(`User ${userId} not found`);
                    await doc.ref.update({ status: "failed", error: "User not found" });
                    return;
                }
                const userData = userDoc.data();
                const fcmToken = userData?.fcmToken;
                if (!fcmToken) {
                    v2_1.logger.warn(`User ${userId} has no FCM token`);
                    await doc.ref.update({ status: "failed", error: "No FCM token" });
                    return;
                }
                // Send notification
                await admin.messaging().send({
                    token: fcmToken,
                    notification: {
                        title: "🚌 Trip Reminder",
                        body: `Your trip ${origin} → ${destination} departs at ${time}. Departure in 30 minutes!`,
                    },
                    data: {
                        type: type || "trip_reminder",
                        origin: origin || "",
                        destination: destination || "",
                        time: time || "",
                    },
                    android: {
                        priority: "high",
                        notification: {
                            sound: "default",
                            channelId: "trip_reminders",
                        },
                    },
                });
                // Mark as sent
                await doc.ref.update({
                    status: "sent",
                    sentAt: new Date().toISOString(),
                });
                v2_1.logger.info(`✅ 30-min reminder sent to user ${userId} for trip at ${time}`);
            }
            catch (error) {
                v2_1.logger.error(`Error sending notification for ${doc.id}:`, error);
                await doc.ref.update({
                    status: "failed",
                    error: String(error),
                });
            }
        });
        await Promise.all(promises);
        v2_1.logger.info("✅ Finished processing scheduled notifications");
    }
    catch (error) {
        v2_1.logger.error("Error in checkScheduledNotifications:", error);
    }
});
/** ---------- TEST: Manually trigger notification check ---------- */
/** ---------- TEST: Manually trigger notification check ---------- */
exports.testScheduledNotifications = (0, https_1.onRequest)({ region: REGION }, async (req, res) => {
    v2_1.logger.info("🧪 Manually triggering scheduled notifications check...");
    try {
        const admin = getAdmin();
        const db = admin.firestore();
        // Calculate time window
        const now = new Date();
        const tenMinutesFromNow = new Date(now.getTime() + 10 * 60 * 1000);
        v2_1.logger.info(`Checking from ${now.toISOString()} to ${tenMinutesFromNow.toISOString()}`);
        // Find all scheduled notifications
        const notificationsSnapshot = await db
            .collection("scheduled_notifications")
            .where("status", "==", "scheduled")
            .get();
        v2_1.logger.info(`Found ${notificationsSnapshot.size} total scheduled notifications`);
        const results = [];
        for (const doc of notificationsSnapshot.docs) {
            const data = doc.data();
            const { userId, origin, destination, time, type, isDriver, reminderTime } = data;
            // Check if reminderTime is within our window
            let reminderDate;
            if (reminderTime && reminderTime.toDate) {
                reminderDate = reminderTime.toDate();
            }
            else {
                v2_1.logger.warn(`Document ${doc.id} has invalid reminderTime`);
                continue;
            }
            // Skip if not in time window
            if (reminderDate < now || reminderDate > tenMinutesFromNow) {
                v2_1.logger.info(`Skipping ${doc.id} - reminder time ${reminderDate.toISOString()} not in window`);
                continue;
            }
            v2_1.logger.info(`Processing notification ${doc.id} for user ${userId}`);
            try {
                const collection = isDriver ? "drivers" : "users";
                const userDoc = await db.collection(collection).doc(userId).get();
                if (!userDoc.exists) {
                    v2_1.logger.warn(`User ${userId} not found`);
                    await doc.ref.update({ status: "failed", error: "User not found" });
                    results.push({ id: doc.id, status: "failed", error: "User not found" });
                    continue;
                }
                const userData = userDoc.data();
                const fcmToken = userData?.fcmToken;
                if (!fcmToken) {
                    v2_1.logger.warn(`User ${userId} has no FCM token`);
                    await doc.ref.update({ status: "failed", error: "No FCM token" });
                    results.push({ id: doc.id, status: "failed", error: "No FCM token" });
                    continue;
                }
                await admin.messaging().send({
                    token: fcmToken,
                    notification: {
                        title: "🚌 Trip Reminder",
                        body: `Your trip ${origin} → ${destination} departs at ${time}. Departure in 30 minutes!`,
                    },
                    data: {
                        type: type || "trip_reminder",
                        origin: origin || "",
                        destination: destination || "",
                        time: time || "",
                    },
                    android: {
                        priority: "high",
                        notification: {
                            sound: "default",
                            channelId: "trip_reminders",
                        },
                    },
                });
                await doc.ref.update({
                    status: "sent",
                    sentAt: new Date().toISOString(),
                });
                v2_1.logger.info(`✅ Reminder sent to user ${userId}`);
                results.push({ id: doc.id, status: "sent", userId });
            }
            catch (error) {
                v2_1.logger.error(`Error sending notification for ${doc.id}:`, error);
                await doc.ref.update({
                    status: "failed",
                    error: String(error),
                });
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
        res.status(500).json({
            success: false,
            error: String(error),
        });
    }
});
/** ---------- TEST: Send Push Notification ---------- */
exports.testPushNotification = (0, https_1.onRequest)({ region: REGION }, async (req, res) => {
    v2_1.logger.info("🧪 Testing push notification...");
    try {
        const admin = getAdmin();
        // Get userId from query parameter or use default
        const userId = req.query.userId || 'test-user-123';
        // Get user's FCM token
        const userDoc = await admin.firestore().collection('users').doc(userId).get();
        if (!userDoc.exists) {
            res.status(404).json({
                success: false,
                error: 'User not found',
                userId,
            });
            return;
        }
        const userData = userDoc.data();
        const fcmToken = userData?.fcmToken;
        if (!fcmToken) {
            res.status(400).json({
                success: false,
                error: 'User has no FCM token',
                userId,
            });
            return;
        }
        // Send the notification
        await admin.messaging().send({
            token: fcmToken,
            notification: {
                title: "🚌 Test Notification",
                body: "Your trip from USM → Penang Sentral departs at 14:30. This is a test!",
            },
            data: {
                type: "trip_reminder",
                origin: "USM",
                destination: "Penang Sentral",
                time: "14:30",
            },
            android: {
                priority: "high",
                notification: {
                    sound: "default",
                    channelId: "trip_reminders",
                },
            },
        });
        v2_1.logger.info(`✅ Test notification sent to user ${userId}`);
        res.status(200).json({
            success: true,
            message: 'Push notification sent!',
            userId,
            fcmToken: fcmToken.substring(0, 20) + '...',
        });
    }
    catch (error) {
        v2_1.logger.error("Error:", error);
        res.status(500).json({
            success: false,
            error: String(error),
        });
    }
});
