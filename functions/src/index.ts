// functions/src/index.ts
import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";

/** ───────────────────────────────
 *  Load .env.local only in local/dev
 *  (Cloud Functions prod uses process.env / Secrets)
 *  ─────────────────────────────── */
 // Load .env.local when running locally (emulator)
 import * as path from "path";
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
   } catch (e) {
     console.warn("⚠️ dotenv/config load skipped:", e);
   }
 })();


(() => {
  try {
    // Detect emulator / local run
    const isLocal =
      process.env.FUNCTIONS_EMULATOR === "true" ||
      process.env.GCLOUD_PROJECT === undefined ||
      process.env.K_SERVICE === undefined;

    if (isLocal) {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const fs = require("fs") as typeof import("fs");
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const path = require("path") as typeof import("path");
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const dotenv = require("dotenv") as typeof import("dotenv");

      const envPath = path.join(__dirname, "..", ".env.local");
      if (fs.existsSync(envPath)) {
        dotenv.config({ path: envPath });
        logger.info("Loaded environment from .env.local");
      } else {
        logger.warn(".env.local not found at functions/.env.local");
      }
    }
  } catch (e) {
    logger.warn("Skipping .env.local load:", e);
  }
})();

/** ---------- Helpers ---------- */
const REGION = "asia-southeast1" as const;

const getEnv = (key: string, required = true): string => {
  const v = process.env[key];
  if (!v && required) throw new Error(`${key} not configured`);
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

const getAdmin = (): typeof import("firebase-admin") => {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const admin = require("firebase-admin");
  if (!admin.apps.length) admin.initializeApp();
  return admin;
};

/** ---------- Health check ---------- */
export const hello = onRequest({ region: REGION }, (_req, res) => {
  res.status(200).send("ok");
});

/** ---------- Create Payment Intent (Stripe) ---------- */
export const createPaymentIntent = onCall({ region: REGION }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required");

  const {
    amount,
    currency = "myr",
    description = "Bus ticket payment",
  } = (request.data ?? {}) as {
    amount: number | string;
    currency?: string;
    description?: string;
  };

  const numAmount = Number(amount);
  if (!Number.isFinite(numAmount) || numAmount <= 0) {
    throw new HttpsError("invalid-argument", "amount must be > 0");
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
  } catch (err: unknown) {
    const e = err as Error & { message?: string };
    logger.error("Stripe error:", e);
    throw new HttpsError("internal", e?.message ?? "Payment processing failed");
  }
});

/** ---------- Refund Payment (Stripe) ---------- */
export const refundPayment = onCall({ region: REGION }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required");

  const { paymentIntentId, amount } = (request.data ?? {}) as {
    paymentIntentId?: string;
    amount?: number;
  };
  if (!paymentIntentId) throw new HttpsError("invalid-argument", "paymentIntentId is required");

  try {
    const stripe = getStripe();
    const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
    const latestCharge = pi.latest_charge;
    if (!latestCharge) {
      throw new HttpsError("failed-precondition", "No charge found for this payment");
    }
    const chargeId = typeof latestCharge === "string" ? latestCharge : latestCharge.id;

    const refund = await stripe.refunds.create({
      charge: chargeId,
      amount: amount && amount > 0 ? Math.trunc(amount) : undefined,
      metadata: { userId: request.auth.uid, refundedAt: new Date().toISOString() },
    });

    logger.info("Refund created:", refund.id);
    return { success: true, refundId: refund.id, amount: refund.amount, status: refund.status };
  } catch (err: unknown) {
    const e = err as Error & { message?: string };
    logger.error("Refund error:", e);
    throw new HttpsError("internal", e?.message ?? "Refund processing failed");
  }
});

/** ---------- Booking Confirmation Email (SendGrid SMTP) ---------- */
export const sendBookingEmail = onCall({ region: REGION }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required");

  const {
    email,
    name: _name, // unused on purpose
    origin,
    destination,
    date,
    time,
    seats,
    totalAmount,
  } = (request.data ?? {}) as {
    email?: string;
    name?: string;
    origin?: string;
    destination?: string;
    date?: string;
    time?: string;
    seats?: string | number;
    totalAmount?: string | number;
  };

  if (!email) throw new HttpsError("invalid-argument", "Email is required");

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

    logger.info("Booking email sent to:", email);
    return { success: true };
  } catch (err: unknown) {
    const e = err as Error & { message?: string };
    logger.error("Email error:", e);
    throw new HttpsError("internal", e?.message ?? "Failed to send email");
  }
});

/** ---------- Cancellation Email (SendGrid SMTP) ---------- */
export const sendCancellationEmail = onCall({ region: REGION }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required");

  const {
    email,
    name: _name2, // unused
    origin,
    destination,
    date,
    time,
    refundAmount,
  } = (request.data ?? {}) as {
    email?: string;
    name?: string;
    origin?: string;
    destination?: string;
    date?: string;
    time?: string;
    refundAmount?: string | number;
  };

  if (!email) throw new HttpsError("invalid-argument", "Email is required");

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

    logger.info("Cancellation email sent to:", email);
    return { success: true };
  } catch (err: unknown) {
    const e = err as Error & { message?: string };
    logger.error("Email error:", e);
    throw new HttpsError("internal", e?.message ?? "Failed to send email");
  }
});

/** ---------- Trip Reminder (FCM via Admin) ---------- */
export const sendTripReminder = onCall({ region: REGION }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required");

  const { userId, origin, destination, time, isDriver } = (request.data ?? {}) as {
    userId?: string;
    origin?: string;
    destination?: string;
    time?: string;
    isDriver?: boolean;
  };

  if (!userId) throw new HttpsError("invalid-argument", "userId is required");

  try {
    const admin = getAdmin();
    const collection = isDriver ? "drivers" : "users";
    const userDoc = await admin.firestore().collection(collection).doc(userId).get();
    if (!userDoc.exists) throw new HttpsError("not-found", "User not found");

    const userData = userDoc.data() as { fcmToken?: string } | undefined;
    const fcmToken = userData?.fcmToken;
    if (!fcmToken) {
      logger.warn(`User ${userId} has no FCM token`);
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

    logger.info(`Reminder sent to user ${userId}`);
    return { success: true };
  } catch (err: unknown) {
    const e = err as Error & { message?: string };
    logger.error("Notification error:", e);
    throw new HttpsError("internal", e?.message ?? "Failed to send notification");
  }
});
