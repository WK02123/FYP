import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ManageBookingsPage extends StatelessWidget {
  const ManageBookingsPage({Key? key}) : super(key: key);

  String formatTimestamp(Timestamp timestamp) {
    final dateTime = timestamp.toDate();
    return DateFormat('dd MMM yyyy, hh:mm a').format(dateTime);
  }

  Future<void> _sendEmail(String email, String seat, String schedule) async {
    const serviceId = 'service_zbyju3k';
    const templateId = 'template_jatlq6k';
    const publicKey = '-5_PV78dsS8EjJAkb';

    final url = Uri.parse('https://api.emailjs.com/api/v1.0/email/send');
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
          "user_email": "heartx8880@gmail.com",       // ✅ dynamic value
          "seat_number": seat,
          "schedule_id": schedule
        }
      }),
    );

    if (response.statusCode == 200) {
      print('✅ Email sent successfully to $email');
    } else {
      print('❌ Failed to send email: ${response.statusCode}');
      print('Body: ${response.body}');
    }
  }

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

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Booking deleted and email sent.")),
      );
    } catch (e) {
      print("❌ Error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to delete or send email.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Bookings"),
        backgroundColor: Colors.red,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('booked_seats')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No bookings found."));
          }

          final bookings = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: bookings.length,
            itemBuilder: (context, index) {
              final doc = bookings[index];
              final data = doc.data() as Map<String, dynamic>;

              final schedule = data['scheduleId'] ?? '-';
              final seat = data['seatNumber'] ?? '-';
              final user = data['userId'] ?? '-';
              final timestampRaw = data['timestamp'];
              final timestamp = timestampRaw is Timestamp
                  ? formatTimestamp(timestampRaw)
                  : '-';

              return Card(
                elevation: 3,
                margin: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text("🚌 $schedule - Seat $seat",
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Text("👤 User: $user"),
                      Text("📅 Date: $timestamp"),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _deleteBooking(
                      context,
                      doc.id,
                      user,
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
