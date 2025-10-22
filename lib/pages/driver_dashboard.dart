// lib/pages/driver_dashboard.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'driver_scan_page.dart';
import 'driver_service.dart';
import 'driver_schedule_page.dart';
import 'login_page.dart';

class DriverDashboard extends StatelessWidget {
  const DriverDashboard({super.key});

  void _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
    );
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

  @override
  Widget build(BuildContext context) {
    final svc = DriverService.instance;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        title: const Text("Ridemate"),
        centerTitle: true,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            tooltip: 'Sign out',
            onPressed: () => _logout(context),
          ),
          IconButton(
            tooltip: 'Scan QR',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DriverScanPage()),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: svc.driverStream(),
              builder: (context, snap) {
                final data = snap.data?.data() ?? {};
                final name = data['name']?.toString() ?? 'Driver';
                final status = data['status']?.toString() ?? 'offline';
                return Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: ListTile(
                    leading: const Icon(Icons.person, size: 40, color: Colors.red),
                    title: Text(name),
                    subtitle: Text('Bus: ${data['busCode'] ?? '-'}'),
                    trailing: Text(
                      status == 'online' ? 'Online' : 'Offline',
                      style: TextStyle(
                        color: status == 'online' ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),

            // We will render "Report Issue" _below_ the nearest trip card
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: svc.todayTrips(),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const _EmptyCard(text: "Error loading trips");
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final uid = FirebaseAuth.instance.currentUser!.uid;
                  final all = snap.data!.docs;
                  // filter to only keys starting with this driver (if your IDs are prefixed),
                  // otherwise simply use .orderBy('time') result from query and take the first doc.
                  final driverDocs = all.where((d) => d.id.startsWith(uid)).toList();
                  final docs = driverDocs.isEmpty ? all : driverDocs;

                  if (docs.isEmpty) {
                    return const _EmptyCard(text: "No trips scheduled for today");
                  }

                  // Nearest/first trip for today
                  final nextDoc = docs.first;
                  final next = nextDoc.data();
                  final dateRaw = next['date']?.toString() ?? '';
                  final timeRaw = next['time']?.toString() ?? '';
                  final dateStr = _prettyDate(dateRaw);
                  final origin = next['origin']?.toString() ?? '-';
                  final dest = next['destination']?.toString() ?? '-';

                  return ListView(
                    children: [
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        child: ListTile(
                          title: Text('$dateStr • ${timeRaw.isEmpty ? "--:--" : timeRaw}'),
                          subtitle: Text('$origin → $dest'),
                          trailing: const Icon(Icons.chevron_right, size: 28),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const DriverSchedulePage()),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text("Report Issue", style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 14,
                        runSpacing: 10,
                        children: [
                          _IssueChip2(
                            label: 'Delay',
                            icon: Icons.schedule,
                            origin: origin,
                            destination: dest,
                            date: dateRaw,
                            time: timeRaw,
                          ),
                          _IssueChip2(
                            label: 'Accident',
                            icon: Icons.car_crash,
                            origin: origin,
                            destination: dest,
                            date: dateRaw,
                            time: timeRaw,
                          ),
                          _IssueChip2(
                            label: 'Mechanical',
                            icon: Icons.build,
                            origin: origin,
                            destination: dest,
                            date: dateRaw,
                            time: timeRaw,
                          ),
                          _IssueChip2(
                            label: 'Emergency',
                            icon: Icons.warning_amber,
                            origin: origin,
                            destination: dest,
                            date: dateRaw,
                            time: timeRaw,
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueChip2 extends StatelessWidget {
  final String label;
  final IconData icon;
  final String origin, destination, date, time;
  const _IssueChip2({
    required this.label,
    required this.icon,
    required this.origin,
    required this.destination,
    required this.date,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, color: Colors.red),
      label: Text(label),
      onPressed: () async {
        // Ask for note (+ optional delay minutes when label == 'Delay')
        final result = await showDialog<_IssueDialogResult>(
          context: context,
          builder: (_) => _IssueDialog2(type: label),
        );
        if (result == null) return;

        try {
          await DriverService.instance.reportIssueForTrip(
            origin: origin,
            destination: destination,
            date: date,
            time: time,
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
              SnackBar(content: Text('Failed: $e')),
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
  _IssueDialogResult({required this.note, this.delayMinutes});
}

class _IssueDialog2 extends StatefulWidget {
  final String type;
  const _IssueDialog2({required this.type});
  @override
  State<_IssueDialog2> createState() => _IssueDialog2State();
}

class _IssueDialog2State extends State<_IssueDialog2> {
  final _note = TextEditingController();
  final _delay = TextEditingController(); // only used for "Delay"
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final isDelay = widget.type.toLowerCase() == 'delay';
    return AlertDialog(
      title: Text('Report ${widget.type}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDelay)
            TextField(
              controller: _delay,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Delay minutes (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Add a note (optional)',
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
            final mins = int.tryParse(_delay.text.trim());
            Navigator.pop(context, _IssueDialogResult(
              note: _note.text.trim(),
              delayMinutes: mins,
            ));
          },
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: _sending
              ? const SizedBox(height: 16, width: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
