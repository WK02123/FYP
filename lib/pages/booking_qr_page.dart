import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class BookingQrPage extends StatefulWidget {
  final String tripId;
  final String seatDocId;

  const BookingQrPage({
    super.key,
    required this.tripId,
    required this.seatDocId,
  });

  @override
  State<BookingQrPage> createState() => _BookingQrPageState();
}

class _BookingQrPageState extends State<BookingQrPage> {
  final _fs = FirebaseFirestore.instance;

  DocumentSnapshot<Map<String, dynamic>>? _trip;
  DocumentSnapshot<Map<String, dynamic>>? _seat;
  String? _error;
  String _payload = '';
  bool _locked = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  String _fmtDate(dynamic v) {
    if (v == null) return '-';
    if (v is Timestamp) {
      final d = v.toDate();
      return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    return v.toString().trim();
  }

  String _fmtTime(dynamic v) {
    if (v == null) return '-';
    if (v is Timestamp) {
      final d = v.toDate();
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return v.toString().trim();
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _resolveTripDoc(String navId) async {
    var snap = await _fs.collection('driver_trips').doc(navId).get();
    if (snap.exists) return snap;

    final byField = await _fs
        .collection('driver_trips')
        .where('tripId', isEqualTo: navId)
        .limit(1)
        .get();
    if (byField.docs.isNotEmpty) return byField.docs.first;

    throw Exception('Trip not found: $navId');
  }

  Future<void> _loadAll() async {
    try {
      setState(() {
        _trip = null;
        _seat = null;
        _payload = '';
        _error = null;
        _locked = false;
      });

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        setState(() => _error = 'You are not signed in.');
        return;
      }

      final tripSnap = await _resolveTripDoc(widget.tripId);
      final t = tripSnap.data() ?? {};

      final seatSnap = await _fs.collection('booked_seats').doc(widget.seatDocId).get();
      if (!seatSnap.exists) {
        setState(() {
          _trip = tripSnap;
          _error = 'Seat not found or already deleted.';
        });
        return;
      }

      final s = seatSnap.data()!;
      final owner = (s['studentId'] ?? s['userId'])?.toString();
      if (owner != uid) {
        setState(() {
          _trip = tripSnap;
          _error = 'You do not own this seat.';
        });
        return;
      }

      final tripIdCurrent = tripSnap.id;
      final top = await _fs.collection('boardings').doc('$tripIdCurrent|$uid').get();
      final nested = await tripSnap.reference.collection('scans').doc(uid).get();
      if ((top.exists && (top.data()?['locked'] == true)) ||
          (nested.exists && (nested.data()?['locked'] == true))) {
        setState(() {
          _trip = tripSnap;
          _seat = seatSnap;
          _locked = true;
        });
        return;
      }

      String effectiveTripId = (s['tripId'] ?? '').toString().trim();
      final origin = (t['origin'] ?? '').toString();
      final destination = (t['destination'] ?? '').toString();
      final date = _fmtDate(t['date']);
      final time = _fmtTime(t['time']);
      final seatName = (s['seatNumber'] ?? '').toString();

      if (effectiveTripId.isEmpty) effectiveTripId = tripSnap.id;

      // ✅ Correct 8-part payload format
      final payload = [
        'RIDEMATE',
        effectiveTripId, // driver_trip id
        uid,              // student id
        origin,
        destination,
        date,
        time,
        seatName,
      ].join('|');

      setState(() {
        _trip = tripSnap;
        _seat = seatSnap;
        _payload = payload;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _cancelThisSeat() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _trip == null || _seat == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: Text('Seat ${( _seat!.data()?['seatNumber'] ?? '' )}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, cancel')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);

    try {
      final tripRef = _trip!.reference;
      await _seat!.reference.delete();

      final myRemainingSeats = await _fs
          .collection('booked_seats')
          .where('studentId', isEqualTo: user.uid)
          .where('tripId', isEqualTo: tripRef.id)
          .limit(1)
          .get();

      if (myRemainingSeats.docs.isEmpty) {
        final myBoardings = await _fs
            .collection('boardings')
            .where('tripId', isEqualTo: tripRef.id)
            .where('studentId', isEqualTo: user.uid)
            .get();
        if (myBoardings.docs.isNotEmpty) {
          final b = _fs.batch();
          for (final d in myBoardings.docs) b.delete(d.reference);
          await b.commit();
        }

        final scan = await tripRef.collection('scans').doc(user.uid).get();
        if (scan.exists) await scan.reference.delete();

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Booking cancelled.')),
        );
        Navigator.pop(context, true);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Seat cancelled.')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to cancel: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      title: const Text('Booking Details'),
      backgroundColor: const Color(0xFFD32F2F),
      foregroundColor: Colors.white,
      actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAll)],
    );

    if (_error != null) {
      return Scaffold(appBar: appBar, body: Center(child: Text('⚠️ $_error')));
    }
    if (_trip == null) {
      return Scaffold(appBar: appBar, body: const Center(child: CircularProgressIndicator()));
    }

    final t = _trip!.data() ?? {};
    final origin = (t['origin'] ?? '').toString();
    final destination = (t['destination'] ?? '').toString();
    final date = _fmtDate(t['date']);
    final time = _fmtTime(t['time']);
    final busCode = (t['busCode'] ?? '').toString();
    final status = (t['status'] ?? 'scheduled').toString();
    final seatLabel = (_seat?.data()?['seatNumber'] ?? '—').toString();

    if (_locked) {
      return Scaffold(
        appBar: appBar,
        body: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TripHeaderCard(origin: origin, destination: destination, date: date, time: time, busCode: busCode, status: status),
              const SizedBox(height: 12),
              _SeatChip(seatLabel: seatLabel),
              const SizedBox(height: 16),
              _LockedNotice(),
            ],
          ),
        ),
      );
    }

