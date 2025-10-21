// lib/services/notification_service.dart
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

  /// Initialize notification service and save FCM token
  Future<void> initialize() async {
    try {
      // Get current user
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('⚠️ No user logged in, skipping FCM token save');
        return;
      }

      // Get FCM token
      final token = await _messaging.getToken();
      if (token == null) {
        debugPrint('⚠️ Failed to get FCM token');
        return;
      }

      debugPrint('📱 Saving FCM token for user: ${user.uid}');

      // Save token to Firestore
      await _firestore.collection('users').doc(user.uid).set({
        'fcmToken': token,
        'lastTokenUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('✅ FCM token saved successfully');

      // Listen for token refresh
      _messaging.onTokenRefresh.listen((newToken) {
        _saveTokenToFirestore(newToken);
      });

    } catch (e) {
      debugPrint('❌ Error initializing notification service: $e');
    }
  }

  /// Save or update FCM token in Firestore
  Future<void> _saveTokenToFirestore(String token) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await _firestore.collection('users').doc(user.uid).set({
        'fcmToken': token,
        'lastTokenUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint('✅ FCM token updated');
    } catch (e) {
      debugPrint('❌ Error saving token: $e');
    }
  }

  /// Schedule a notification for a booking (called when user books)
  Future<void> scheduleBookingReminder({
    required String bookingId,
    required String origin,
    required String destination,
    required String date,
    required String time,
    required DateTime departureDateTime,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('⚠️ No user logged in');
        return;
      }

      // Calculate when to send reminder (1 hour before departure)
      final reminderTime = departureDateTime.subtract(const Duration(hours: 1));
      final now = DateTime.now();

      // Only schedule if reminder time is in the future
      if (reminderTime.isBefore(now)) {
        debugPrint('⚠️ Reminder time is in the past, skipping');
        return;
      }

      // Save reminder info to Firestore (for scheduled functions to process)
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
        'createdAt': FieldValue.serverTimestamp(),
      });

      debugPrint('✅ Reminder scheduled for $reminderTime');
    } catch (e) {
      debugPrint('❌ Error scheduling reminder: $e');
    }
  }

  /// Send immediate trip reminder (for testing or immediate needs)
  Future<bool> sendTripReminder({
    required String origin,
    required String destination,
    required String time,
    bool isDriver = false,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('⚠️ No user logged in');
        return false;
      }

      debugPrint('📤 Sending trip reminder via Cloud Function...');

      final result = await _functions.httpsCallable('sendTripReminder').call({
        'userId': user.uid,
        'origin': origin,
        'destination': destination,
        'time': time,
        'isDriver': isDriver,
      });

      final success = result.data['success'] == true;

      if (success) {
        debugPrint('✅ Trip reminder sent successfully');
      } else {
        debugPrint('⚠️ Trip reminder failed: ${result.data['message']}');
      }

      return success;
    } catch (e) {
      debugPrint('❌ Error sending trip reminder: $e');
      return false;
    }
  }

  /// Send booking confirmation email
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
      debugPrint('📧 Sending booking confirmation email...');

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

      if (success) {
        debugPrint('✅ Booking email sent successfully');
      } else {
        debugPrint('⚠️ Booking email failed');
      }

      return success;
    } catch (e) {
      debugPrint('❌ Error sending booking email: $e');
      return false;
    }
  }

  /// Send cancellation email
  Future<bool> sendCancellationEmail({
    required String email,
    required String origin,
    required String destination,
    required String date,
    required String time,
    required String refundAmount,
  }) async {
    try {
      debugPrint('📧 Sending cancellation email...');

      final result = await _functions.httpsCallable('sendCancellationEmail').call({
        'email': email,
        'origin': origin,
        'destination': destination,
        'date': date,
        'time': time,
        'refundAmount': refundAmount,
      });

      final success = result.data['success'] == true;

      if (success) {
        debugPrint('✅ Cancellation email sent successfully');
      } else {
        debugPrint('⚠️ Cancellation email failed');
      }

      return success;
    } catch (e) {
      debugPrint('❌ Error sending cancellation email: $e');
      return false;
    }
  }

  /// Cancel a scheduled reminder
  Future<void> cancelReminder(String bookingId) async {
    try {
      await _firestore.collection('scheduled_notifications').doc(bookingId).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
      debugPrint('✅ Reminder cancelled for booking: $bookingId');
    } catch (e) {
      debugPrint('❌ Error cancelling reminder: $e');
    }
  }

  /// Get user's upcoming bookings that need reminders
  Stream<List<Map<String, dynamic>>> watchUpcomingBookings() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Stream.value([]);
    }

    return _firestore
        .collection('bookings')
        .where('userId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'confirmed')
        .orderBy('departureDateTime')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id;
        return data;
      }).toList();
    });
  }

  /// Check and send reminders for bookings happening soon
  Future<void> checkAndSendUpcomingReminders() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Get bookings in the next 2 hours
      final now = DateTime.now();
      final twoHoursFromNow = now.add(const Duration(hours: 2));

      final snapshot = await _firestore
          .collection('bookings')
          .where('userId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'confirmed')
          .where('departureDateTime', isGreaterThan: Timestamp.fromDate(now))
          .where('departureDateTime', isLessThan: Timestamp.fromDate(twoHoursFromNow))
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final notificationSent = data['reminderSent'] ?? false;

        if (!notificationSent) {
          // Send reminder
          await sendTripReminder(
            origin: data['origin'] ?? '',
            destination: data['destination'] ?? '',
            time: data['time'] ?? '',
          );

          // Mark as sent
          await doc.reference.update({'reminderSent': true});
        }
      }
    } catch (e) {
      debugPrint('❌ Error checking upcoming reminders: $e');
    }
  }

  /// Remove FCM token on logout
  Future<void> removeToken() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      await _firestore.collection('users').doc(user.uid).update({
        'fcmToken': FieldValue.delete(),
      });

      debugPrint('✅ FCM token removed');
    } catch (e) {
      debugPrint('❌ Error removing token: $e');
    }
  }
  /// Delete a scheduled notification when booking is cancelled
  Future<void> deleteScheduledNotification(String notificationId) async {
    try {
      await _firestore
          .collection('scheduled_notifications')
          .doc(notificationId)
          .delete();

      debugPrint('✅ Scheduled notification deleted: $notificationId');
    } catch (e) {
      debugPrint('❌ Error deleting scheduled notification: $e');
    }
  }

  /// Build notification ID from booking details
  static String buildNotificationId({
    required String userId,
    required String scheduleId,
    required String date,
  }) {
    return '${userId}_${scheduleId}_$date';
  }
}
