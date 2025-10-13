// lib/pages/booking_qr_page.dart
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class BookingQrPage extends StatefulWidget {
  /// /trips document id (or value stored in trips.tripId)
  final String tripId;

  /// booked_seats document id for THIS seat
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

  // ----------------------------- helpers -----------------------------

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
    final byId = await _fs.collection('trips').doc(navId).get();
    if (byId.exists) return byId;

    final byField = await _fs.collection('trips').where('tripId', isEqualTo: navId).limit(1).get();
    if (byField.docs.isNotEmpty) return byField.docs.first;

    throw Exception('Trip not found: $navId');
  }

  // ------------------------------- load -------------------------------

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

      // trip (whatever was passed in)
      final tripSnap = await _resolveTripDoc(widget.tripId);
      final t = tripSnap.data() ?? {};

      // seat (the one user tapped in My Bookings)
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

      // lock after driver scan?
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

      // --------------------- choose DRIVER trip id for QR ---------------------
      // Priority:
      // 1) Use booked_seats.tripId (should already point to the DRIVER trip)
      // 2) Map by driverId + origin/dest + date/time
      // 3) Fallback to the current trip doc id
      String effectiveTripId = (s['tripId'] ?? '').toString().trim();

      final origin = (t['origin'] ?? '').toString();
      final destination = (t['destination'] ?? '').toString();
      final date = _fmtDate(t['date']);
      final time = _fmtTime(t['time'] ?? t['time12']);
      final seatName = (s['seatNumber'] ?? '').toString();

      if (effectiveTripId.isEmpty) {
        final driverId = (t['driverId'] ?? '').toString().trim();
        if (driverId.isNotEmpty) {
          final drv = await _fs
              .collection('trips')
              .where('driverId', isEqualTo: driverId)
              .where('origin', isEqualTo: origin)
              .where('destination', isEqualTo: destination)
              .get();
          String _d(dynamic v) => _fmtDate(v);
          String _tm(dynamic v) => _fmtTime(v);
          for (final d in drv.docs) {
            final dt = d.data();
            if (_d(dt['date']) == date && _tm(dt['time'] ?? dt['time12']) == time) {
              effectiveTripId = d.id;
              break;
            }
          }
        }
        if (effectiveTripId.isEmpty) {
          effectiveTripId = tripSnap.id; // last resort
        }
      }

      final payload = [
        'RIDEMATE',
        effectiveTripId, // <<--- driver trip id for instant resolve
        uid,
        origin,
        destination,
        date,
        time,
        seatName, // only this seat
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

  // ------------------------ cancel this seat ------------------------

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
      final t = _trip!.data() ?? {};
      final origin   = (t['origin'] ?? '').toString().trim();
      final destination = (t['destination'] ?? '').toString().trim();
      final date     = (t['date'] ?? '').toString().trim();                // "YYYY-MM-DD"
      final timeRaw  = (t['time'] ?? t['time12'] ?? '').toString().trim(); // prefer "HH:mm"
      final driverId = (t['driverId'] ?? '').toString().trim();

      // 1) delete THIS seat document
      await _seat!.reference.delete();

      // 2) does this student still have seats on THIS trip?
      final myRemainingSeats = await _fs
          .collection('booked_seats')
          .where('studentId', isEqualTo: user.uid)
          .where('tripId', isEqualTo: tripRef.id)
          .limit(1)
          .get();

      if (myRemainingSeats.docs.isEmpty) {
        // 2a) delete boardings for THIS student & trip
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

        // 2b) delete nested scans/* under the student's trip
        final scans = await tripRef.collection('scans').get();
        if (scans.docs.isNotEmpty) {
          final b2 = _fs.batch();
          for (final d in scans.docs) b2.delete(d.reference);
          await b2.commit();
        }

        // 2c) delete the student's trip doc
        try { await tripRef.delete(); } catch (_) {}

        // 2d) ALSO delete the DRIVER-SIDE trip(s) for the same route/date/time
        if (driverId.isNotEmpty) {
          final driverTrips = await _fs
              .collection('trips')
              .where('driverId', isEqualTo: driverId)
              .where('origin', isEqualTo: origin)
              .where('destination', isEqualTo: destination)
              .where('date', isEqualTo: date)
              .where('time', isEqualTo: timeRaw)
              .get();

          for (final d in driverTrips.docs) {
            final drvScans = await d.reference.collection('scans').get();
            if (drvScans.docs.isNotEmpty) {
              final b3 = _fs.batch();
              for (final s in drvScans.docs) b3.delete(s.reference);
              await b3.commit();
            }
            final drvBoardings = await _fs
                .collection('boardings')
                .where('tripId', isEqualTo: d.id)
                .where('studentId', isEqualTo: user.uid)
                .get();
            if (drvBoardings.docs.isNotEmpty) {
              final b4 = _fs.batch();
              for (final b in drvBoardings.docs) b4.delete(b.reference);
              await b4.commit();
            }
            try { await d.reference.delete(); } catch (_) {}
          }
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Booking cancelled.')),
        );
        Navigator.pop(context, true); // close page
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

  // -------------------------------- UI --------------------------------

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
    final time = _fmtTime(t['time'] ?? t['time12']);
    final busCode = (t['busCode'] ?? '').toString();
    final status = (t['status'] ?? 'scheduled').toString();
    final seatLabel = (_seat?.data()?['seatNumber'] ?? '—').toString();

    // lock screen (no cancel)
    if (_locked) {
      return Scaffold(
        appBar: appBar,
        body: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TripHeaderCard(
                origin: origin,
                destination: destination,
                date: date,
                time: time,
                busCode: busCode,
                status: status,
              ),
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
              _TripHeaderCard(
                origin: origin,
                destination: destination,
                date: date,
                time: time,
                busCode: busCode,
                status: status,
              ),
              const SizedBox(height: 12),
              _SeatChip(seatLabel: seatLabel),
              const SizedBox(height: 16),
              // QR card
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
                    const Text(
                      'Show this QR to the driver',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const SizedBox(height: 14),
                    _payload.isEmpty
                        ? const Icon(Icons.qr_code_2, size: 96, color: Colors.black26)
                        : QrImageView(
                      data: _payload,
                      version: QrVersions.auto,
                      backgroundColor: Colors.white,
                      size: qrSize,
                    ),
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
                    const SizedBox(height: 6),
                    // Collapsed payload preview
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _payload.isEmpty ? '—' : _payload,
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      // bottom fixed cancel button
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

// --------------------------- UI Pieces ---------------------------

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
          child: Text(
            'Seat: $seatLabel',
            style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: .2),
          ),
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
