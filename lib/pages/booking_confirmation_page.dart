// lib/pages/booking_confirmation_page.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'homepage.dart';

class BookingConfirmationPage extends StatefulWidget {
  final List<String> selectedSeats;
  final String origin;
  final String destination;
  final String time;        // e.g. "7:00 AM" (12h) or "19:00" (24h)
  final String date;        // "YYYY-MM-DD"
  final String scheduleId;  // e.g., "Relau_INTIPenang_7:00AM"

  const BookingConfirmationPage({
    super.key,
    required this.selectedSeats,
    required this.origin,
    required this.destination,
    required this.time,
    required this.date,
    required this.scheduleId,
  });

  @override
  State<BookingConfirmationPage> createState() =>
      _BookingConfirmationPageState();
}

class _BookingConfirmationPageState extends State<BookingConfirmationPage> {
  bool _saving = false;

  String _name = '';
  String _email = '';
  String _phone = '';

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    _email = user.email ?? '';

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = doc.data() ?? {};
      setState(() {
        _name  = (data['name']  ?? '').toString();
        _phone = (data['phone'] ?? '').toString();
      });
    } catch (_) {
      setState(() {});
    }
  }

  // to24h: "7:05 AM" -> "07:05"; "19:05" -> "19:05"
  String _to24h(String t) {
    final s = t.trim();
    final m24 = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
    if (m24 != null) {
      final h = int.parse(m24.group(1)!);
      final mm = m24.group(2)!;
      return '${h.toString().padLeft(2, '0')}:$mm';
    }
    final up = s.toUpperCase();
    if (!up.endsWith('AM') && !up.endsWith('PM')) return s;
    final isAm = up.endsWith('AM');
    final core = up.substring(0, up.length - 2).trim();
    final parts = core.split(':');
    int h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    if (!isAm && h != 12) h += 12;
    if (isAm && h == 12) h = 0;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// Upserts BOTH driver_trips and student_trips and returns driverTripId
  Future<String> _ensureTrips() async {
    final user = FirebaseAuth.instance.currentUser!;
    final fs = FirebaseFirestore.instance;
    final time24 = _to24h(widget.time);

    // best-effort: find driver & bus from routes/driver
    String driverId = 'unassigned';
    String busCode = '';

    try {
      final routeKey = '${widget.origin.trim()}|${widget.destination.trim()}';
      final routeSnap = await fs.collection('routes').doc(routeKey).get();
      if (routeSnap.exists) {
        final route = routeSnap.data()!;
        busCode = (route['busCode'] ?? '').toString();
        final fromRoute = (route['driverId'] as String? ?? '').trim();
        if (fromRoute.isNotEmpty) driverId = fromRoute;
      }
      if (driverId == 'unassigned' && busCode.isNotEmpty) {
        final ds = await fs
            .collection('drivers')
            .where('busCode', isEqualTo: busCode)
            .where('disabled', isEqualTo: false)
            .limit(1)
            .get();
        if (ds.docs.isNotEmpty) driverId = ds.docs.first.id;
      }
    } catch (_) {}

    // Build stable ids
    final driverTripId =
    '$driverId|${widget.origin}|${widget.destination}|${widget.date}|$time24'
        .replaceAll(' ', '');
    final studentTripId =
    '${user.uid}|${widget.origin}|${widget.destination}|${widget.date}|$time24'
        .replaceAll(' ', '');

    final driverTripRef = fs.collection('driver_trips').doc(driverTripId);
    final studentTripRef = fs.collection('student_trips').doc(studentTripId);

    // Upsert driver_trips
    final driverExisting = await driverTripRef.get();
    if (!driverExisting.exists) {
      await driverTripRef.set({
        'tripId'      : driverTripId,
        'origin'      : widget.origin,
        'destination' : widget.destination,
        'date'        : widget.date,
        'time'        : time24,
        'time12'      : widget.time,
        'busCode'     : busCode,
        'driverId'    : driverId, // "unassigned" if none
        'status'      : 'scheduled',
        'createdAt'   : FieldValue.serverTimestamp(),
      });
    } else {
      await driverTripRef.set({
        'updatedAt'   : FieldValue.serverTimestamp(),
        if (busCode.isNotEmpty) 'busCode': busCode,
        if (driverId.isNotEmpty) 'driverId': driverId,
      }, SetOptions(merge: true));
    }

    // Upsert student_trips (so this collection has data)
    final studentExisting = await studentTripRef.get();
    if (!studentExisting.exists) {
      await studentTripRef.set({
        'tripId'        : studentTripId,
        'driverTripId'  : driverTripId,  // <- link
        'origin'        : widget.origin,
        'destination'   : widget.destination,
        'date'          : widget.date,
        'time'          : time24,
        'time12'        : widget.time,
        'studentId'     : user.uid,
        'studentEmail'  : _email,
        'studentName'   : _name,
        'studentPhone'  : _phone,
        'status'        : 'scheduled',
        'createdAt'     : FieldValue.serverTimestamp(),
      });
    } else {
      await studentTripRef.set({
        'driverTripId'  : driverTripId,
        'updatedAt'     : FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    return driverTripId;
  }

  String _seatDocId(String seat) => '${widget.scheduleId}|${widget.date}|$seat';

  Future<List<String>> _alreadyBookedSeats() async {
    final fs = FirebaseFirestore.instance;
    final taken = <String>[];
    const chunk = 10;

    for (int i = 0; i < widget.selectedSeats.length; i += chunk) {
      final part = widget.selectedSeats.sublist(
        i, (i + chunk > widget.selectedSeats.length)
          ? widget.selectedSeats.length
          : i + chunk,
      );

      final q = await fs
          .collection('booked_seats')
          .where('scheduleId', isEqualTo: widget.scheduleId)
          .where('date', isEqualTo: widget.date)
          .where('seatNumber', whereIn: part)
          .get();

      for (final d in q.docs) {
        final s = (d.data()['seatNumber'] as String?) ?? '';
        if (s.isNotEmpty) taken.add(s);
      }
    }
    return taken.toSet().toList();
  }

  Future<void> _confirm() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in again')),
      );
      return;
    }
    setState(() => _saving = true);

    try {
      // 1) ensure BOTH trips exist
      final driverTripId = await _ensureTrips();

      // 2) race-safe seat check
      final taken = await _alreadyBookedSeats();
      if (taken.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('These seats were just taken: ${taken.join(', ')}. Pick others.')),
        );
        setState(() => _saving = false);
        return;
      }

      // 3) write booked_seats anchored to driverTripId (24h time!)
      final fs = FirebaseFirestore.instance;
      final batch = fs.batch();
      final time24 = _to24h(widget.time);

      for (final seat in widget.selectedSeats) {
        final ref = fs.collection('booked_seats').doc(_seatDocId(seat));
        batch.set(ref, {
          'tripId'      : driverTripId,     // <- driver_trips id
          'studentId'   : user.uid,
          'studentEmail': _email,
          'studentName' : _name,
          'studentPhone': _phone,

          'seatNumber'  : seat,
          'scheduleId'  : widget.scheduleId,
          'date'        : widget.date,
          'time'        : time24,           // <- store 24h
          'origin'      : widget.origin,
          'destination' : widget.destination,

          'createdAt'   : FieldValue.serverTimestamp(),
          'locked'      : false,
        });
      }
      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Booking confirmed!')),
      );

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
            (route) => false,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to confirm booking: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seatsText = widget.selectedSeats.join(', ');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        title: const Text('Booking Details'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0x33D32F2F),
                child: Icon(Icons.directions_bus, color: Color(0xFFD32F2F)),
              ),
              title: Text('${widget.origin}  →  ${widget.destination}'),
              subtitle: Text('${widget.date} • ${widget.time}'),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('scheduled', style: TextStyle(color: Colors.green)),
              ),
            ),
          ),
          const SizedBox(height: 12),

          Text('Your information', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                ListTile(leading: const Icon(Icons.person),         title: Text(_name.isEmpty ? '—' : _name)),
                const Divider(height: 1),
                ListTile(leading: const Icon(Icons.email_outlined), title: Text(_email.isEmpty ? '—' : _email)),
                const Divider(height: 1),
                ListTile(leading: const Icon(Icons.phone_outlined), title: Text(_phone.isEmpty ? '—' : _phone)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: const Icon(Icons.event_seat),
              title: Text('Seats: $seatsText'),
            ),
          ),

          const SizedBox(height: 24),
          _saving
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton.icon(
            onPressed: _confirm,
            icon: const Icon(Icons.check),
            label: const Text('Confirm Booking'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}
