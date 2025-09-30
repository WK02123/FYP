import 'package:flutter/material.dart';
import 'driver_dashboard.dart';
import 'driver_schedule_page.dart';
import 'driver_profile_page.dart';

class DriverHomePage extends StatefulWidget {
  const DriverHomePage({super.key});

  @override
  State<DriverHomePage> createState() => _DriverHomePageState();
}

class _DriverHomePageState extends State<DriverHomePage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const DriverDashboard(),
      const DriverSchedulePage(),
      const DriverProfilePage(),
    ];

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        selectedItemColor: Colors.red,
        unselectedItemColor: Colors.grey,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: ''),
          BottomNavigationBarItem(icon: Icon(Icons.schedule), label: ''),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: ''),
        ],
      ),
    );
  }
}
