// lib/notification_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final _firestore = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'asia-southeast1');
  final _messaging = FirebaseMessaging.instance;

  /// Persist token now (call after login) + subscribe to refresh
  Future<void> initializeAfterLogin() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('⚠️ No user logged in, skipping token save');
        return;
      }
      final token = await _messaging.getToken();
      if (token != null) {
        await _saveTokenToFirestore(token);
      }
      _messaging.onTokenRefresh.listen((newToken) => _saveTokenToFirestore(newToken));
    } catch (e) {
      debugPrint('❌ Error initializing notification service: $e');
    }
  }

  Future<void> _saveTokenToFirestore(String token) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      await _firestore.collection('users').doc(user.uid).set({
        'fcmToken': token,
        'lastTokenUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      debugPrint('✅ FCM token updated for ${user.uid}');
    } catch (e) {
      debugPrint('❌ Error saving token: $e');
    }
  }

  /// Save schedule for cron-based reminders (server will send it)
  Future<void> scheduleBookingReminder({
    required String bookingId,
    required String origin,
    required String destination,
    required String date,
    required String time,
    required DateTime departureDateTime,
    String? snapshotFcmToken, // optional but robust
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final reminderTime = departureDateTime.subtract(const Duration(minutes: 30));
      final now = DateTime.now();
      if (reminderTime.isBefore(now)) {
        debugPrint('⚠️ Reminder time is in the past, skipping schedule');
        return;
      }

      await _firestore.collection('scheduled_notifications').doc(bookingId).set({
        'userId': user.uid,
        'bookingId': bookingId,
        'type': 'trip_reminder',
        'origin': origin,
        'destination': destination,
        'date': date,
        'time': time,
        'departureDateTime': Timestamp.fromDate(departureDateTime),
        'reminderTime': Timestamp.fromDate(reminderTime),
        'status': 'scheduled',
        'isDriver': false,
        if (snapshotFcmToken != null) 'snapshotFcmToken': snapshotFcmToken,
        'createdAt': FieldValue.serverTimestamp(),
      });

      debugPrint('✅ Reminder scheduled for $reminderTime');
    } catch (e) {
      debugPrint('❌ Error scheduling reminder: $e');
    }
  }

  /// Send immediate reminder via callable
  Future<bool> sendTripReminder({
    required String origin,
    required String destination,
    required String time,
    bool isDriver = false,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;

      debugPrint('📤 Calling sendTripReminder CF...');
      final result = await _functions.httpsCallable('sendTripReminder').call({
        'userId': user.uid,
        'origin': origin,
        'destination': destination,
        'time': time,
        'isDriver': isDriver,
      });

      final success = result.data['success'] == true;
      if (!success) {
        debugPrint('⚠️ sendTripReminder failed: ${result.data}');
      } else {
        debugPrint('✅ sendTripReminder OK');
      }
      return success;
    } catch (e) {
      debugPrint('❌ Error sending trip reminder: $e');
      return false;
    }
  }

  /// Emails via callables
  Future<bool> sendBookingConfirmation({
    required String email,
    required String origin,
    required String destination,
    required String date,
    required String time,
    required String seats,
    required String totalAmount,
  }) async {
    try {
      final result = await _functions.httpsCallable('sendBookingEmail').call({
        'email': email,
        'origin': origin,
        'destination': destination,
        'date': date,
        'time': time,
        'seats': seats,
        'totalAmount': totalAmount,
      });
      final success = result.data['success'] == true;
      if (!success) debugPrint('⚠️ Booking email failed: ${result.data}');
      return success;
    } catch (e) {
      debugPrint('❌ Error sending booking email: $e');
      return false;
    }
  }

  Future<bool> sendCancellationEmail({
    required String email,
    required String origin,
    required String destination,
    required String date,
    required String time,
    required String refundAmount,
  }) async {
    try {
      final result =
      await _functions.httpsCallable('sendCancellationEmail').call({
        'email': email,
        'origin': origin,
        'destination': destination,
        'date': date,
        'time': time,
        'refundAmount': refundAmount,
      });
      final success = result.data['success'] == true;
      if (!success) debugPrint('⚠️ Cancellation email failed: ${result.data}');
      return success;
    } catch (e) {
      debugPrint('❌ Error sending cancellation email: $e');
      return false;
    }
  }

  Future<void> cancelReminder(String bookingId) async {
    try {
      await _firestore.collection('scheduled_notifications').doc(bookingId).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
      debugPrint('✅ Reminder cancelled for $bookingId');
    } catch (e) {
      debugPrint('❌ Error cancelling reminder: $e');
    }
  }

  Future<void> deleteScheduledNotification(String notificationId) async {
    try {
      await _firestore.collection('scheduled_notifications').doc(notificationId).delete();
      debugPrint('✅ Scheduled notification deleted: $notificationId');
    } catch (e) {
      debugPrint('❌ Error deleting scheduled notification: $e');
    }
  }

  static String buildNotificationId({
    required String userId,
    required String scheduleId,
    required String date,
  }) {
    return '${userId}_${scheduleId}_$date';
    // This must match what your booking code uses to write the schedule doc id
  }
}
