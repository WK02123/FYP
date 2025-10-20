import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'driver_service.dart';
import 'edit_driver_page.dart';
import 'leave_request_page.dart';
import 'login_page.dart'; // 👈 make sure this points to your actual login screen

class DriverProfilePage extends StatelessWidget {
  const DriverProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = DriverService.instance;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        title: const Text("Ridemate Account"),
        centerTitle: true,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ✅ Driver info card
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: svc.driverStream(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Card(
                    child: ListTile(
                      title: Text('Loading...'),
                      subtitle: Text('Please wait'),
                    ),
                  );
                }
                final data = snap.data?.data() ?? <String, dynamic>{};
                return Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.person, color: Colors.red),
                    title: Text(data['name']?.toString() ?? 'Driver'),
                    subtitle: Text(data['phone']?.toString() ?? '-'),
                    trailing: const Icon(Icons.arrow_forward_ios),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EditDriverPage(
                            name: data['name']?.toString() ?? '',
                            phone: data['phone']?.toString() ?? '',
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 8),

            // ✅ Leave request card
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                leading: const Icon(Icons.request_page, color: Colors.red),
                title: const Text("Request Leave / MC"),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LeaveRequestPage(),
                    ),
                  );
                },
              ),
            ),

            const Spacer(),

            // ✅ Sign-out button
            ElevatedButton(
              onPressed: () async {
                await FirebaseAuth.instance.signOut();

                if (!context.mounted) return;

                // Optional: Show sign-out success
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Signed out successfully."),
                    duration: Duration(seconds: 1),
                  ),
                );

                // Go back to login page and clear navigation history
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                      (route) => false,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                "Sign Out",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
