import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shuttle_bus_app/pages/location_search_page.dart';
import 'package:shuttle_bus_app/pages/time_picker_page.dart';
import 'package:shuttle_bus_app/pages/date_picker_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? selectedOrigin;
  String? selectedDestination;
  String? selectedDate;
  String? selectedTime;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // 🔴 Top Header with Logout Button
          Container(
            width: double.infinity,
            height: 220,
            decoration: const BoxDecoration(
              color: Color(0xFFD32F2F),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(50),
                bottomRight: Radius.circular(50),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 50),
                    const Icon(Icons.directions_bus, color: Colors.white, size: 50),
                    IconButton(
                      icon: const Icon(Icons.logout, color: Colors.white),
                      onPressed: () async {
                        await FirebaseAuth.instance.signOut();
                        if (!mounted) return;
                        Navigator.of(context).pushReplacementNamed('/login');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Ridemate',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 🔘 Form Section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 10,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _buildTextField(context, "Origin", Icons.location_on, selectedOrigin, () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LocationSearchPage(title: 'Search Origin'),
                      ),
                    );
                    if (result != null) {
                      setState(() => selectedOrigin = result);
                    }
                  }),
                  const SizedBox(height: 10),

                  _buildTextField(context, "Destination", Icons.flag, selectedDestination, () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LocationSearchPage(title: 'Search Destination'),
                      ),
                    );
                    if (result != null) {
                      setState(() => selectedDestination = result);
                    }
                  }),
                  const SizedBox(height: 10),

                  _buildTextField(context, "Date", Icons.calendar_month, selectedDate, () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DatePickerPage()),
                    );
                    if (result != null) {
                      setState(() => selectedDate = result);
                    }
                  }),
                  const SizedBox(height: 10),

                  _buildTextField(context, "Time", Icons.access_time, selectedTime, () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TimePickerPage()),
                    );
                    if (result != null) {
                      setState(() => selectedTime = result);
                    }
                  }),
                  const SizedBox(height: 20),

                  ElevatedButton(
                    onPressed: () {
                      print("Searching from $selectedOrigin to $selectedDestination on $selectedDate at $selectedTime");
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      minimumSize: const Size.fromHeight(50),
                    ),
                    child: const Text("Search Bus", style: TextStyle(fontSize: 16)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
      BuildContext context,
      String hint,
      IconData icon,
      String? value,
      VoidCallback onTap,
      ) {
    return GestureDetector(
      onTap: onTap,
      child: TextField(
        enabled: false,
        decoration: InputDecoration(
          hintText: value ?? hint,
          prefixIcon: Icon(icon, color: Colors.grey),
          filled: true,
          fillColor: const Color(0xFFF5F5F5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
