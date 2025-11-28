import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ManageBookingsPage extends StatefulWidget {
  const ManageBookingsPage({Key? key}) : super(key: key);

  @override
  State<ManageBookingsPage> createState() => _ManageBookingsPageState();
}

class _ManageBookingsPageState extends State<ManageBookingsPage> {
  // ---------- Email with SendGrid (HTML + reason) ----------
  Future<bool> _sendEmail(
      String email,
      String seat,
      String schedule, {
        String? origin,
        String? destination,
        String? date,
        String? time,
        String? reason,
      }) async {
    // IMPORTANT:
    // 1. Put your real SendGrid API key here (for local testing only)
    // 2. Do NOT commit the real key to GitHub
    const sendgridApiKey = 'YOUR_SENDGRID_API_KEY_HERE';

    if (sendgridApiKey == 'YOUR_SENDGRID_API_KEY_HERE') {
      debugPrint('❗ SendGrid API key not set. Email will not be sent.');
      return false;
    }

    final url = Uri.parse('https://api.sendgrid.com/v3/mail/send');

    // Your CSS styles
    const styles = '''
body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; background-color: #f5f5f5; }
.email-container { max-width: 600px; margin: 0 auto; background-color: #ffffff; }
.header { background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); padding: 40px 20px; text-align: center; }
.logo { font-size: 32px; font-weight: bold; color: #ffffff; margin: 0; }
.content { padding: 40px 30px; }
.title { font-size: 28px; font-weight: bold; color: #1f2937; margin: 0 0 10px 0; }
.subtitle { font-size: 16px; color: #6b7280; margin: 0 0 30px 0; }
.card { background-color: #f9fafb; border-radius: 12px; padding: 24px; margin-bottom: 24px; border: 1px solid #e5e7eb; }
.route { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; padding: 16px; background-color: #ffffff; border-radius: 8px; }
.location { font-size: 18px; font-weight: 600; color: #1f2937; }
.arrow { font-size: 24px; color: #ef4444; margin: 0 10px; }
.info-row { display: flex; justify-content: space-between; padding: 12px 0; border-bottom: 1px solid #e5e7eb; }
.info-row:last-child { border-bottom: none; }
.info-label { font-size: 14px; color: #6b7280; font-weight: 500; }
.info-value { font-size: 14px; color: #1f2937; font-weight: 600; }
.footer { padding: 0 30px 30px 30px; font-size: 12px; color: #9ca3af; text-align: center; }
.button { display: inline-block; margin-top: 18px; padding: 10px 18px; border-radius: 999px; background-color: #ef4444; color: #ffffff; font-size: 14px; font-weight: 600; text-decoration: none; }
''';

    final safeOrigin = origin ?? 'Not specified';
    final safeDestination = destination ?? 'Not specified';
    final safeDate = date ?? 'Not specified';
    final safeTime = time ?? 'Not specified';

    final reasonHtml = (reason != null && reason.trim().isNotEmpty)
        ? '''
      <div class="card">
        <div class="info-label" style="margin-bottom: 8px;">Reason for cancellation</div>
        <div class="info-value">
          ${reason.trim().replaceAll('\n', '<br />')}
        </div>
      </div>
    '''
        : '';

    final html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>RideMate Booking Cancelled</title>
  <style>
  $styles
  </style>
</head>
<body>
  <div class="email-container">
    <div class="header">
      <h1 class="logo">RideMate Shuttle</h1>
    </div>

    <div class="content">
      <h2 class="title">Your booking has been cancelled</h2>
      <p class="subtitle">
        Your shuttle seat reservation has been cancelled by the administrator. Please review the details below.
      </p>

      <div class="card">
        <div class="route">
          <span class="location">$safeOrigin</span>
          <span class="arrow">→</span>
          <span class="location">$safeDestination</span>
        </div>

        <div class="info-row">
          <span class="info-label">Seat</span>
          <span class="info-value">$seat</span>
        </div>
        <div class="info-row">
          <span class="info-label">Schedule ID</span>
          <span class="info-value">$schedule</span>
        </div>
        <div class="info-row">
          <span class="info-label">Date</span>
          <span class="info-value">$safeDate</span>
        </div>
        <div class="info-row">
          <span class="info-label">Time</span>
          <span class="info-value">$safeTime</span>
        </div>
      </div>

      $reasonHtml

      <p class="subtitle" style="margin-top: 24px;">
        If you believe this cancellation was made in error, please contact RideMate support or try booking another available slot in the app.
      </p>

      <a class="button" href="#">Open RideMate App</a>
    </div>

    <div class="footer">
      You are receiving this email because you have an active RideMate Shuttle account.
      <br />Please do not reply directly to this automated email.
    </div>
  </div>
</body>
</html>
''';

    debugPrint('📧 Sending email to $email ...');

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $sendgridApiKey',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          "personalizations": [
            {
              "to": [
                {"email": email}
              ],
              "subject": "Your RideMate shuttle booking has been cancelled"
            }
          ],
          "from": {
            // MUST be a verified sender in your SendGrid account
            "email": "heartx8880@gmail.com",
            "name": "RideMate Shuttle"
          },
          "content": [
            {
              "type": "text/html",
              "value": html,
            }
          ]
        }),
      );

      debugPrint('📨 SendGrid response: '
          '${response.statusCode} - ${response.body}');

      if (response.statusCode == 202) {
        debugPrint('✅ SendGrid email accepted for delivery to $email');
        return true;
      } else {
        debugPrint(
            '❌ SendGrid failed with status ${response.statusCode}: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error sending SendGrid email: $e');
      return false;
    }
  }

  // ---------- Delete single booking (with reason) ----------
  Future<void> _deleteBooking(
      String docId,
      String userEmail,
      String seat,
      String schedule, {
        String? origin,
        String? destination,
        String? date,
        String? time,
        String? reason,
      }) async {
    debugPrint('🗑️ Deleting booking docId=$docId, email=$userEmail');

    try {
      await FirebaseFirestore.instance
          .collection('booked_seats')
          .doc(docId)
          .delete();

      bool emailSent = false;

      if (userEmail.isNotEmpty && userEmail != '-') {
        emailSent = await _sendEmail(
          userEmail,
          seat,
          schedule,
          origin: origin,
          destination: destination,
          date: date,
          time: time,
          reason: reason,
        );
      } else {
        debugPrint('⚠️ No valid email found for this booking.');
      }

      if (!mounted) return;

      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text(
            emailSent
                ? "Deleted booking for seat $seat and email sent."
                : "Deleted booking for seat $seat. (Email not sent)",
          ),
        ),
      );
    } catch (e) {
      debugPrint("❌ Error deleting booking: $e");

      if (!mounted) return;

      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text("Failed to delete booking.")),
      );
    }
  }

  // ---------- Helper: Parse date/time ----------
  DateTime? _parseBookingDate(Map<String, dynamic> data) {
    try {
      final date = (data['date'] ?? '').toString(); // "YYYY-MM-DD"
      final time = (data['time'] ?? '').toString(); // "7:00 AM" or "07:00"
      if (date.isEmpty || time.isEmpty) return null;

      DateTime dt;
      if (time.contains('AM') || time.contains('PM')) {
        final inputFormat = DateFormat("yyyy-MM-dd h:mm a");
        dt = inputFormat.parse("$date $time");
      } else {
        final inputFormat = DateFormat("yyyy-MM-dd HH:mm");
        dt = inputFormat.parse("$date $time");
      }
      return dt;
    } catch (_) {
      return null;
    }
  }

  // ---------- Auto delete past bookings (no email) ----------
  Future<void> _autoDeletePastBookings(List<QueryDocumentSnapshot> docs) async {
    final now = DateTime.now();
    final batch = FirebaseFirestore.instance.batch();
    int deleteCount = 0;

    for (final d in docs) {
      final data = d.data() as Map<String, dynamic>;
      final dt = _parseBookingDate(data);
      if (dt != null && dt.isBefore(now)) {
        batch.delete(d.reference);
        deleteCount++;
      }
    }

    if (deleteCount > 0) {
      try {
        await batch.commit();
        debugPrint("🗑️ Auto-deleted $deleteCount past bookings.");
      } catch (e) {
        debugPrint("❌ Auto-delete error: $e");
      }
    }
  }

  // ---------- Optional: quick button to test email only ----------
  Future<void> _testSendGrid() async {
    const testEmail = 'heartx8880@gmail.com'; // change if needed

    final ok = await _sendEmail(
      testEmail,
      'TEST_SEAT',
      'TEST_SCHEDULE',
      origin: 'INTI',
      destination: 'Relau',
      date: '2025-11-17',
      time: '07:00 AM',
      reason: 'This is a test cancellation reason for debugging.',
    );

    if (!mounted) return;

    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Test email sent (check $testEmail).'
              : 'Test email failed. Check console logs.',
        ),
      ),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Bookings"),
        backgroundColor: Colors.red,
        actions: [
          IconButton(
            icon: const Icon(Icons.email),
            tooltip: 'Test SendGrid email',
            onPressed: _testSendGrid,
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream:
        FirebaseFirestore.instance.collection('booked_seats').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No bookings found."));
          }

          final allBookings = snapshot.data!.docs;

          // fire-and-forget: auto-delete past ones (no email)
          _autoDeletePastBookings(allBookings);

          // keep only now/future
          final now = DateTime.now();
          final upcoming = allBookings.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final dt = _parseBookingDate(data);
            return dt == null || !dt.isBefore(now);
          }).toList();

          if (upcoming.isEmpty) {
            return const Center(
              child: Text("No active or upcoming bookings."),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: upcoming.length,
            itemBuilder: (context, index) {
              final doc = upcoming[index];
              final data = doc.data() as Map<String, dynamic>;

              final schedule = (data['scheduleId'] ?? '-').toString();
              final seat = (data['seatNumber'] ?? '-').toString();
              final userEmail =
              (data['studentEmail'] ?? data['userEmail'] ?? '-')
                  .toString();
              final origin = (data['origin'] ?? '-').toString();
              final destination = (data['destination'] ?? '-').toString();
              final date = (data['date'] ?? '-').toString();
              final time = (data['time'] ?? '-').toString();

              return Card(
                elevation: 3,
                margin: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(
                    "🚌 $origin → $destination",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text("Seat: $seat"),
                      Text("Date: $date  •  $time"),
                      Text("Email: $userEmail"),
                      Text("Schedule: $schedule"),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () async {
                      final reasonController = TextEditingController();

                      final reason = await showDialog<String>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Cancel booking'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Please enter the reason for cancelling seat $seat for $userEmail. '
                                    'This reason will be included in the email sent to the student.',
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: reasonController,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                  labelText: 'Reason',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, null),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(
                                ctx,
                                reasonController.text.trim(),
                              ),
                              child: const Text('Confirm'),
                            ),
                          ],
                        ),
                      );

                      if (reason == null) {
                        // user pressed Cancel
                        return;
                      }

                      if (reason.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Please enter a reason before cancelling.'),
                          ),
                        );
                        return;
                      }

                      await _deleteBooking(
                        doc.id,
                        userEmail,
                        seat,
                        schedule,
                        origin: origin,
                        destination: destination,
                        date: date,
                        time: time,
                        reason: reason,
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
