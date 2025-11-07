// lib/main.dart
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

/// ---------- NEW: ensureSignedIn helper (anonymous sign-in) ----------
Future<void> ensureSignedIn() async {
  final auth = FirebaseAuth.instance;
  if (auth.currentUser == null) {
    await auth.signInAnonymously();
  }
}
/// -------------------------------------------------------------------

/// Single global instance of flutter_local_notifications
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

/// Channels (must match those used by the server)
const AndroidNotificationChannel kTripRemindersChannel = AndroidNotificationChannel(
  'trip_reminders',
  'Trip Reminders',
  description: '30-min and immediate trip reminders',
  importance: Importance.high,
  playSound: true,
);

const AndroidNotificationChannel kBookingUpdatesChannel = AndroidNotificationChannel(
  'booking_updates',
  'Booking Updates',
  description: 'Booking confirmations and updates',
  importance: Importance.high,
  playSound: true,
);

/// NEW: route alerts for driver-reported issues/delays
const AndroidNotificationChannel kRouteAlertsChannel = AndroidNotificationChannel(
  'route_alerts',
  'Route Alerts',
  description: 'Delay & disruption notices from drivers',
  importance: Importance.high,
  playSound: true,
);

/// Background message handler (must be a top-level function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // If you need background processing, uncomment:
  // await Firebase.initializeApp();
  // print('[BG] message: ${message.data}');
}

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

/// Save FCM token to Firestore for the given user
Future<void> _saveTokenToFirestore(User user, String token) async {
  try {
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'fcmToken': token,
      'lastTokenUpdate': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    debugPrint('✅ Saved FCM token for ${user.uid}');
  } catch (e) {
    debugPrint('❌ Error saving token: $e');
  }
}

/// Ensure token is synced for this user (request permission → get token → save)
Future<void> _syncTokenFor(User user) async {
  // 1) Ask notification permission (Android 13+, iOS)
  final settings = await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    provisional: false,
  );
  debugPrint('🔐 Permission for ${user.uid}: ${settings.authorizationStatus}');
  if (settings.authorizationStatus == AuthorizationStatus.denied) {
    debugPrint('❌ Notifications denied by user, skip saving token.');
    return;
  }

  // 2) Get token
  final token = await FirebaseMessaging.instance.getToken();
  debugPrint('🔑 FCM token for ${user.uid}: $token');
  if (token == null) {
    debugPrint('⚠️ No FCM token returned (Play Services? network?)');
    return;
  }

  // 3) Save token
  await _saveTokenToFirestore(user, token);
}

/// Ask for permissions, set up local notifs & FCM listeners
Future<void> _setupPushAndLocalNotifications(BuildContext context) async {
  // 1) Init local notifications
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      debugPrint('🔔 Notification tapped: ${response.payload}');
      // TODO: route by payload if you want deep links
    },
  );

  // 2) Create Android channels
  final androidFln = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidFln?.createNotificationChannel(kTripRemindersChannel);
  await androidFln?.createNotificationChannel(kBookingUpdatesChannel);
  await androidFln?.createNotificationChannel(kRouteAlertsChannel);

  // 3) Background handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // 4) Foreground messages → show local banner
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    final title = message.notification?.title ?? 'Notification';
    final body = message.notification?.body ?? '';
    final channelId = (message.data['channelId'] as String?) ?? kTripRemindersChannel.id;

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelId == kBookingUpdatesChannel.id
          ? kBookingUpdatesChannel.name
          : channelId == kRouteAlertsChannel.id
          ? kRouteAlertsChannel.name
          : kTripRemindersChannel.name,
      channelDescription: channelId == kBookingUpdatesChannel.id
          ? kBookingUpdatesChannel.description
          : channelId == kRouteAlertsChannel.id
          ? kRouteAlertsChannel.description
          : kTripRemindersChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      icon: '@mipmap/ic_launcher',
      color: const Color(0xFFD32F2F),
    );

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: message.data.toString(),
    );
  });

  // 5) Taps when app resumed from background
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    debugPrint('🔔 Notification tapped (background): ${message.data}');
  });

  // 6) App opened from terminated by notif
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    debugPrint('🔔 Opened from terminated: ${initialMessage.data}');
  }

  // 7) Keep token in sync on refresh (for whichever user is signed in)
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
    final user = FirebaseAuth.instance.currentUser;
    debugPrint('🔄 Token refresh: $newToken (user: ${user?.uid})');
    if (user != null && newToken.isNotEmpty) {
      await _saveTokenToFirestore(user, newToken);
    }
  });
}

/// Debug helper
Future<void> printFCMToken() async {
  final token = await FirebaseMessaging.instance.getToken();
  debugPrint('==========================================');
  debugPrint('📱 FCM Token (debug print): $token');
  debugPrint('==========================================');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // ---------- NEW: make sure we’re authenticated for Firestore rules ----------
  await ensureSignedIn(); // 👈 anonymous sign-in if needed
  // ---------------------------------------------------------------------------

  // Stripe (keep your keys)
  Stripe.publishableKey =
  'pk_test_51SIgpbLQwmM1oR5kPismRY1vyNP7qYAgpXyDRb0Kj576pvL86AHx8bMIKavym2dee7Fb21Eo9UR9xSQWqLOtWYrb00Tz99PoEL';
  Stripe.merchantIdentifier = 'merchant.inti.edu.shuttle_bus_app';
  await Stripe.instance.applySettings();

  // Emulator config (debug only)
  /*await _configureLocalFunctionsIfDebug();*/

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
      home: const _Bootstrap(),
    );
  }
}

/// Small bootstrap widget so we have a BuildContext to pass to setup
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({super.key});
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Stream<User?> _authSub;

  @override
  void initState() {
    super.initState();

    // Set up local + FCM foreground handlers/channels
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _setupPushAndLocalNotifications(context);
      await printFCMToken();
    });

    // 🔑 Keep FCM token in Firestore when auth changes (includes anonymous)
    _authSub = FirebaseAuth.instance.authStateChanges();
    _authSub.listen((user) async {
      if (user == null) {
        debugPrint('👤 User signed OUT — will save token after next sign-in.');
        return;
      }
      debugPrint('👤 User signed IN: ${user.uid} — syncing FCM token...');
      await _syncTokenFor(user);
    });

    // If already logged in at app start, sync token once
    final existing = FirebaseAuth.instance.currentUser;
    if (existing != null) {
      _syncTokenFor(existing);
    }
  }

  @override
  Widget build(BuildContext context) {
    return const LoginPage();
  }
}
