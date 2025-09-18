import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final _auth = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;

  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();

  final _formKey = GlobalKey<FormState>();

  bool isLoading = true;

  // ---------- Validators ----------
  final _msiaPhoneRegex = RegExp(r'^(?:\+?60|0)1\d{8,9}$');

  String? _validateName(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Please enter your full name';
    if (v.length < 3) return 'Name must be at least 3 characters';
    if (!RegExp(r"^[A-Za-zÀ-ÿ' .-]+$").hasMatch(v)) {
      return 'Name contains invalid characters';
    }
    return null;
  }

  String? _validatePhone(String? value) {
    final v = (value ?? '').replaceAll(' ', '');
    if (v.isEmpty) return 'Please enter your phone number';
    if (!_msiaPhoneRegex.hasMatch(v)) {
      return 'Use Malaysian mobile format e.g. 0123456789 or +60123456789';
    }
    return null;
  }

  String _normalizeMsiaPhone(String raw) {
    var v = raw.replaceAll(' ', '');
    if (v.startsWith('+60')) return v;
    if (v.startsWith('0')) return '+60${v.substring(1)}';
    if (v.startsWith('60')) return '+$v';
    return v;
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = _auth.currentUser;
    if (user != null) {
      _emailController.text = user.email ?? '';
      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists) {
        final data = doc.data()!;
        _nameController.text = (data['name'] ?? '').toString();
        // read new key 'phone', fallback to old 'contact'
        final phone = (data['phone'] ?? data['contact'] ?? '').toString();
        _phoneController.text = phone;
      }
    }
    if (mounted) setState(() => isLoading = false);
  }

  Future<void> _updateProfile() async {
    if (!_formKey.currentState!.validate()) {
      _showSnack('Please fix the errors above');
      return;
    }

    final user = _auth.currentUser;
    if (user == null) {
      _showSnack('Not signed in');
      return;
    }

    final name = _nameController.text.trim();
    final normalizedPhone = _normalizeMsiaPhone(_phoneController.text.trim());

    await _firestore.collection('users').doc(user.uid).update({
      'name': name,
      'phone': normalizedPhone,
      'contact': normalizedPhone, // keep for backward compatibility
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.check_circle, color: Colors.green, size: 60),
            SizedBox(height: 10),
            Text("Profile Updated",
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          )
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Edit Profile"),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              _buildField(
                "Email",
                controller: _emailController,
                readOnly: true,
                keyboardType: TextInputType.emailAddress,
              ),
              _buildField(
                "Full Name",
                controller: _nameController,
                validator: _validateName,
              ),
              _buildField(
                "Contact / Phone",
                controller: _phoneController,
                validator: _validatePhone,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\+]')),
                  LengthLimitingTextInputFormatter(13), // e.g., +601XXXXXXXXX
                ],
                hintText: "+60123456789 or 0123456789",
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _updateProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding:
                  const EdgeInsets.symmetric(vertical: 14, horizontal: 40),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15)),
                ),
                child: const Text("Update"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
      String label, {
        required TextEditingController controller,
        bool readOnly = false,
        String? Function(String?)? validator,
        TextInputType keyboardType = TextInputType.text,
        List<TextInputFormatter>? inputFormatters,
        String? hintText,
      }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        autovalidateMode:
        validator == null ? AutovalidateMode.disabled : AutovalidateMode.onUserInteraction,
        validator: validator,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          fillColor: const Color(0xFFF4F4F4),
        ),
      ),
    );
  }
}
