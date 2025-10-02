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

  /// Ensures a driver doc exists with at least {status:'offline'}.
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
      // If somehow not logged in, bounce to login
      Future.microtask(_signOut);
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final pages = const [
      DriverDashboard(),
      DriverSchedulePage(),
      DriverProfilePage(),
    ];

    final docRef = _fs.collection('drivers').doc(user.uid);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: docRef.snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          // Also make sure the doc exists at least once
          _ensureDriverDoc(user.uid);
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (!snap.hasData || !snap.data!.exists) {
          // Create a baseline doc then render loading once
          _ensureDriverDoc(user.uid);
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final data = snap.data!.data() ?? {};
        final status = (data['status'] ?? 'offline').toString().toLowerCase();
        final isOnline = status == 'online';
        final disabled = (data['disabled'] as bool?) ?? false;

        // If admin disabled this account, force offline and block everything.
        final blocking = disabled || !isOnline;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFFD32F2F),
            title: const Text('Driver'),
            foregroundColor: Colors.white,
            actions: [
              // Online switch
              Row(
                children: [
                  const Text('Online', style: TextStyle(color: Colors.white)),
                  Switch.adaptive(
                    value: isOnline && !disabled,
                    onChanged: disabled
                        ? null
                        : (v) async {
                      try {
                        await _setOnline(user.uid, v);
                        if (!v && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('You are now offline.'),
                            ),
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
                  const SizedBox(width: 8),
                ],
              ),
              IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout, color: Colors.white),
                onPressed: _signOut,
              ),
            ],
          ),

          // Body: show page, but absorb input when offline/disabled and overlay a blocker.
          body: Stack(
            children: [
              // Main content
              // We still show it (dimmed) so drivers see context,
              // but can’t interact when offline.
              AbsorbPointer(
                absorbing: blocking,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: blocking ? 0.4 : 1.0,
                  child: pages[_index],
                ),
              ),

              // Blocking overlay (if offline or disabled)
              if (blocking)
                Container(
                  color: Colors.black.withOpacity(0.05),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Card(
                      elevation: 6,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              disabled ? Icons.block : Icons.cloud_off,
                              size: 56,
                              color: disabled ? Colors.red : Colors.grey,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              disabled
                                  ? 'Account Disabled'
                                  : 'You’re Offline',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              disabled
                                  ? 'Please contact admin for access.'
                                  : 'Go online to access dashboard, schedule, and other actions.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.black54),
                            ),
                            const SizedBox(height: 16),
                            if (!disabled)
                              ElevatedButton.icon(
                                onPressed: () => _setOnline(user.uid, true),
                                icon: const Icon(Icons.wifi),
                                label: const Text('Go Online'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFD32F2F),
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size.fromHeight(44),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            if (disabled) ...[
                              const SizedBox(height: 12),
                              const Text(
                                'You can still sign out from the top-right.',
                                style: TextStyle(
                                  color: Colors.black45,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // Bottom navigation: blocked when offline/disabled
          bottomNavigationBar: AbsorbPointer(
            absorbing: blocking,
            child: Opacity(
              opacity: blocking ? 0.4 : 1.0,
              child: BottomNavigationBar(
                currentIndex: _index,
                selectedItemColor: Colors.red,
                unselectedItemColor: Colors.grey,
                onTap: (i) {
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
                items: const [
                  BottomNavigationBarItem(icon: Icon(Icons.home), label: ''),
                  BottomNavigationBarItem(icon: Icon(Icons.schedule), label: ''),
                  BottomNavigationBarItem(icon: Icon(Icons.person), label: ''),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
