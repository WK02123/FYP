import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class CreateDriverPage extends StatefulWidget {
  const CreateDriverPage({super.key});

  @override
  State<CreateDriverPage> createState() => _CreateDriverPageState();
}

class _CreateDriverPageState extends State<CreateDriverPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _busCode = TextEditingController();
  final _password = TextEditingController();

  bool _isCreating = false;
  bool _sendInviteEmail = true;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _busCode.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _createDriver() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isCreating = true);

    FirebaseApp? secondaryApp;
    try {
      // 1) Init a secondary Firebase app (so admin session is preserved)
      // Reuse default app options
      final defaultApp = Firebase.app();
      secondaryApp = await Firebase.initializeApp(
        name: 'admin-helper',
        options: defaultApp.options,
      );

      final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);

      // 2) Create the Auth user on SECONDARY auth
      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: _email.text.trim().toLowerCase(),
        password: _password.text,
      );
      final uid = cred.user!.uid;

      // 3) Firestore: create drivers/{uid}
      await FirebaseFirestore.instance.collection('drivers').doc(uid).set({
        'name': _name.text.trim(),
        'email': _email.text.trim().toLowerCase(),
        'phone': _phone.text.trim(),
        'busCode': _busCode.text.trim(),
        'role': 'driver',
        'disabled': false,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 4) (Optional mirror) users/{uid}
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'name': _name.text.trim(),
        'email': _email.text.trim().toLowerCase(),
        'phone': _phone.text.trim(),
        'role': 'driver',
        'disabled': false,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 5) Send verification mail (from secondary user)
      if (_sendInviteEmail) {
        await cred.user!.sendEmailVerification();
      }

      // 6) Sign out the secondary auth (admin remains logged in on main app)
      await secondaryAuth.signOut();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Driver created: ${_email.text.trim()}')),
      );
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      String msg = e.message ?? 'Auth error';
      if (e.code == 'email-already-in-use') {
        msg = 'This email is already in use.';
      } else if (e.code == 'invalid-email') {
        msg = 'Invalid email format.';
      } else if (e.code == 'weak-password') {
        msg = 'Please use a stronger password.';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      // Clean up the secondary app
      if (secondaryApp != null) {
        await secondaryApp.delete();
      }
      if (mounted) setState(() => _isCreating = false);
    }
  }

  String? _validateEmail(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Email is required';
    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
    if (!ok) return 'Invalid email';
    return null;
  }

  String? _validatePassword(String? v) {
    if (v == null || v.length < 6) return 'Min 6 characters';
    return null;
  }

  String? _validatePhone(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Phone is required';
    // Simple Malaysia-ish phone pattern (you can refine)
    final ok = RegExp(r'^\+?6?0\d{8,10}$').hasMatch(s.replaceAll(' ', ''));
    if (!ok) return 'Enter MAL phone, e.g. +60 12 345 6789';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Driver'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: AbsorbPointer(
          absorbing: _isCreating,
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                _field(
                  label: 'Full Name',
                  controller: _name,
                  validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
                ),
                _field(
                  label: 'Email',
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  validator: _validateEmail,
                ),
                _field(
                  label: 'Phone (+60 …)',
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  validator: _validatePhone,
                ),
                _field(
                  label: 'Bus Code (optional)',
                  controller: _busCode,
                ),
                _field(
                  label: 'Temp Password',
                  controller: _password,
                  isPassword: true,
                  validator: _validatePassword,
                ),
                SwitchListTile(
                  value: _sendInviteEmail,
                  onChanged: (v) => setState(() => _sendInviteEmail = v),
                  title: const Text('Send verification email'),
                  subtitle: const Text('Driver must verify before first login'),
                ),
                const SizedBox(height: 12),
                _isCreating
                    ? const CircularProgressIndicator()
                    : ElevatedButton.icon(
                  onPressed: _createDriver,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Create Driver'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    bool isPassword = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        validator: validator,
        keyboardType: keyboardType,
        obscureText: isPassword,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFFF5F5F5),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
