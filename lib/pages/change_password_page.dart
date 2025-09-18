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
  final _confirmPasswordController = TextEditingController();

  final _formKey = GlobalKey<FormState>();
  bool _hideCurrent = true;
  bool _hideNew = true;
  bool _hideConfirm = true;
  bool _isLoading = false;

  // ---------- Validators ----------
  String? _validateCurrent(String? v) {
    if ((v ?? '').isEmpty) return 'Please enter your current password';
    return null;
  }

  String? _validateNew(String? v) {
    final val = v ?? '';
    if (val.isEmpty) return 'Please enter a new password';
    if (val.length < 8) return 'Must be at least 8 characters';
    if (!RegExp(r'[A-Z]').hasMatch(val)) return 'Include at least one uppercase letter';
    if (!RegExp(r'[a-z]').hasMatch(val)) return 'Include at least one lowercase letter';
    if (!RegExp(r'\d').hasMatch(val)) return 'Include at least one number';
    // triple-quoted raw string so ' and " are allowed inside the class
    if (!RegExp(r'''[!@#\$%^&*(),.?":{}|<>_\-\[\]\\;'/+=~`]''').hasMatch(val)) {
      return 'Include at least one symbol';
    }
    // prevent reusing current password
    if (val == _currentPasswordController.text) {
      return 'New password must be different from current password';
    }
    return null;
  }

  String? _validateConfirm(String? v) {
    if ((v ?? '').isEmpty) return 'Please confirm your new password';
    if (v != _newPasswordController.text) return 'Passwords do not match';
    return null;
  }

  Future<void> _changePassword() async {
    if (!_formKey.currentState!.validate()) {
      _showSnack('Please fix the errors above');
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('You are not signed in');
      return;
    }

    final currentPassword = _currentPasswordController.text.trim();
    final newPassword = _newPasswordController.text.trim();

    try {
      setState(() => _isLoading = true);

      final email = user.email;
      if (email == null) {
        _showSnack('User email not found. Please re-login.');
        return;
      }

      // Reauthenticate
      final credential =
      EmailAuthProvider.credential(email: email, password: currentPassword);
      await user.reauthenticateWithCredential(credential);

      // Update password in Firebase Auth
      await user.updatePassword(newPassword);

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => const _SuccessDialog(),
      );

      // Close dialog then go back
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      Navigator.of(context).pop(); // close dialog
      Navigator.of(context).pop(); // back
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (e.code == 'wrong-password') {
        _showSnack('Incorrect current password.');
      } else if (e.code == 'requires-recent-login') {
        _showSnack('Please log in again and try updating your password.');
      } else if (e.code == 'weak-password') {
        _showSnack('New password is too weak.');
      } else {
        _showSnack('Firebase Error: ${e.message}');
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack('Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
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
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              _passwordField(
                label: 'Current Password',
                controller: _currentPasswordController,
                obscure: _hideCurrent,
                toggle: () => setState(() => _hideCurrent = !_hideCurrent),
                validator: _validateCurrent,
              ),
              const SizedBox(height: 16),
              _passwordField(
                label: 'New Password',
                controller: _newPasswordController,
                obscure: _hideNew,
                toggle: () => setState(() => _hideNew = !_hideNew),
                validator: _validateNew,
                helperText:
                'Min 8 chars, include upper, lower, number & symbol',
              ),
              const SizedBox(height: 16),
              _passwordField(
                label: 'Confirm New Password',
                controller: _confirmPasswordController,
                obscure: _hideConfirm,
                toggle: () => setState(() => _hideConfirm = !_hideConfirm),
                validator: _validateConfirm,
              ),
              const SizedBox(height: 24),
              _isLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                onPressed: _changePassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 40),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15)),
                ),
                child: const Text("Update Password"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _passwordField({
    required String label,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback toggle,
    required String? Function(String?) validator,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: const Color(0xFFF4F4F4),
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: toggle,
        ),
      ),
    );
  }
}

// Simple success dialog widget
class _SuccessDialog extends StatelessWidget {
  const _SuccessDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.check_circle, color: Colors.green, size: 60),
          SizedBox(height: 10),
          Text("Password Updated", style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
