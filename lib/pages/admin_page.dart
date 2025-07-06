import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'login_page.dart';
import 'manage_bookings_page.dart';
import 'manage_users_page.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  void _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Admin Dashboard"),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () => _logout(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 20,
          crossAxisSpacing: 20,
          children: [
            _buildTile(
              context,
              title: "Shuttle Bookings",
              icon: Icons.directions_bus,
              color: Colors.blue,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManageBookingsPage()),
                );
              },
            ),
            _buildTile(
              context,
              title: "Manage Users",
              icon: Icons.group,
              color: Colors.green,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManageUsersPage()),
                );
              },
            ),
            _buildTile(
              context,
              title: "Usage Stats",
              icon: Icons.bar_chart,
              color: Colors.orange,
              onTap: () {
                // Navigate to statistics page
              },
            ),
            _buildTile(
              context,
              title: "Edit Schedules",
              icon: Icons.schedule,
              color: Colors.purple,
              onTap: () {
                // Navigate to schedule management
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(
      BuildContext context, {
        required String title,
        required IconData icon,
        required Color color,
        required VoidCallback onTap,
      }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
