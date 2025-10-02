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
  final String time;        // "7:00 AM" (12h)
  final String date;        // "YYYY-MM-DD"
  final String scheduleId;  // e.g. "Relau_INTIPenang_7:00AM" (your existing scheme)

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

  /// Convert "7:00 AM" -> "07:00" (24h) so the driver schedule can sort reliably.
  String _to24h(String t12) {
    final s = t12.trim().toUpperCase();
    final isAm = s.endsWith('AM');
    final isPm = s.endsWith('PM');
    final core = s.replaceAll('AM', '').replaceAll('PM', '').trim(); // "7:05"
    final parts = core.split(':');
    int h = int.parse(parts[0]);
    final m = parts.length > 1 ? int.parse(parts[1]) : 0;
    if (isPm && h != 12) h += 12;
    if (isAm && h == 12) h = 0;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// Ensure a trip exists and return its docId (idempotent).
  /// Trip doc is used by driver pages and to anchor seats (via tripId).
  Future<String> _ensureTrip() async {
    final user = FirebaseAuth.instance.currentUser!;
    final fs = FirebaseFirestore.instance;

    final routeKey = '${widget.origin.trim()}|${widget.destination.trim()}';
    final routeSnap = await fs.collection('routes').doc(routeKey).get();
    if (!routeSnap.exists) {
      throw Exception('Route not found: $routeKey');
    }
    final route = routeSnap.data()!;
    final busCode = (route['busCode'] ?? '').toString();
    String? driverId = (route['driverId'] as String?);

    if ((driverId == null || driverId.isEmpty) && busCode.isNotEmpty) {
      final ds = await fs
          .collection('drivers')
          .where('busCode', isEqualTo: busCode)
          .where('disabled', isEqualTo: false)
          .limit(1)
          .get();
      if (ds.docs.isEmpty) {
        throw Exception('No active driver for busCode $busCode');
      }
      driverId = ds.docs.first.id; // driver docId = UID
    }

    final time24 = _to24h(widget.time);

    // Stable natural key prevents duplicates on retry:
    final tripId = '${user.uid}|$routeKey|${widget.date}|$time24'
        .replaceAll(' ', '');

    final tripRef = fs.collection('trips').doc(tripId);

    await fs.runTransaction((tx) async {
      final snap = await tx.get(tripRef);
      if (!snap.exists) {
        tx.set(tripRef, {
          'tripId'      : tripId,
          'studentId'   : user.uid,
          'studentEmail': user.email,
          'origin'      : widget.origin,
          'destination' : widget.destination,
          'date'        : widget.date,   // "YYYY-MM-DD"
          'time'        : time24,        // "HH:mm"
          'busCode'     : busCode,
          'driverId'    : driverId,
          'status'      : 'scheduled',
          'createdAt'   : FieldValue.serverTimestamp(),
        });
      }
    });

    return tripId;
  }

  /// Your previous uniqueness: scheduleId + date + seat.
  String _seatDocId(String seat) => '${widget.scheduleId}|${widget.date}|$seat';

  /// Re-check that selected seats are still free.
  Future<List<String>> _alreadyBookedSeats() async {
    final fs = FirebaseFirestore.instance;
    final taken = <String>[];
    const chunk = 10;

    for (int i = 0; i < widget.selectedSeats.length; i += chunk) {
      final part = widget.selectedSeats.sublist(
        i, (i + chunk > widget.selectedSeats.length) ? widget.selectedSeats.length : i + chunk,
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
      // 1) ensure the trip exists (and get its id)
      final tripId = await _ensureTrip();

      // 2) race-safe seat check
      final taken = await _alreadyBookedSeats();
      if (taken.isNotEmpty) {
        final msg = 'These seats were just taken: ${taken.join(', ')}. Please pick others.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        setState(() => _saving = false);
        return;
      }

      // 3) write booked_seats with studentId + tripId (so QR page can find them)
      final fs = FirebaseFirestore.instance;
      final batch = fs.batch();
      for (final seat in widget.selectedSeats) {
        final ref = fs.collection('booked_seats').doc(_seatDocId(seat));
        batch.set(ref, {
          'tripId'     : tripId,                 // 👈 anchor to trip
          'studentId'  : user.uid,               // 👈 not "userId"
          'studentEmail': _email,
          'studentName' : _name,
          'studentPhone': _phone,

          'seatNumber' : seat,
          'scheduleId' : widget.scheduleId,
          'date'       : widget.date,            // keep same format
          'time'       : widget.time,            // store 12h if you like, not used for queries
          'origin'     : widget.origin,
          'destination': widget.destination,

          'createdAt'  : FieldValue.serverTimestamp(),
        }, SetOptions(merge: false));
      }
      await batch.commit();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Booking confirmed!')),
      );

      // 4) back to Home
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
            (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to confirm booking: $e')),
      );
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
