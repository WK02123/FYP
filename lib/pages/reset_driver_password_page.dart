import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ResetDriverPasswordPage extends StatefulWidget {
  const ResetDriverPasswordPage({super.key});

  @override
  State<ResetDriverPasswordPage> createState() => _ResetDriverPasswordPageState();
}

class _ResetDriverPasswordPageState extends State<ResetDriverPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  String? _validateEmail(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Email is required';
    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
    if (!ok) return 'Invalid email';
    return null;
  }

  Future<void> _sendReset() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _sending = true);
    final email = _email.text.trim().toLowerCase();

    try {
      // Sends reset email (Firebase hides whether the email exists).
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Password reset email sent to $email')),
      );
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Failed to send reset email')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reset Driver Password'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              const SizedBox(height: 8),
              TextFormField(
                controller: _email,
                validator: _validateEmail,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Driver Email',
                  hintText: 'driver@example.com',
                  filled: true,
                  fillColor: const Color(0xFFF5F5F5),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 16),
              _sending
                  ? const CircularProgressIndicator()
                  : ElevatedButton.icon(
                onPressed: _sendReset,
                icon: const Icon(Icons.lock_reset),
                label: const Text('Send Reset Email'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Note: For security, this will show success even if the email is not registered.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
