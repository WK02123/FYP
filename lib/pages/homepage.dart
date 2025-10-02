import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // ✅ for route check
import 'package:shuttle_bus_app/pages/date_picker_page.dart';
import 'package:shuttle_bus_app/pages/location_search_page.dart';
import 'package:shuttle_bus_app/pages/schedule_page.dart';
import 'package:shuttle_bus_app/pages/profile_page.dart';
import 'package:shuttle_bus_app/pages/gps_map_page.dart';
import 'login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? selectedOrigin;
  String? selectedDestination;
  String? selectedDate;

  int _selectedIndex = 0;

  Future<void> _goScheduleIfRouteExists() async {
    final origin = selectedOrigin;
    final dest = selectedDestination;
    final date = selectedDate;

    if (origin == null || dest == null || date == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select origin, destination, and date')),
      );
      return;
    }

    final routeKey = '${origin.trim()}|${dest.trim()}';
    final doc = await FirebaseFirestore.instance.collection('routes').doc(routeKey).get();

    if (!doc.exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No route found for "$routeKey". Please pick another.')),
      );
      return;
    }

    // Route exists — proceed
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SchedulePage(
          origin: origin,
          destination: dest,
          date: date,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!mounted) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
            },
          ),
        ],
      ),
      body: _selectedIndex == 0
          ? _buildMainContent()
          : _selectedIndex == 1
          ? const GpsMapPage() // middle tab = GPS
          : _buildProfilePage(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.red,
        unselectedItemColor: Colors.grey,
        iconSize: 30,
        onTap: (index) {
          setState(() => _selectedIndex = index);
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: ''),
          BottomNavigationBarItem(icon: Icon(Icons.my_location), label: ''), // GPS
          BottomNavigationBarItem(icon: Icon(Icons.person), label: ''),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          height: 180,
          decoration: const BoxDecoration(
            color: Color(0xFFD32F2F),
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(50),
              bottomRight: Radius.circular(50),
            ),
          ),
          child: const Column(
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
            ],
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(30),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 10,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              children: [
                // Origin picker
                _buildTextField(
                  context,
                  "Origin",
                  Icons.location_on,
                  selectedOrigin,
                      () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LocationSearchPage(
                          title: 'Search Origin',
                        ),
                      ),
                    );
                    if (result != null) {
                      // If origin changes, clear destination (to avoid mismatch)
                      setState(() {
                        selectedOrigin = result as String;
                        selectedDestination = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 10),

                // Destination picker (filters by selected origin)
                _buildTextField(
                  context,
                  "Destination",
                  Icons.flag,
                  selectedDestination,
                      () async {
                    if (selectedOrigin == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please select origin first')),
                      );
                      return;
                    }
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LocationSearchPage(
                          title: 'Search Destination',
                          originFilter: selectedOrigin, // ✅ filter destinations by origin
                        ),
                      ),
                    );
                    if (result != null) {
                      setState(() => selectedDestination = result as String);
                    }
                  },
                ),
                const SizedBox(height: 10),

                // Date picker
                _buildTextField(
                  context,
                  "Date",
                  Icons.calendar_month,
                  selectedDate,
                      () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DatePickerPage()),
                    );
                    if (result != null) setState(() => selectedDate = result as String);
                  },
                ),

                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _goScheduleIfRouteExists, // ✅ verify route exists
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

  Widget _buildProfilePage() => const ProfilePage();
}