    final screenW = MediaQuery.of(context).size.width;
    final qrSize = math.max(180.0, math.min(300.0, screenW - 72));

    return Scaffold(
      appBar: appBar,
      backgroundColor: const Color(0xFFF5F6FA),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TripHeaderCard(origin: origin, destination: destination, date: date, time: time, busCode: busCode, status: status),
              const SizedBox(height: 12),
              _SeatChip(seatLabel: seatLabel),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 12, offset: Offset(0, 5))],
                ),
                child: Column(
                  children: [
                    const Text('Show this QR to the driver', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 14),
                    _payload.isEmpty
                        ? const Icon(Icons.qr_code_2, size: 96, color: Colors.black26)
                        : QrImageView(data: _payload, version: QrVersions.auto, backgroundColor: Colors.white, size: qrSize),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: _payload.isEmpty
                          ? null
                          : () {
                        Clipboard.setData(ClipboardData(text: _payload));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('QR payload copied')),
                        );
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy payload'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: _busy
            ? const SizedBox(height: 52, child: Center(child: CircularProgressIndicator()))
            : ElevatedButton.icon(
          onPressed: _cancelThisSeat,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Cancel booking'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade700,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            elevation: 2,
          ),
        ),
      ),
    );
  }
}

class _TripHeaderCard extends StatelessWidget {
  final String origin, destination, date, time, busCode, status;
  const _TripHeaderCard({
    required this.origin,
    required this.destination,
    required this.date,
    required this.time,
    required this.busCode,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Colors.red.shade100,
            child: const Icon(Icons.directions_bus, color: Colors.red),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$origin → $destination', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 4),
                Text('$date  •  $time  •  $busCode', style: const TextStyle(color: Colors.black87)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: status == 'scheduled' ? Colors.green.withOpacity(.12) : Colors.orange.withOpacity(.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              status,
              style: TextStyle(
                color: status == 'scheduled' ? Colors.green[800] : Colors.orange[800],
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatChip extends StatelessWidget {
  final String seatLabel;
  const _SeatChip({required this.seatLabel});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.event_seat, color: Colors.black87),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDBEAFE)),
          ),
          child: Text('Seat: $seatLabel', style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: .2)),
        ),
      ],
    );
  }
}

class _LockedNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3F3),
        border: Border.all(color: const Color(0xFFFFCACA)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'This booking has been checked in by the driver.\nAccess is locked.',
        style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
      ),
    );
  }
}
