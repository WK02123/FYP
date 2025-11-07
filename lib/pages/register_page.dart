import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'login_page.dart';
import 'TOC.dart';
import 'PrivacyPolicy.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  // Controllers
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final passwordController = TextEditingController();

  // Form key
  final _formKey = GlobalKey<FormState>();

  bool isLoading = false;
  bool agreed = false;
  bool _hidePassword = true;

  // Validators
  final _emailRegex =
  RegExp(r"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$", caseSensitive: false);
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

  String? _validateEmail(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Please enter your email';
    if (!_emailRegex.hasMatch(v)) return 'Enter a valid email address';
    return null;
  }

  String? _validatePhone(String? value) {
    final v = value?.replaceAll(' ', '') ?? '';
    if (v.isEmpty) return 'Please enter your phone number';
    if (!_msiaPhoneRegex.hasMatch(v)) {
      return 'Use Malaysian mobile format e.g. 0123456789 or +60123456789';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Please enter a password';
    if (v.length < 8) return 'Password must be at least 8 characters';
    if (!RegExp(r'[A-Z]').hasMatch(v)) return 'Include at least one uppercase letter';
    if (!RegExp(r'[a-z]').hasMatch(v)) return 'Include at least one lowercase letter';
    if (!RegExp(r'\d').hasMatch(v)) return 'Include at least one number';
    if (!RegExp(r'''[!@#\$%^&*(),.?":{}|<>_\-\[\]\\;'/+=~`]''').hasMatch(v)) {
      return 'Include at least one symbol';
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

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) {
      _showMessage('Please fix the errors above');
      return;
    }
    if (!agreed) {
      _showMessage("Please agree to the Terms & Conditions and Privacy Policy");
      return;
    }

    final name = nameController.text.trim();
    final email = emailController.text.trim();
    final phone = _normalizeMsiaPhone(phoneController.text.trim());
    final password = passwordController.text;

    try {
      setState(() => isLoading = true);

      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      await cred.user!.sendEmailVerification();

      await FirebaseFirestore.instance
          .collection('users')
          .doc(cred.user!.uid)
          .set({
        'name': name,
        'email': email,
        'phone': phone,
        'createdAt': FieldValue.serverTimestamp(),
        'disabled': false,
      });

      _showMessage("Verification email sent. Please check your inbox.");
      await FirebaseAuth.instance.signOut();

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
      }
    } on FirebaseAuthException catch (e) {
      _showMessage(e.message ?? "Registration failed");
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _showMessage(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required String? Function(String?) validator,
    bool isPassword = false,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? hintText,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
      child: TextFormField(
        controller: controller,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        obscureText: isPassword ? _hidePassword : false,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText,
          filled: true,
          fillColor: const Color(0xFFF5F5F5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide.none,
          ),
          suffixIcon: isPassword
              ? IconButton(
            icon: Icon(_hidePassword ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _hidePassword = !_hidePassword),
          )
              : null,
        ),
        validator: validator,
      ),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark, // iOS
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        // This simple ListView avoids Stack/overlay issues
        body: ListView(
          padding: EdgeInsets.zero,
          children: [
            // ===== Red header that includes the status-bar area =====
            Container(
              padding: EdgeInsets.only(top: topInset + 8, left: 8, right: 8),
              decoration: const BoxDecoration(
                color: Color(0xFFD32F2F),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(50)),
              ),
              child: Column(
                children: const [
                  _HeaderBar(),
                  SizedBox(height: 8),
                  Icon(Icons.directions_bus, color: Colors.white, size: 50),
                  SizedBox(height: 10),
                  Text(
                    'Ridemate',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Sign Up',
                    style: TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                  SizedBox(height: 24),
                ],
              ),
            ),

            // ===== Form =====
            Form(
              key: _formKey,
              child: Column(
                children: [
                  _buildTextField(
                    label: "Name as per IC",
                    controller: nameController,
                    validator: _validateName,
                  ),
                  _buildTextField(
                    label: "Email",
                    controller: emailController,
                    validator: _validateEmail,
                    keyboardType: TextInputType.emailAddress,
                  ),
                  _buildTextField(
                    label: "Phone Number",
                    controller: phoneController,
                    validator: _validatePhone,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9\+]')),
                      LengthLimitingTextInputFormatter(13),
                    ],
                    hintText: "+60123456789 or 0123456789",
                  ),
                  _buildTextField(
                    label: "Password",
                    controller: passwordController,
                    validator: _validatePassword,
                    isPassword: true,
                  ),

                  // Terms & Privacy
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: agreed,
                          onChanged: (value) => setState(() => agreed = value ?? false),
                        ),
                        Expanded(
                          child: Wrap(
                            children: [
                              const Text("I agree to the "),
                              GestureDetector(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const TermsPage()),
                                ),
                                child: const Text("Terms & Conditions",
                                    style: TextStyle(color: Colors.blue)),
                              ),
                              const Text(" and "),
                              GestureDetector(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const PrivacyPage()),
                                ),
                                child: const Text("Privacy Policy",
                                    style: TextStyle(color: Colors.blue)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Register button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                    child: isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : ElevatedButton(
                      onPressed: _register,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child:
                      const Text("Register", style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Separate widget for the back button row so it stays simple
class _HeaderBar extends StatelessWidget {
  const _HeaderBar();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () {
          if (!Navigator.of(context).canPop()) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const LoginPage()),
            );
          } else {
            Navigator.of(context).maybePop();
          }
        },
      ),
    );
  }
}
