// lib/main.dart - PRODUCTION VERSION
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'pages/login_page.dart';

// Initialize local notifications plugin at top level
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

Future<void> _configureLocalFunctionsIfDebug() async {
  if (!kReleaseMode) {
    final functions = FirebaseFunctions.instanceFor(
      app: Firebase.app(),
      region: 'asia-southeast1',
    );
    final host = Platform.isAndroid ? '10.0.2.2' : 'localhost';
    functions.useFunctionsEmulator(host, 5001);
    debugPrint('✅ Cloud Functions emulator: http://$host:5001 (asia-southeast1)');
  }
}

// Print FCM Token for testing
Future<void> printFCMToken() async {
  String? token = await FirebaseMessaging.instance.getToken();
  debugPrint('==========================================');
  debugPrint('📱 FCM Token: $token');
  debugPrint('==========================================');
}

// Setup notification listeners with display capability
Future<void> _setupNotificationListeners() async {
  // Initialize flutter_local_notifications
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      debugPrint('🔔 Notification tapped: ${response.payload}');
      // TODO: Navigate to specific page based on notification type
    },
  );

  // Create notification channel for Android
// Create notification channel for Android
  const androidChannel = AndroidNotificationChannel(
    'trip_reminders',
    'Trip Reminders',
    description: 'Notifications for upcoming trips and bookings',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);

  // Request permission for iOS
  if (Platform.isIOS) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  // Request permission from Firebase Messaging
  final settings = await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    provisional: false,
  );

  if (settings.authorizationStatus == AuthorizationStatus.authorized) {
    debugPrint('✅ Notification permission granted');
  } else if (settings.authorizationStatus == AuthorizationStatus.provisional) {
    debugPrint('⚠️ Notification permission provisional');
  } else {
    debugPrint('❌ Notification permission denied');
  }

  // Handle FOREGROUND notifications - Display them!
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    debugPrint('🔔 Foreground notification received!');
    debugPrint('Title: ${message.notification?.title}');
    debugPrint('Body: ${message.notification?.body}');

    final notification = message.notification;
    final android = message.notification?.android;

    if (notification != null) {
      flutterLocalNotificationsPlugin.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            androidChannel.id,
            androidChannel.name,
            channelDescription: androidChannel.description,
            icon: android?.smallIcon ?? '@mipmap/ic_launcher',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            color: const Color(0xFFD32F2F),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: message.data.toString(),
      );
      debugPrint('✅ Notification displayed!');
    }
  });

  // Handle notification tap when app is in BACKGROUND
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    debugPrint('🔔 Notification tapped (background)!');
    // TODO: Navigate based on notification data
  });

  // Handle notification tap when app was TERMINATED
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    debugPrint('🔔 App opened from notification (terminated)!');
    // TODO: Navigate based on notification data
  }

  // Listen for token refresh
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    debugPrint('🔄 FCM Token refreshed');
    _saveTokenToFirestore(newToken);
  });
}

// Initialize notification service and save FCM token
Future<void> _initializeNotificationService() async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('⚠️ No user logged in yet');
      return;
    }

    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _saveTokenToFirestore(token);
    }
  } catch (e) {
    debugPrint('❌ Error initializing notification service: $e');
  }
}

// Save FCM token to Firestore
Future<void> _saveTokenToFirestore(String token) async {
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'fcmToken': token,
      'lastTokenUpdate': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    debugPrint('✅ FCM token saved to Firestore');
  } catch (e) {
    debugPrint('❌ Error saving token: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();

  // Initialize Stripe with your publishable key
  Stripe.publishableKey =
  'pk_test_51SIgpbLQwmM1oR5kPismRY1vyNP7qYAgpXyDRb0Kj576pvL86AHx8bMIKavym2dee7Fb21Eo9UR9xSQWqLOtWYrb00Tz99PoEL';
  Stripe.merchantIdentifier = 'merchant.inti.edu.shuttle_bus_app';
  await Stripe.instance.applySettings();

  // Configure Cloud Functions emulator if in debug mode
  await _configureLocalFunctionsIfDebug();

  // Setup notification listeners
  await _setupNotificationListeners();

  // Initialize Notification Service (save FCM token)
  await _initializeNotificationService();

  // Print FCM Token for testing
  await printFCMToken();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ridemate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.red,
        primaryColor: const Color(0xFFD32F2F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD32F2F),
          primary: const Color(0xFFD32F2F),
        ),
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}