import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();

  Future<void> _changePassword() async {
    final user = FirebaseAuth.instance.currentUser;
    final currentPassword = _currentPasswordController.text.trim();
    final newPassword = _newPasswordController.text.trim();

    if (currentPassword.isEmpty || newPassword.isEmpty) {
      _showSnack("Please fill in all fields");
      return;
    }

    if (newPassword.length < 6) {
      _showSnack("Password must be at least 6 characters");
      return;
    }

    try {
      // Re-authenticate
      final email = user?.email;
      if (email == null) throw Exception("User email not found.");

      final credential = EmailAuthProvider.credential(email: email, password: currentPassword);
      await user!.reauthenticateWithCredential(credential);

      // Change password
      await user.updatePassword(newPassword);

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.check_circle, color: Colors.green, size: 60),
              SizedBox(height: 10),
              Text("Password Updated", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password') {
        _showSnack("Incorrect current password.");
      } else if (e.code == 'requires-recent-login') {
        _showSnack("Please log in again and try updating your password.");
      } else {
        _showSnack("Firebase Error: ${e.message}");
      }
    } catch (e) {
      _showSnack("Error: ${e.toString()}");
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Change Password"),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextFormField(
              controller: _currentPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "Current Password",
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Color(0xFFF4F4F4),
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "New Password",
                border: OutlineInputBorder(),
                filled: true,
                fillColor: Color(0xFFF4F4F4),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _changePassword,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 40),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              child: const Text("Update Password"),
            ),
          ],
        ),
      ),
    );
  }
}
