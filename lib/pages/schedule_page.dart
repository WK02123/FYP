import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shuttle_bus_app/pages/seat_selection_page.dart';

class SchedulePage extends StatelessWidget {
  final String origin;
  final String destination;
  final String date;

  const SchedulePage({
    super.key,
    required this.origin,
    required this.destination,
    required this.date,
  });

  @override
  Widget build(BuildContext context) {
    final List<String> availableTimes = [
      '7:00 AM',
      '9:00 AM',
      '12:00 PM',
    ];

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // 🔴 Top App Bar
          Container(
            width: double.infinity,
            height: 100,
            padding: const EdgeInsets.only(left: 10),
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
                Text(
                  "Depart: $origin to $destination",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                )
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 🚌 Bus Times
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: availableTimes.length,
              itemBuilder: (context, index) {
                final time = availableTimes[index];
                final scheduleId = "${origin}_${destination}_$time".replaceAll(" ", "");

                return FutureBuilder<QuerySnapshot>(
                  future: FirebaseFirestore.instance
                      .collection('booked_seats')
                      .where('scheduleId', isEqualTo: scheduleId)
                      .get(),
                  builder: (context, snapshot) {
                    int bookedCount = 0;
                    if (snapshot.hasData) {
                      bookedCount = snapshot.data!.docs.length;
                    }

                    final availableSeats = 15 - bookedCount;

                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SeatSelectionPage(
                              scheduleId: scheduleId,
                              origin: origin,
                              destination: destination,
                              time: time,
                              date: date,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 10),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(15),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black12,
                              blurRadius: 6,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  time,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  '$availableSeats Seat(s)',
                                  style: const TextStyle(color: Colors.green),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(origin),
                                const Text(
                                  '15 Min',
                                  style: TextStyle(color: Colors.red),
                                ),
                                Text(destination),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
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
