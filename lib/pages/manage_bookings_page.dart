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
  // ---------- Email ----------
  Future<void> _sendEmail(String email, String seat, String schedule) async {
    const serviceId = 'service_zbyju3k';
    const templateId = 'template_jatlq6k';
    const publicKey = '-5_PV78dsS8EjJAkb';

    final url = Uri.parse('https://api.emailjs.com/api/v1.0/email/send');
    try {
      final response = await http.post(
        url,
        headers: {
          'origin': 'http://localhost',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          "service_id": serviceId,
          "template_id": templateId,
          "user_id": publicKey,
          "template_params": {
            "user_email": email,
            "seat_number": seat,
            "schedule_id": schedule,
          }
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ Email sent successfully to $email');
      } else {
        debugPrint('❌ Failed to send email: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ Error sending email: $e');
    }
  }

  // ---------- Delete single booking ----------
  Future<void> _deleteBooking(
      BuildContext context,
      String docId,
      String userEmail,
      String seat,
      String schedule,
      ) async {
    try {
      await FirebaseFirestore.instance
          .collection('booked_seats')
          .doc(docId)
          .delete();

      await _sendEmail(userEmail, seat, schedule);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Deleted booking for seat $seat.")),
        );
      }
    } catch (e) {
      debugPrint("❌ Error deleting booking: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to delete booking.")),
        );
      }
    }
  }

  // ---------- Helper: Parse date/time ----------
  DateTime? _parseBookingDate(Map<String, dynamic> data) {
    try {
      final date = (data['date'] ?? '').toString(); // "YYYY-MM-DD"
      final time = (data['time'] ?? '').toString(); // "7:00 AM" or "07:00"
      if (date.isEmpty || time.isEmpty) return null;

      // handle both 12h and 24h time
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

  // ---------- Auto delete past bookings ----------
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

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Bookings"),
        backgroundColor: Colors.red,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('booked_seats').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No bookings found."));
          }

          final allBookings = snapshot.data!.docs;
          // fire-and-forget: auto-delete past ones
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
              final userEmail = (data['studentEmail'] ?? data['userEmail'] ?? '-').toString();
              final origin = (data['origin'] ?? '-').toString();
              final destination = (data['destination'] ?? '-').toString();
              final date = (data['date'] ?? '-').toString();
              final time = (data['time'] ?? '-').toString();

              return Card(
                elevation: 3,
                margin: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
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
                    onPressed: () => _deleteBooking(
                      context,
                      doc.id,
                      userEmail,
                      seat,
                      schedule,
                    ),
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
