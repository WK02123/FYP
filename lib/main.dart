// lib/main.dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_stripe/flutter_stripe.dart'; // Add this import

import 'pages/login_page.dart';

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp();

  // Initialize Stripe with your publishable key
  Stripe.publishableKey = 'pk_test_51SIgpbLQwmM1oR5kPismRY1vyNP7qYAgpXyDRb0Kj576pvL86AHx8bMIKavym2dee7Fb21Eo9UR9xSQWqLOtWYrb00Tz99PoEL'; // Replace with your actual key
  Stripe.merchantIdentifier = 'merchant.inti.edu.shuttle_bus_app'; // Optional, for Apple Pay
  await Stripe.instance.applySettings();

  await _configureLocalFunctionsIfDebug();

  // Sign out on start
  await FirebaseAuth.instance.signOut();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ridemate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.red),
      home: const LoginPage(),
    );
  }
}