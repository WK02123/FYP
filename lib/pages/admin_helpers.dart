// lib/pages/admin_helpers.dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Admin-only: creates a Firebase Auth user and auto-creates Firestore profiles.
/// Uses a secondary Firebase app so the admin stays logged in.
/// [routes] are route keys like "Relau|INTI Penang".
/// If [attachDriverToRoutes] is true, each route doc will get driverId=<uid>.
Future<String> adminCreateDriverAccount({
  required String email,
  required String password,
  required String name,
  required String phone,
  String busCode = '',
  List<String> routes = const <String>[],
  bool attachDriverToRoutes = true,
  bool sendVerification = true,
}) async {
  FirebaseApp? secondaryApp;
  try {
    // Secondary app so admin’s session is preserved.
    final defaultApp = Firebase.app();
    secondaryApp = await Firebase.initializeApp(
      name: 'admin-helper',
      options: defaultApp.options,
    );
    final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);

    // Create Auth user (the driver).
    final cred = await secondaryAuth.createUserWithEmailAndPassword(
      email: email.trim().toLowerCase(),
      password: password,
    );
    final uid = cred.user!.uid;

    final fs = FirebaseFirestore.instance;

    // Create drivers/{uid}
    await fs.collection('drivers').doc(uid).set({
      'name': name.trim(),
      'email': email.trim().toLowerCase(),
      'phone': phone.trim(),
      'busCode': busCode.trim(),
      'status': 'offline',
      'role': 'driver',
      'disabled': false,
      'updatedAt': FieldValue.serverTimestamp(),
      'driverId': uid,                 // convenience duplicate
      'routes': routes,                // <-- save route keys here
    });

    // Mirror into users/{uid}
    await fs.collection('users').doc(uid).set({
      'name': name.trim(),
      'email': email.trim().toLowerCase(),
      'phone': phone.trim(),
      'role': 'driver',
      'disabled': false,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // Optionally attach the driver to each route doc.
    if (attachDriverToRoutes) {
      final batch = fs.batch();
      for (final key in routes) {
        final ref = fs.collection('routes').doc(key);
        batch.set(ref, {
          'driverId': uid,
          if (busCode.trim().isNotEmpty) 'busCode': busCode.trim(),
          'active': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      await batch.commit();
    }

    if (sendVerification) {
      await cred.user!.sendEmailVerification();
    }

    await secondaryAuth.signOut();
    return 'Driver created. Verification email sent to $email';
  } on FirebaseAuthException catch (e) {
    return 'Auth error: ${e.message ?? e.code}';
  } catch (e) {
    return 'Error: $e';
  } finally {
    if (secondaryApp != null) {
      await secondaryApp.delete();
    }
  }
}
