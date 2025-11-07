// lib/driver_home_page.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'driver_dashboard.dart';
import 'driver_schedule_page.dart';
import 'driver_profile_page.dart';
import 'login_page.dart';

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage> {
  int _index = 0;
  final _auth = FirebaseAuth.instance;
  final _fs = FirebaseFirestore.instance;

  Future<void> _ensureDriverDoc(String uid) async {
    final ref = _fs.collection('drivers').doc(uid);
    final snap = await ref.get();
    if (!snap.exists) {
      await ref.set({
        'status': 'offline',
        'disabled': false,
        'createdAt': FieldValue.serverTimestamp(),
        'lastOnline': null,
      }, SetOptions(merge: true));
    }
  }

  Future<void> _setOnline(String uid, bool online) async {
    await _fs.collection('drivers').doc(uid).set({
      'status': online ? 'online' : 'offline',
      if (online) 'lastOnline': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _signOut() async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
          (r) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    if (user == null) {
      Future.microtask(_signOut);
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final docRef = _fs.collection('drivers').doc(user.uid);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: docRef.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          _ensureDriverDoc(user.uid);
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (!snap.hasData || !snap.data!.exists) {
          _ensureDriverDoc(user.uid);
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        final data = snap.data!.data() ?? {};
        final status = (data['status'] ?? 'offline').toString().toLowerCase();
        final isOnline = status == 'online';
        final disabled = (data['disabled'] as bool?) ?? false;
        final blocking = disabled || !isOnline;

        // Use your existing dashboard (no named args)
        final pages = const [
          DriverDashboard(),
          DriverSchedulePage(),
          DriverProfilePage(),
        ];

        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFFD32F2F),
            foregroundColor: Colors.white,
            title: const Text('Ridemate', style: TextStyle(fontWeight: FontWeight.w700)),
            actions: [
              Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Text('Online', style: TextStyle(color: Colors.white)),
                  ),
                  Switch.adaptive(
                    value: isOnline && !disabled,
                    onChanged: disabled
                        ? null
                        : (v) async {
                      try {
                        await _setOnline(user.uid, v);
                        if (!v && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('You are now offline.')),
                          );
                        }
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed: $e')),
                        );
                      }
                    },
                    activeColor: Colors.white,
                    activeTrackColor: Colors.white70,
                    inactiveThumbColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                  ),
                  IconButton(
                    tooltip: 'Sign out',
                    icon: const Icon(Icons.logout),
                    onPressed: _signOut,
                  ),
                ],
              ),
            ],
          ),

          body: Stack(
            children: [
              AbsorbPointer(
                absorbing: blocking,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: blocking ? 0.4 : 1,
                  child: IndexedStack(index: _index, children: pages),
                ),
              ),
              if (blocking)
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: disabled ? const Color(0xFFFFEBEE) : const Color(0xFFFFF8E1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: disabled ? const Color(0xFFE57373) : const Color(0xFFFFE082),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(disabled ? Icons.block : Icons.cloud_off,
                            color: disabled ? const Color(0xFFC62828) : const Color(0xFFE65100)),
                        const SizedBox(width: 8),
                        Text(
                          disabled ? 'Account disabled. Contact admin.'
                              : 'Go online to enable dashboard & trips.',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: disabled ? const Color(0xFFC62828) : const Color(0xFF6D4C41),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),

          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) {
              if (blocking) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(disabled
                        ? 'Account disabled by admin.'
                        : 'Go online to use the app.'),
                  ),
                );
                return;
              }
              setState(() => _index = i);
            },
            indicatorColor: const Color(0xFFFFEBEE),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'Trips'),
              NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
            ],
          ),
        );
      },
    );
  }
}
