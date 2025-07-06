import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ManageUsersPage extends StatelessWidget {
  const ManageUsersPage({Key? key}) : super(key: key);

  Future<void> _disableUser(BuildContext context, String uid) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'disabled': true});

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("User has been disabled.")),
      );
    } catch (e) {
      print("❌ Error disabling user: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to disable user.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Users"),
        backgroundColor: Colors.green,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .where('disabled', isNotEqualTo: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No users found."));
          }

          final users = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: users.length,
            itemBuilder: (context, index) {
              final doc = users[index];
              final data = doc.data() as Map<String, dynamic>;
              final email = data['email'] ?? 'No email';
              final name = data['name'] ?? 'Unnamed';

              return Card(
                elevation: 3,
                margin: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(email),
                  trailing: IconButton(
                    icon: const Icon(Icons.block, color: Colors.red),
                    onPressed: () => _disableUser(context, doc.id),
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
