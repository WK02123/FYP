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

            Align(
              alignment: Alignment.centerLeft,
              child: Text("Report Issue",
                  style: Theme.of(context).textTheme.titleMedium),
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

            // ✅ Next trip card with client-side filter
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: ListTile(
                      title: Text('$dateStr • $timeStr'),
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
        final note = await showDialog<String>(
          context: context,
          builder: (_) => _IssueDialog(type: label),
        );
        if (note == null) return;
        await DriverService.instance.reportIssue(type: label, note: note);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label reported')),
        );
      },
      shape: StadiumBorder(side: BorderSide(color: Colors.red.shade100)),
    );
  }
}

class _IssueDialog extends StatefulWidget {
  final String type;
  const _IssueDialog({required this.type});

  @override
  State<_IssueDialog> createState() => _IssueDialogState();
}

class _IssueDialogState extends State<_IssueDialog> {
  final _c = TextEditingController();
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Report ${widget.type}'),
      content: TextField(
        controller: _c,
        maxLines: 4,
        decoration: const InputDecoration(
          hintText: 'Add a note (optional)',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _sending ? null : () async {
            setState(() => _sending = true);
            Navigator.pop(context, _c.text.trim());
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
