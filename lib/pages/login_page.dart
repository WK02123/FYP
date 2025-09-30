import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'homepage.dart';
import 'register_page.dart';
import 'reset_password_page.dart';
import 'admin_page.dart';
import 'driver_home_page.dart'; // 👈 driver dashboard entry

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool isChecked = false;
  bool isLoading = false;

  Future<void> _login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _toast("Email and password must not be empty");
      return;
    }

    setState(() => isLoading = true);

    try {
      final cred = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);

      final user = cred.user;
      if (user == null) {
        _toast("Login failed.");
        setState(() => isLoading = false);
        return;
      }

      // 1) Optional: block disabled accounts (checks users/ and drivers/)
      final usersDoc =
      await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final driversDoc =
      await FirebaseFirestore.instance.collection('drivers').doc(user.uid).get();

      final isDisabled =
          (usersDoc.data()?['disabled'] == true) || (driversDoc.data()?['disabled'] == true);

      if (isDisabled) {
        await FirebaseAuth.instance.signOut();
        _toast("Your account has been disabled by the admin.");
        setState(() => isLoading = false);
        return;
      }

      // 2) Admin bypasses verification
      final isAdmin = user.email?.toLowerCase() == 'admin@gmail.com';
      if (!isAdmin && !user.emailVerified) {
        await FirebaseAuth.instance.signOut();
        _toast("Please verify your email before logging in.");
        setState(() => isLoading = false);
        return;
      }

      // 3) Resolve role (users/{uid}.role or drivers/{uid}.role; fallback student)
      String role = 'student';
      if (usersDoc.exists) {
        role = (usersDoc.data()?['role'] as String?)?.toLowerCase() ?? 'student';
      } else if (driversDoc.exists) {
        role = (driversDoc.data()?['role'] as String?)?.toLowerCase() ?? 'driver';
      }

      // 4) Navigate by role (admin wins first)
      if (isAdmin) {
        _go(const AdminPage());
      } else if (role == 'driver') {
        _go(const DriverHomePage());
      } else {
        _go(const HomePage());
      }
    } on FirebaseAuthException catch (e) {
      String msg;
      switch (e.code) {
        case 'user-not-found':
          msg = "No user found with this email.";
          break;
        case 'wrong-password':
          msg = "Incorrect password.";
          break;
        case 'invalid-email':
          msg = "Invalid email format.";
          break;
        case 'user-disabled':
          msg = "This account has been disabled.";
          break;
        default:
          msg = "Login failed: ${e.message}";
      }
      _toast(msg);
    } catch (e) {
      _toast("An unexpected error occurred.");
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _go(Widget page) {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => page),
          (route) => false,
    );
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            height: 200,
            decoration: const BoxDecoration(
              color: Color(0xFFD32F2F),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(50),
                bottomRight: Radius.circular(50),
              ),
            ),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
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
                    'Login to your account',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 30),
          _buildTextField("Email", emailController),
          const SizedBox(height: 20),
          _buildTextField("Password", passwordController, isPassword: true),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: isChecked,
                    onChanged: (value) =>
                        setState(() => isChecked = value ?? false),
                  ),
                  const Text("Remember me", style: TextStyle(fontSize: 12)),
                ],
              ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ResetPasswordPage()),
                  );
                },
                child: const Text(
                  "Forgot password?",
                  style: TextStyle(color: Colors.red),
                ),
              )
            ],
          ),
          const SizedBox(height: 20),
          isLoading
              ? const CircularProgressIndicator()
              : ElevatedButton(
            onPressed: _login,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              minimumSize: const Size(150, 45),
            ),
            child: const Text("Login Now"),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const RegisterPage()),
              );
            },
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              minimumSize: const Size(150, 45),
              side: const BorderSide(color: Colors.red),
            ),
            child: const Text(
              "Register",
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(String hint, TextEditingController controller,
      {bool isPassword = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: TextField(
        controller: controller,
        obscureText: isPassword,
        decoration: InputDecoration(
          hintText: hint,
          filled: true,
          fillColor: const Color(0xFFF5F5F5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide.none,
          ),
        ),
        onSubmitted: isPassword ? (_) => _login() : null,
      ),
    );
  }
}
