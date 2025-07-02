import 'package:flutter/material.dart';

class TermsPage extends StatelessWidget {
  const TermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          _buildHeader(context, "Terms & Conditions"),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: SingleChildScrollView(
                child: Text(
                  '''
Welcome to RideMate. By using our app, you agree to follow these terms:

1. **Usage**: The app is intended for shuttle tracking and seat booking only.
2. **Account**: You are responsible for your login credentials. Do not share them with others.
3. **Booking Rules**: Bookings must be made honestly. Abusing the system may result in account suspension.
4. **Changes**: We may update our terms occasionally. Continued use means you accept those changes.
5. **Support**: For issues, please contact our support team through the app.

Thank you for using RideMate!
                  ''',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, String title) {
    return Container(
      width: double.infinity,
      height: 200,
      decoration: const BoxDecoration(
        color: Color(0xFFD32F2F),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(50),
          bottomRight: Radius.circular(50),
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 40,
            left: 10,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.directions_bus, color: Colors.white, size: 50),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
