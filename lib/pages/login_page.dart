import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'homepage.dart';
import 'register_page.dart';
import 'reset_password_page.dart';
import 'admin_page.dart';

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

  void _login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Email and password must not be empty")),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      final user = userCredential.user;

      // Check if user is disabled in Firestore
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user?.uid)
          .get();

      if (userDoc.exists && userDoc.data()?['disabled'] == true) {
        await FirebaseAuth.instance.signOut();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Your account has been disabled by the admin."),
          ),
        );
        setState(() => isLoading = false);
        return;
      }

      // ✅ Admin bypasses email verification
      if (user != null && user.email != 'admin@gmail.com' && !user.emailVerified) {
        await FirebaseAuth.instance.signOut();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Please verify your email before logging in."),
          ),
        );
        setState(() => isLoading = false);
        return;
      }

      if (user?.email == 'admin@gmail.com') {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const AdminPage()),
              (Route<dynamic> route) => false,
        );
      } else {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const HomePage()),
              (Route<dynamic> route) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      String errorMessage;
      switch (e.code) {
        case 'user-not-found':
          errorMessage = "No user found with this email.";
          break;
        case 'wrong-password':
          errorMessage = "Incorrect password.";
          break;
        case 'invalid-email':
          errorMessage = "Invalid email format.";
          break;
        default:
          errorMessage = "Login failed: ${e.message}";
      }

      print("❌ FirebaseAuthException: ${e.code} - ${e.message}");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(errorMessage)),
      );
    } catch (e) {
      print("❌ Unexpected error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("An unexpected error occurred.")),
      );
    } finally {
      setState(() => isLoading = false);
    }
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
