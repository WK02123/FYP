// lib/pages/leave_approval_page.dart
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

class LeaveApprovalPage extends StatefulWidget {
  const LeaveApprovalPage({super.key});

  @override
  State<LeaveApprovalPage> createState() => _LeaveApprovalPageState();
}

class _LeaveApprovalPageState extends State<LeaveApprovalPage> {
  final df = DateFormat('yyyy-MM-dd');

  // ---------- Helper: get driver name from drivers collection ----------
  Future<String> _getDriverName(String driverId) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('drivers')
          .doc(driverId)
          .get();

      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return 'Driver';

      final name = (data['name'] ?? data['displayName'] ?? '').toString();
      if (name.trim().isEmpty) return 'Driver';
      return name;
    } catch (_) {
      return 'Driver';
    }
  }

  // ---------- Send email to driver about leave decision ----------
  Future<bool> _sendDriverEmail({
    required String email,
    required String driverName,
    required String status, // approved / rejected
    required DateTime from,
    required DateTime to,
    required String reason,
  }) async {
    const apiKey = 'YOUR_SENDGRID_API_KEY_HERE'; // TODO: replace for testing

    if (apiKey == 'YOUR_SENDGRID_API_KEY_HERE') {
      debugPrint('❗ SendGrid API key not set.');
      return false;
    }

    final url = Uri.parse('https://api.sendgrid.com/v3/mail/send');

    final isApproved = status.toLowerCase() == 'approved';
    final pillBg = isApproved ? '#dcfce7' : '#fee2e2';
    final pillText = isApproved ? '#16a34a' : '#dc2626';
    final statusLabel = isApproved ? 'Approved' : 'Rejected';
    final msg = isApproved
        ? 'Your leave request has been approved.'
        : 'Your leave request has been rejected.';

    final html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8" />
<title>RideMate Leave $statusLabel</title>
<style>
  body { font-family: -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif; background:#f5f5f5; margin:0; padding:0; }
  .container { max-width:600px;margin:20px auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 10px 30px rgba(15,23,42,0.1); }
  .header { background:linear-gradient(135deg,#ef4444,#dc2626);padding:24px;text-align:center;color:#fff;font-size:22px;font-weight:bold; }
  .content { padding:24px 22px; }
  .title { font-size:20px;font-weight:700;margin:0 0 8px 0;color:#111827; }
  .subtitle { font-size:14px;color:#6b7280;margin:0 0 20px 0; }
  .card { background:#f9fafb;border-radius:12px;border:1px solid #e5e7eb;padding:18px;margin-bottom:16px; }
  .row { display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #e5e7eb;font-size:14px; }
  .row:last-child { border-bottom:none; }
  .label { color:#6b7280;font-weight:500; }
  .value { color:#111827;font-weight:600;text-align:right; }
  .pill { display:inline-block;padding:6px 14px;border-radius:999px;background:$pillBg;color:$pillText;font-size:13px;font-weight:600; }
  .footer { padding:0 22px 20px 22px;font-size:12px;color:#9ca3af;text-align:center; }
</style>
</head>
<body>
  <div class="container">
    <div class="header">RideMate Shuttle</div>
    <div class="content">
      <h2 class="title">Leave request $statusLabel</h2>
      <p class="subtitle">Hi $driverName,<br />$msg Please see the details below.</p>

      <div class="card">
        <div class="row">
          <span class="label">Status</span>
          <span class="value"><span class="pill">$statusLabel</span></span>
        </div>
        <div class="row">
          <span class="label">Leave period</span>
          <span class="value">${df.format(from)} → ${df.format(to)}</span>
        </div>
        <div class="row">
          <span class="label">Reason (from you)</span>
          <span class="value" style="max-width:260px;">${reason.replaceAll('\n', '<br />')}</span>
        </div>
      </div>

      <p class="subtitle" style="margin-top:8px;">
        Please check the RideMate app to view your latest trip schedules and assignments.
      </p>
    </div>
    <div class="footer">
      This is an automated email from RideMate Shuttle. Please do not reply directly to this email.
    </div>
  </div>
</body>
</html>
""";

    try {
      final res = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'personalizations': [
            {
              'to': [
                {'email': email}
              ],
              'subject': 'RideMate – Your leave request has been $statusLabel',
            }
          ],
          'from': {
            'email': 'heartx8880@gmail.com', // must be verified sender
            'name': 'RideMate Shuttle',
          },
          'content': [
            {'type': 'text/html', 'value': html},
          ]
        }),
      );

      debugPrint(
          '📨 Leave status email: ${res.statusCode} - ${res.body.substring(0, res.body.length > 200 ? 200 : res.body.length)}');

      return res.statusCode == 202;
    } catch (e) {
      debugPrint('❌ Email error: $e');
      return false;
    }
  }

  // ---------- Update Firestore & email ----------
  Future<void> _updateLeaveStatus({
    required DocumentSnapshot doc,
    required String status,
  }) async {
    try {
      final data = doc.data() as Map<String, dynamic>;

      final driverId = data['driverId']?.toString() ?? '';
      final driverEmail = data['driverEmail']?.toString() ?? '';
      final reason = data['reason']?.toString() ?? 'N/A';
      final from = (data['from'] as Timestamp).toDate();
      final to = (data['to'] as Timestamp).toDate();

      // 1) update status
      await FirebaseFirestore.instance
          .collection('leave_requests')
          .doc(doc.id)
          .update({'status': status});

      // 2) get driver name
      final driverName =
      driverId.isEmpty ? 'Driver' : await _getDriverName(driverId);

      // 3) send email if we have email
      bool emailSent = false;
      if (driverEmail.isNotEmpty) {
        emailSent = await _sendDriverEmail(
          email: driverEmail,
          driverName: driverName,
          status: status,
          from: from,
          to: to,
          reason: reason,
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            emailSent
                ? 'Leave $status and email sent to $driverEmail.'
                : 'Leave $status (email not sent).',
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ Failed to update leave status: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to update leave status.')),
      );
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Leave Requests'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('leave_requests')
            .where('status', isEqualTo: 'pending')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading leaves:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text(
                'No pending leave requests.',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            );
          }

          final docs = snapshot.data!.docs;
          debugPrint('📄 pending leaves: ${docs.length}');

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data() as Map<String, dynamic>;

              final driverId = data['driverId']?.toString() ?? 'N/A';
              final reason = data['reason']?.toString() ?? 'N/A';
              final from = (data['from'] as Timestamp).toDate();
              final to = (data['to'] as Timestamp).toDate();
              final dateRange = '${df.format(from)} → ${df.format(to)}';

              return FutureBuilder<String>(
                future: _getDriverName(driverId),
                builder: (context, snapName) {
                  final driverName =
                      snapName.data ?? 'Driver'; // show name instead of ID

                  return Card(
                    elevation: 4,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.red.withOpacity(0.15),
                          width: 1.2,
                        ),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top row: avatar + name + driverId
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor:
                                Colors.red.withOpacity(0.1),
                                child: Text(
                                  driverName.isNotEmpty
                                      ? driverName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      driverName,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'ID: $driverId',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  children: const [
                                    Icon(Icons.timelapse,
                                        size: 14, color: Colors.orange),
                                    SizedBox(width: 4),
                                    Text(
                                      'Pending',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.orange,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 10),

                          // Date range row
                          Row(
                            children: [
                              const Icon(Icons.date_range,
                                  size: 18, color: Colors.red),
                              const SizedBox(width: 6),
                              Text(
                                dateRange,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 10),

                          // Reason bubble
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Reason',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  reason,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Buttons
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Reject leave'),
                                      content: Text(
                                          'Reject leave request from $driverName?'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Reject'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await _updateLeaveStatus(
                                      doc: doc,
                                      status: 'rejected',
                                    );
                                  }
                                },
                                icon: const Icon(Icons.close,
                                    size: 18, color: Colors.red),
                                label: const Text(
                                  'Reject',
                                  style: TextStyle(color: Colors.red),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.red),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Approve leave'),
                                      content: Text(
                                          'Approve leave request from $driverName?'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Approve'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await _updateLeaveStatus(
                                      doc: doc,
                                      status: 'approved',
                                    );
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                ),
                                icon: const Icon(Icons.check,
                                    size: 18, color: Colors.white),
                                label: const Text('Approve'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
