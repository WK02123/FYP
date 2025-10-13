import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'driver_service.dart';
import 'edit_driver_page.dart';
import 'leave_request_page.dart';

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
            // ✅ Typed StreamBuilder so snap.data is a DocumentSnapshot<Map<...>>
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: ListTile(
                    leading: const Icon(Icons.person, color: Colors.red),
                    title: Text(data['name']?.toString() ?? 'Driver'),
                    subtitle: Text(data['phone']?.toString() ?? '-'),
                    trailing: const Icon(Icons.arrow_forward_ios),
                    onTap: () {
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => EditDriverPage(
                          name: data['name']?.toString() ?? '',
                          phone: data['phone']?.toString() ?? '',
                        ),
                      ));
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: ListTile(
                leading: const Icon(Icons.request_page, color: Colors.red),
                title: const Text("Request Leave / MC"),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const LeaveRequestPage(),
                  ));
                },
              ),
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text("Sign Out"),
            ),
          ],
        ),
      ),
    );
  }
}
