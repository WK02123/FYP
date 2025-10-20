import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TimePickerPage extends StatelessWidget {
  const TimePickerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final currentTime = now;

    final allTimes = [
      "7:00 AM",
      "9:00 AM",
      "12:00 PM",
      "2:00 PM",
      "5:00 PM",
      "7:00 PM"
    ];

    // 🕒 Filter times that are still upcoming today
    final upcomingTimes = allTimes.where((t) {
      final parsed = DateFormat.jm().parse(t); // parse e.g. "2:00 PM"
      final candidate = DateTime(
        now.year,
        now.month,
        now.day,
        parsed.hour,
        parsed.minute,
      );
      return candidate.isAfter(currentTime);
    }).toList();

    // If it's late night and all past, show all tomorrow’s options
    final timesToShow = upcomingTimes.isNotEmpty ? upcomingTimes : allTimes;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // 🔴 Red Header
          Container(
            width: double.infinity,
            height: 120,
            decoration: const BoxDecoration(
              color: Color(0xFFD32F2F),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 10),
                const Text(
                  "Time",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ⏰ Time List
          Expanded(
            child: ListView.separated(
              itemCount: timesToShow.length,
              separatorBuilder: (_, __) =>
              const Divider(indent: 30, endIndent: 30),
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(timesToShow[index],
                      style: const TextStyle(fontSize: 16)),
                  leading: const Icon(Icons.access_time),
                  onTap: () {
                    Navigator.pop(context, timesToShow[index]);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
