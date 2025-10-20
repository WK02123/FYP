// lib/pages/booking_confirmation_page.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;

import 'homepage.dart';

class BookingConfirmationPage extends StatefulWidget {
  final List<String> selectedSeats;
  final String origin;
  final String destination;
  final String time;
  final String date;
  final String scheduleId;

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
  int _pricePerSeatSen = 500;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _loadRoutePrice();
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
        _name = (data['name'] ?? '').toString();
        _phone = (data['phone'] ?? '').toString();
      });
    } catch (_) {
      setState(() {});
    }
  }

  Future<void> _loadRoutePrice() async {
    try {
      final key = '${widget.origin.trim()}|${widget.destination.trim()}';
      final doc = await FirebaseFirestore.instance
          .collection('routes')
          .doc(key)
          .get();
      if (doc.exists) {
        final data = doc.data()!;
        final p = (data['priceSen'] as num?)?.toInt();
        if (p != null && p > 0) {
          setState(() => _pricePerSeatSen = p);
        }
      }
    } catch (_) {}
  }

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

  Future<String> _ensureTrips() async {
    final user = FirebaseAuth.instance.currentUser!;
    final fs = FirebaseFirestore.instance;
    final time24 = _to24h(widget.time);

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

    final driverTripId =
    '$driverId|${widget.origin}|${widget.destination}|${widget.date}|$time24'
        .replaceAll(' ', '');
    final studentTripId =
    '${user.uid}|${widget.origin}|${widget.destination}|${widget.date}|$time24'
        .replaceAll(' ', '');

    final driverTripRef = fs.collection('driver_trips').doc(driverTripId);
    final studentTripRef = fs.collection('student_trips').doc(studentTripId);

    if (!(await driverTripRef.get()).exists) {
      await driverTripRef.set({
        'tripId': driverTripId,
        'origin': widget.origin,
        'destination': widget.destination,
        'date': widget.date,
        'time': time24,
        'time12': widget.time,
        'busCode': busCode,
        'driverId': driverId,
        'status': 'scheduled',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    if (!(await studentTripRef.get()).exists) {
      await studentTripRef.set({
        'tripId': studentTripId,
        'driverTripId': driverTripId,
        'origin': widget.origin,
        'destination': widget.destination,
        'date': widget.date,
        'time': time24,
        'time12': widget.time,
        'studentId': user.uid,
        'studentEmail': _email,
        'studentName': _name,
        'studentPhone': _phone,
        'status': 'scheduled',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    return driverTripId;
  }

  String _seatDocId(String seat) =>
      '${widget.scheduleId}|${widget.date}|$seat';

  Future<List<String>> _alreadyBookedSeats() async {
    final fs = FirebaseFirestore.instance;
    final taken = <String>[];
    const chunk = 10;

    for (int i = 0; i < widget.selectedSeats.length; i += chunk) {
      final part = widget.selectedSeats.sublist(
        i,
        (i + chunk > widget.selectedSeats.length)
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

  Future<void> _payAndConfirm() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in again')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final taken = await _alreadyBookedSeats();
      if (taken.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'These seats were just taken: ${taken.join(', ')}. Pick others.',
            ),
          ),
        );
        setState(() => _saving = false);
        return;
      }

      final totalSen = _pricePerSeatSen * widget.selectedSeats.length;
      final fun = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
          .httpsCallable('createPaymentIntent');

      final resp = await fun.call({
        'amount': totalSen,
        'currency': 'myr',
        'description':
        'Shuttle ${widget.origin} → ${widget.destination} (${widget.date} ${widget.time}) x ${widget.selectedSeats.length} seat(s)',
      });

      final data = Map<String, dynamic>.from(resp.data);
      final clientSecret = data['clientSecret'] as String?;
      if (clientSecret == null || clientSecret.isEmpty) {
        throw Exception('No clientSecret from server');
      }

      final paymentIntentId = clientSecret.split('_secret_')[0];

      await stripe.Stripe.instance.initPaymentSheet(
        paymentSheetParameters: stripe.SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'Ridemate Shuttle',
          allowsDelayedPaymentMethods: false,
          style: ThemeMode.system,
        ),
      );
      await stripe.Stripe.instance.presentPaymentSheet();

      final driverTripId = await _ensureTrips();

      final fs = FirebaseFirestore.instance;
      final batch = fs.batch();
      final time24 = _to24h(widget.time);

      for (final seat in widget.selectedSeats) {
        final ref = fs.collection('booked_seats').doc(_seatDocId(seat));
        batch.set(ref, {
          'tripId': driverTripId,
          'studentId': user.uid,
          'studentEmail': _email,
          'studentName': _name,
          'studentPhone': _phone,
          'seatNumber': seat,
          'scheduleId': widget.scheduleId,
          'date': widget.date,
          'time': time24,
          'origin': widget.origin,
          'destination': widget.destination,
          'createdAt': FieldValue.serverTimestamp(),
          'locked': false,
          'priceSen': _pricePerSeatSen,
          'paid': true,
          'paymentIntentId': paymentIntentId,
        });
      }

      await batch.commit();

      // 👇 SEND BOOKING CONFIRMATION EMAIL
      try {
        final totalRm = (totalSen / 100).toStringAsFixed(2);
        debugPrint('🔵 Sending booking email to: $_email');

        final emailFun = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
            .httpsCallable('sendBookingEmail');

        await emailFun.call({
          'email': _email,
          'name': _name,
          'origin': widget.origin,
          'destination': widget.destination,
          'date': widget.date,
          'time': widget.time,
          'seats': widget.selectedSeats.join(', '),
          'totalAmount': totalRm,
        });

        debugPrint('✅ Booking email sent successfully');
      } catch (e) {
        debugPrint('❌ Email sending failed: $e');
        // Don't fail the booking if email fails
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('✅ Payment successful & booking confirmed! Check your email.')),
      );

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
            (route) => false,
      );
    } on stripe.StripeException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Stripe error: ${e.error.localizedMessage}')),
      );
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Cloud Function error: ${e.code} ${e.message}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Payment/booking failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seatsText = widget.selectedSeats.join(', ');
    final totalSen = _pricePerSeatSen * widget.selectedSeats.length;
    final totalRm = (totalSen / 100).toStringAsFixed(2);

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
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0x33D32F2F),
                child: Icon(Icons.directions_bus, color: Color(0xFFD32F2F)),
              ),
              title: Text('${widget.origin}  →  ${widget.destination}'),
              subtitle: Text('${widget.date} • ${widget.time}'),
              trailing: Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('scheduled',
                    style: TextStyle(color: Colors.green)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('Your information',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(_name.isEmpty ? '—' : _name)),
                const Divider(height: 1),
                ListTile(
                    leading: const Icon(Icons.email_outlined),
                    title: Text(_email.isEmpty ? '—' : _email)),
                const Divider(height: 1),
                ListTile(
                    leading: const Icon(Icons.phone_outlined),
                    title: Text(_phone.isEmpty ? '—' : _phone)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                ListTile(
                    leading: const Icon(Icons.event_seat),
                    title: Text('Seats: $seatsText')),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: const Text('Total'),
                  trailing: Text('RM $totalRm',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _saving
              ? const Center(child: CircularProgressIndicator())
              : ElevatedButton.icon(
            onPressed: _payAndConfirm,
            icon: const Icon(Icons.lock),
            label: const Text('Pay & Confirm'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}