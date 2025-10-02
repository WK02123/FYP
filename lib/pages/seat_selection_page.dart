import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'booking_confirmation_page.dart';

class SeatSelectionPage extends StatefulWidget {
  final String scheduleId;   // e.g. "Relau_INTIPenang_7:00AM"
  final String origin;       // e.g. "Relau"
  final String destination;  // e.g. "INTI Penang"
  final String time;         // e.g. "7:00 AM"
  final String date;         // e.g. "2025-10-07"

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
  // 5 rows x 3 columns (A1..E3)
  final List<String> rows = const ['A', 'B', 'C', 'D', 'E'];

  List<String> bookedSeats = [];
  List<String> selectedSeats = [];
  bool _creatingTrip = false;

  @override
  void initState() {
    super.initState();
    fetchBookedSeats();
  }

  // -------------------- Load booked seats --------------------
  Future<void> fetchBookedSeats() async {
    try {
      final q = await FirebaseFirestore.instance
          .collection('booked_seats')
          .where('scheduleId', isEqualTo: widget.scheduleId)
          .where('date', isEqualTo: widget.date)
          .get();

      final seats = q.docs
          .map((d) => (d.data()['seatNumber'] as String?) ?? '')
          .where((s) => s.isNotEmpty)
          .toList();

      if (!mounted) return;
      setState(() => bookedSeats = seats);
    } catch (e, st) {
      debugPrint('⚠️ fetchBookedSeats error: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load seats: $e')),
      );
    }
  }

  // -------------------- Ensure a trip exists (so driver sees it) --------------------
  Future<void> _ensureTripExists() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in');

    final fs = FirebaseFirestore.instance;
    final routeKey = '${widget.origin.trim()}|${widget.destination.trim()}';
    debugPrint('🔎 routeKey="$routeKey"');

    // 1) Read route mapping
    final routeSnap = await fs.collection('routes').doc(routeKey).get();
    if (!routeSnap.exists) {
      throw Exception('Route not found: "$routeKey". Create routes/$routeKey');
    }

    final route = routeSnap.data()!;
    final busCode = (route['busCode'] ?? '').toString();
    String? driverId = (route['driverId'] as String?);
    debugPrint('🧭 route.busCode="$busCode" route.driverId="$driverId"');

    // 2) Resolve driver by busCode if no driverId on the route
    if (driverId == null || driverId.isEmpty) {
      final ds = await fs
          .collection('drivers')
          .where('busCode', isEqualTo: busCode)
          .where('disabled', isEqualTo: false)
          .limit(1)
          .get();
      if (ds.docs.isEmpty) {
        throw Exception('No driver found for busCode "$busCode"');
      }
      driverId = ds.docs.first.id; // driver doc id == driver’s auth uid
    }

    // 3) Convert "7:00 AM" -> "07:00"
    String to24h(String t12) {
      final s = t12.trim().toUpperCase();
      final isAm = s.endsWith('AM');
      final isPm = s.endsWith('PM');
      final core = s.replaceAll('AM', '').replaceAll('PM', '').trim();
      final parts = core.split(':');
      int h = int.parse(parts[0]);
      final m = parts.length > 1 ? int.parse(parts[1]) : 0;
      if (isPm && h != 12) h += 12;
      if (isAm && h == 12) h = 0;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }

    final time24 = to24h(widget.time);

    // 4) Stable trip id (idempotent)
    final tripId =
    '${user.uid}|$routeKey|${widget.date}|$time24'.replaceAll(' ', '');
    final tripRef = fs.collection('trips').doc(tripId);

    // Upsert (safe to call multiple times)
    await tripRef.set({
      'tripId': tripId,
      'studentId': user.uid,
      'studentEmail': user.email,
      'origin': widget.origin,
      'destination': widget.destination,
      'date': widget.date,   // YYYY-MM-DD
      'time': time24,        // HH:mm
      'busCode': busCode,
      'driverId': driverId,
      'status': 'scheduled',
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    debugPrint('✅ Trip upserted: $tripId');
  }

  // -------------------- Next (confirm) --------------------
  Future<void> _onNext() async {
    if (selectedSeats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one seat')),
      );
      return;
    }

    try {
      setState(() => _creatingTrip = true);

      // Make sure the trip exists before going to confirmation
      await _ensureTripExists();

      if (!mounted) return;
      await Navigator.push(
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

      // After returning from confirmation, refresh booked seats
      if (mounted) await fetchBookedSeats();
    } catch (e, st) {
      debugPrint('❌ _onNext error: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create trip: $e')),
      );
    } finally {
      if (mounted) setState(() => _creatingTrip = false);
    }
  }

  // -------------------- UI bits --------------------
  Widget _seatBox(String code) {
    final isBooked = bookedSeats.contains(code);
    final isSelected = selectedSeats.contains(code);

    Color iconColor;
    if (isBooked) {
      iconColor = Colors.grey;
    } else if (isSelected) {
      iconColor = const Color(0xFFD32F2F);
    } else {
      iconColor = Colors.black54;
    }

    return GestureDetector(
      onTap: isBooked
          ? null
          : () {
        setState(() {
          if (isSelected) {
            selectedSeats.remove(code);
          } else {
            selectedSeats.add(code);
          }
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 64,
        height: 64,
        alignment: Alignment.center,
        child: Column(
          children: [
            Icon(Icons.event_seat, size: 36, color: iconColor),
            Text(
              code,
              style: TextStyle(
                color: isBooked
                    ? Colors.grey
                    : (isSelected ? const Color(0xFFD32F2F) : Colors.black87),
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _busRow(String r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _seatBox('${r}1'),
          const SizedBox(width: 14),
          _seatBox('${r}2'),
          const SizedBox(width: 36), // aisle
          _seatBox('${r}3'),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Icon(Icons.event_seat, color: color, size: 18),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final nextDisabled = _creatingTrip || selectedSeats.isEmpty;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 50, 16, 20),
            decoration: const BoxDecoration(
              color: Color(0xFFD32F2F),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      "Seat Selection",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  "${widget.origin} → ${widget.destination}",
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                Text(
                  "${widget.date} | ${widget.time}",
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),

          // Legend
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _legendDot(Colors.black54, 'Available'),
                _legendDot(const Color(0xFFD32F2F), 'Selected'),
                _legendDot(Colors.grey, 'Booked'),
              ],
            ),
          ),

          // Bus Cabin
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
                margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 12,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const Text('Driver Cabin', style: TextStyle(color: Colors.grey)),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        itemCount: rows.length,
                        itemBuilder: (_, i) => _busRow(rows[i]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Action Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 18),
            decoration: const BoxDecoration(
              color: Color(0xFFD32F2F),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selectedSeats.isEmpty
                        ? "Select your seat(s)"
                        : "Selected: ${selectedSeats.join(', ')}",
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: nextDisabled ? null : _onNext,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                    nextDisabled ? Colors.white70 : Colors.white,
                    foregroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: _creatingTrip
                      ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.red,
                    ),
                  )
                      : const Text('Next', style: TextStyle(fontSize: 16)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
