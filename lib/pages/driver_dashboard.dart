// lib/pages/driver_dashboard.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'driver_scan_page.dart';
import 'driver_service.dart';
import 'driver_schedule_page.dart';
import 'login_page.dart';
import 'driver_gps_page.dart'; // 👈 GPS page

class DriverDashboard extends StatefulWidget {
  const DriverDashboard({super.key});

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> {
  final _svc = DriverService.instance;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _driverSub;

  bool _sharing = false; // mirrors Firestore "status":"online"
  String _name = 'Driver';
  String _busCode = '-';
  String _status = 'offline';
  String _driverDocId = '';

  @override
  void initState() {
    super.initState();
    _driverSub = _svc.driverStream().listen((snap) {
      final data = snap.data() ?? {};
      setState(() {
        _name = (data['name'] ?? 'Driver').toString();
        _busCode = (data['busCode'] ?? '-').toString();
        _status = (data['status'] ?? 'offline').toString();
        _sharing = _status == 'online';
        _driverDocId = snap.id;
      });
    });
  }

  @override
  void dispose() {
    _driverSub?.cancel();
    super.dispose();
  }

  String _prettyDate(String? ymd) {
    if (ymd == null || ymd.isEmpty) return '--';
    try {
      final dt = DateTime.parse(ymd);
      const months = [
        'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
    } catch (_) {
      return ymd;
    }
  }

  Future<void> _toggleSharing(bool on) async {
    try {
      if (on) {
        await _svc.startSharingLocation(); // starts stream + sets status online
      } else {
        await _svc.stopSharingLocation();  // cancels stream + sets status offline
      }
      setState(() => _sharing = on);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to change status: $e')),
      );
    }
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
    );
  }

  void _openGps() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DriverGpsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = _svc;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        title: const Text("Ridemate"),
        centerTitle: true,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan QR',
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const DriverScanPage()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: _logout,
          ),
        ],
      ),

      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Profile + Online/Offline
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ListTile(
                leading: const Icon(Icons.person, size: 40, color: Colors.red),
                title: Text(_name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('Bus: $_busCode'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _sharing ? 'Online' : 'Offline',
                      style: TextStyle(
                        color: _sharing ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Switch.adaptive(
                      value: _sharing,
                      activeColor: Colors.green,
                      onChanged: (v) => _toggleSharing(v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),

            if (_sharing)
              Row(
                children: const [
                  Icon(Icons.location_on, color: Colors.green),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Live location is being shared with students on your current route.',
                      style: TextStyle(color: Colors.green),
                    ),
                  ),
                ],
              ),
            if (_sharing) const SizedBox(height: 10),

            Align(
              alignment: Alignment.centerLeft,
              child: Text("Report Issue", style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 10,
              children: const [
                _IssueChip(label: 'Accident', icon: Icons.car_crash),
                _IssueChip(label: 'Delay', icon: Icons.schedule),
                _IssueChip(label: 'Mechanical', icon: Icons.build),
                _IssueChip(label: 'Emergency', icon: Icons.warning_amber),
              ],
            ),
            const SizedBox(height: 20),

            // Today's trip card
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: svc.todayTrips(),
                builder: (context, snap) {
                  if (snap.hasError) return const _EmptyCard(text: "Error loading trips");
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());

                  final uid = FirebaseAuth.instance.currentUser!.uid;
                  final all = snap.data!.docs;
                  final driverDocs = all.where((d) => d.id.startsWith(uid)).toList();

                  if (driverDocs.isEmpty) {
                    return const _EmptyCard(text: "No trips scheduled for today");
                  }

                  final next = driverDocs.first.data();
                  final dateStr = _prettyDate(next['date']?.toString());
                  final timeStr = next['time']?.toString() ?? '--:--';
                  final origin = next['origin'] ?? '-';
                  final dest = next['destination'] ?? '-';

                  return Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: ListTile(
                      title: Text('$dateStr • $timeStr', style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('$origin → $dest'),
                      trailing: const Icon(Icons.chevron_right, size: 28),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const DriverSchedulePage()),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),

      // ⬇️ Center GPS FAB + BottomAppBar
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFD32F2F),
        onPressed: _openGps,
        tooltip: 'View My GPS',
        child: const Icon(Icons.map, color: Colors.white),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        height: 64,
        color: Colors.white,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left: Scan
            IconButton(
              tooltip: 'Scan QR',
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const DriverScanPage()));
              },
            ),

            // Right: Schedule
            IconButton(
              tooltip: 'Today\'s Schedule',
              icon: const Icon(Icons.event_note),
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const DriverSchedulePage()));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _IssueChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, color: Colors.red),
      label: Text(label),
      onPressed: () async {
        final result = await showDialog<_IssueDialogResult>(
          context: context,
          builder: (_) => _IssueDialog(type: label),
        );
        if (result == null) return;

        try {
          await DriverService.instance.reportIssueAndNotify(
            type: label,
            note: result.note,
            delayMinutes: result.delayMinutes,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$label reported. Students notified.')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to report: $e')),
            );
          }
        }
      },
      shape: StadiumBorder(side: BorderSide(color: Colors.red.shade100)),
    );
  }
}

class _IssueDialogResult {
  final String note;
  final int? delayMinutes;
  _IssueDialogResult(this.note, this.delayMinutes);
}

class _IssueDialog extends StatefulWidget {
  final String type;
  const _IssueDialog({required this.type});

  @override
  State<_IssueDialog> createState() => _IssueDialogState();
}

class _IssueDialogState extends State<_IssueDialog> {
  final _note = TextEditingController();
  final _delay = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    _delay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Report ${widget.type}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _note,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'Describe the issue briefly',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _delay,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Delay minutes (optional)',
              hintText: 'e.g. 10',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _sending ? null : () async {
            setState(() => _sending = true);
            final minutes = int.tryParse(_delay.text.trim());
            Navigator.pop(context, _IssueDialogResult(_note.text.trim(), minutes));
          },
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: _sending
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Send'),
        )
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String text;
  const _EmptyCard({required this.text});
  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text(text, style: const TextStyle(color: Colors.grey)),
        ),
      ),
    );
  }
}
