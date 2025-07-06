import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'booking_confirmation_page.dart';

class SeatSelectionPage extends StatefulWidget {
  final String scheduleId;
  final String origin;
  final String destination;
  final String time;
  final String date;

  const SeatSelectionPage({
    super.key,
    required this.scheduleId,
    required this.origin,
    required this.destination,
    required this.time,
    required this.date,
  });

  @override
  State<SeatSelectionPage> createState() => _SeatSelectionPageState();
}

class _SeatSelectionPageState extends State<SeatSelectionPage> {
  final List<String> allSeats = [
    'A1', 'A2', 'A3',
    'B1', 'B2', 'B3',
    'C1', 'C2', 'C3',
    'D1', 'D2', 'D3',
    'E1', 'E2', 'E3',
  ];

  List<String> bookedSeats = [];
  List<String> selectedSeats = [];

  @override
  void initState() {
    super.initState();
    fetchBookedSeats();
  }

  Future<void> fetchBookedSeats() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('booked_seats')
        .where('scheduleId', isEqualTo: widget.scheduleId)
        .where('date', isEqualTo: widget.date)
        .get();

    final seats = snapshot.docs.map((doc) => doc['seatNumber'] as String).toList();
    setState(() {
      bookedSeats = seats;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // Top App Bar
          Container(
            width: double.infinity,
            height: 100,
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
                  'Choose Seat',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Text('Driver Cabin', style: TextStyle(color: Colors.grey)),
          const Divider(),

          // Seat Grid
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(20),
                margin: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 10,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: GridView.builder(
                  itemCount: allSeats.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 20,
                    crossAxisSpacing: 20,
                  ),
                  itemBuilder: (context, index) {
                    final seat = allSeats[index];
                    final isBooked = bookedSeats.contains(seat);
                    final isSelected = selectedSeats.contains(seat);

                    return GestureDetector(
                      onTap: isBooked
                          ? null
                          : () {
                        setState(() {
                          if (isSelected) {
                            selectedSeats.remove(seat);
                          } else {
                            selectedSeats.add(seat);
                          }
                        });
                      },
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isBooked
                              ? Colors.grey
                              : isSelected
                              ? Colors.red
                              : Colors.white,
                          border: Border.all(color: Colors.grey.shade400, width: 1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          seat,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isBooked || isSelected ? Colors.white : Colors.black,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // Bottom Booking Bar
          if (selectedSeats.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              decoration: const BoxDecoration(
                color: Color(0xFFD32F2F),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(30),
                  topRight: Radius.circular(30),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Selected: ${selectedSeats.join(', ')}',
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BookingConfirmationPage(
                            selectedSeats: selectedSeats,
                            origin: widget.origin,
                            destination: widget.destination,
                            time: widget.time,
                            date: widget.date,
                            scheduleId: widget.scheduleId,
                          ),
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.red,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: const Text("Next"),
                  )
                ],
              ),
            ),
        ],
      ),
    );
  }
}
