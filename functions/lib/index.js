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
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.sendTripReminder = exports.sendCancellationEmail = exports.sendBookingEmail = exports.refundPayment = exports.createPaymentIntent = exports.hello = void 0;
// functions/src/index.ts
const https_1 = require("firebase-functions/v2/https");
const v2_1 = require("firebase-functions/v2");
/** ───────────────────────────────
 *  Load .env.local only in local/dev
 *  (Cloud Functions prod uses process.env / Secrets)
 *  ─────────────────────────────── */
// Load .env.local when running locally (emulator)
const path = __importStar(require("path"));
(() => {
    try {
        // Only in emulator
        if (process.env.FUNCTIONS_EMULATOR || process.env.FIREBASE_EMULATOR_HUB) {
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            require("dotenv").config({
                path: path.join(__dirname, "..", ".env.local"),
            });
            console.log("✅ .env.local loaded for emulator");
        }
    }
    catch (e) {
        console.warn("⚠️ dotenv/config load skipped:", e);
    }
})();
(() => {
    try {
        // Detect emulator / local run
        const isLocal = process.env.FUNCTIONS_EMULATOR === "true" ||
            process.env.GCLOUD_PROJECT === undefined ||
            process.env.K_SERVICE === undefined;
        if (isLocal) {
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            const fs = require("fs");
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            const path = require("path");
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            const dotenv = require("dotenv");
            const envPath = path.join(__dirname, "..", ".env.local");
            if (fs.existsSync(envPath)) {
                dotenv.config({ path: envPath });
                v2_1.logger.info("Loaded environment from .env.local");
            }
            else {
                v2_1.logger.warn(".env.local not found at functions/.env.local");
            }
        }
    }
    catch (e) {
        v2_1.logger.warn("Skipping .env.local load:", e);
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
/** Lazy loaders (avoid top-level heavy work) */
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
    if (!admin.apps.length)
        admin.initializeApp();
    return admin;
};
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
            amount: Math.trunc(numAmount), // integer minor units
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
    const { email, name: _name, // unused on purpose
    origin, destination, date, time, seats, totalAmount, } = (request.data ?? {});
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
        const fromEmail = getEnv("FROM_EMAIL", false) || "noreply@shuttlebus.com";
        await transporter.sendMail({
            from: `"Ridemate Shuttle" <${fromEmail}>`,
            to: email,
            subject: "✅ Booking Confirmed - Ridemate Shuttle",
            html: `
        <h1>🚌 Booking Confirmed!</h1>
        <p>Your shuttle booking is confirmed:</p>
        <p><strong>Route:</strong> ${origin} → ${destination}</p>
        <p><strong>Date:</strong> ${date} at ${time}</p>
        <p><strong>Seat(s):</strong> ${seats}</p>
        <p><strong>Total:</strong> RM ${totalAmount}</p>
        <p>Arrive 5 minutes early and show your QR code!</p>
      `,
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
    const { email, name: _name2, // unused
    origin, destination, date, time, refundAmount, } = (request.data ?? {});
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
        const fromEmail = getEnv("FROM_EMAIL", false) || "noreply@shuttlebus.com";
        await transporter.sendMail({
            from: `"Ridemate Shuttle" <${fromEmail}>`,
            to: email,
            subject: "🔄 Booking Cancelled - Ridemate Shuttle",
            html: `
        <h1>🔄 Booking Cancelled</h1>
        <p>Your booking has been cancelled:</p>
        <p><strong>Route:</strong> ${origin} → ${destination}</p>
        <p><strong>Date:</strong> ${date} at ${time}</p>
        <p><strong>Refund:</strong> RM ${refundAmount}</p>
        <p>Refund will be processed within 5–10 business days.</p>
      `,
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
