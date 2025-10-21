// lib/pages/test_notification_page.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class TestNotificationPage extends StatefulWidget {
  const TestNotificationPage({Key? key}) : super(key: key);

  @override
  State<TestNotificationPage> createState() => _TestNotificationPageState();
}

class _TestNotificationPageState extends State<TestNotificationPage> {
  String _status = 'Ready to test';
  String? _fcmToken;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initializeFCM();
  }

  Future<void> _initializeFCM() async {
    try {
      // Request notification permission
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        setState(() => _status = 'Notification permission granted ✅');
      } else {
        setState(() => _status = 'Notification permission denied ❌');
        return;
      }

      // Get FCM token
      final token = await FirebaseMessaging.instance.getToken();
      setState(() {
        _fcmToken = token;
        _status = 'FCM Token obtained ✅';
      });

      print('📱 FCM Token: $token');

      // Save to Firestore
      await _saveFCMToken(token);
    } catch (e) {
      setState(() => _status = 'Error initializing FCM: $e');
    }
  }

  Future<void> _saveFCMToken(String? token) async {
    if (token == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _status = 'Error: Not signed in');
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'fcmToken': token}, SetOptions(merge: true));

      setState(() => _status = 'FCM token saved to Firestore ✅');
      print('✅ FCM token saved for user: ${user.uid}');
    } catch (e) {
      setState(() => _status = 'Error saving token: $e');
    }
  }

  Future<void> _sendTestNotification() async {
    setState(() {
      _isLoading = true;
      _status = 'Sending test notification...';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() {
          _status = 'Error: Not signed in ❌';
          _isLoading = false;
        });
        return;
      }

      final functions = FirebaseFunctions.instanceFor(
        region: 'asia-southeast1',
      );

      final result = await functions.httpsCallable('sendTripReminder').call({
        'userId': user.uid,
        'origin': 'INTI Penang',
        'destination': 'Relau',
        'time': '4:00 PM',
        'isDriver': false,
      });

      setState(() {
        _status = 'Success! ✅\n${result.data}';
        _isLoading = false;
      });

      print('✅ Notification sent: ${result.data}');
    } catch (e) {
      setState(() {
        _status = 'Error: $e ❌';
        _isLoading = false;
      });
      print('❌ Error: $e');
    }
  }

  Future<void> _checkFirestoreToken() async {
    setState(() {
      _isLoading = true;
      _status = 'Checking Firestore...';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() {
          _status = 'Error: Not signed in';
          _isLoading = false;
        });
        return;
      }

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (doc.exists) {
        final token = doc.data()?['fcmToken'];
        setState(() {
          _status = token != null
              ? 'Token in Firestore ✅\n${token.substring(0, 30)}...'
              : 'No token in Firestore ❌';
          _isLoading = false;
        });
      } else {
        setState(() {
          _status = 'User document not found ❌';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error checking Firestore: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Notifications'),
        backgroundColor: Colors.red,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '🔔 Notification Test',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _status,
                      style: const TextStyle(fontSize: 14),
                    ),
                    if (_fcmToken != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Token: ${_fcmToken!.substring(0, 20)}...',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _initializeFCM,
              icon: const Icon(Icons.refresh),
              label: const Text('1. Initialize FCM'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _checkFirestoreToken,
              icon: const Icon(Icons.storage),
              label: const Text('2. Check Firestore Token'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _sendTestNotification,
              icon: const Icon(Icons.send),
              label: const Text('3. Send Test Notification'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            const Card(
              color: Color(0xFFFFF3CD),
              child: Padding(
                padding: EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '💡 Instructions:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '1. Click "Initialize FCM" to get token\n'
                          '2. Click "Check Firestore" to verify it\'s saved\n'
                          '3. Click "Send Test" to trigger notification\n'
                          '4. Check your notification tray!',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}