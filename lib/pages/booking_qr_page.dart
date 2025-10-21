// lib/pages/booking_qr_page.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'notification_service.dart';

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

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subBoarding;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subScan;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subSeat;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subTrip;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _cancelSubs();
    super.dispose();
  }

  void _cancelSubs() {
    _subBoarding?.cancel();
    _subScan?.cancel();
    _subSeat?.cancel();
    _subTrip?.cancel();
    _subBoarding = null;
    _subScan = null;
    _subSeat = null;
    _subTrip = null;
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

  Future<void> _batchDelete(List<DocumentReference> refs) async {
    const chunk = 400;
    for (var i = 0; i < refs.length; i += chunk) {
      final part = refs.sublist(i, (i + chunk > refs.length) ? refs.length : i + chunk);
      final b = _fs.batch();
      for (final r in part) {
        b.delete(r);
      }
      await b.commit();
    }
  }

  Future<void> _removeStudentMirrors({
    required String studentUid,
    required String driverTripId,
    required String origin,
    required String destination,
    required String date,
    required String time,
  }) async {
    final stById = await _fs
        .collection('student_trips')
        .where('studentId', isEqualTo: studentUid)
        .where('driverTripId', isEqualTo: driverTripId)
        .get();
    if (stById.docs.isNotEmpty) {
      await _batchDelete(stById.docs.map((d) => d.reference).toList());
    } else {
      final stByRoute = await _fs
          .collection('student_trips')
          .where('studentId', isEqualTo: studentUid)
          .where('origin', isEqualTo: origin)
          .where('destination', isEqualTo: destination)
          .where('date', isEqualTo: date)
          .where('time', isEqualTo: time)
          .get();
      if (stByRoute.docs.isNotEmpty) {
        await _batchDelete(stByRoute.docs.map((d) => d.reference).toList());
      }
    }

    final legacy = await _fs
        .collection('trips')
        .where('studentId', isEqualTo: studentUid)
        .where('origin', isEqualTo: origin)
        .where('destination', isEqualTo: destination)
        .where('date', isEqualTo: date)
        .where('time', isEqualTo: time)
        .get();
    if (legacy.docs.isNotEmpty) {
      await _batchDelete(legacy.docs.map((d) => d.reference).toList());
    }
  }

  Future<void> _maybeDeleteEmptyDriverTrip(
      DocumentReference<Map<String, dynamic>> driverTripRef,
      ) async {
    final seats = await _fs
        .collection('booked_seats')
        .where('tripId', isEqualTo: driverTripRef.id)
        .limit(1)
        .get();
    if (seats.docs.isNotEmpty) return;

    final scans = await driverTripRef.collection('scans').limit(1).get();
    if (scans.docs.isNotEmpty) return;

    try {
      await driverTripRef.delete();
    } catch (_) {}
  }

  Future<void> _loadAll() async {
    try {
      _cancelSubs();
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
        _attachLiveWatchers(tripSnap.reference, seatSnap.reference, uid);
        return;
      }

      String effectiveTripId = (s['tripId'] ?? '').toString().trim();

      final origin = (t['origin'] ?? '').toString();
      final destination = (t['destination'] ?? '').toString();
      final date = _fmtDate(t['date']);
      final time = _fmtTime(t['time']);
      final seatName = (s['seatNumber'] ?? '').toString();

      if (effectiveTripId.isEmpty) {
        effectiveTripId = tripSnap.id;
      }

      final payload = [
        'RIDEMATE',
        effectiveTripId,
        uid,
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

      _attachLiveWatchers(tripSnap.reference, seatSnap.reference, uid);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _attachLiveWatchers(
      DocumentReference<Map<String, dynamic>> tripRef,
      DocumentReference<Map<String, dynamic>> seatRef,
      String studentUid,
      ) {
    _cancelSubs();

    _subTrip = tripRef.snapshots().listen((snap) {
      if (!mounted) return;
      setState(() => _trip = snap);
    });

    _subScan = tripRef.collection('scans').doc(studentUid).snapshots().listen((snap) {
      if (!mounted) return;
      final locked = (snap.data()?['locked'] == true);
      if (locked && !_locked) {
        setState(() => _locked = true);
      }
    });

    final boardedId = '${tripRef.id}|$studentUid';
    _subBoarding = _fs.collection('boardings').doc(boardedId).snapshots().listen((snap) {
      if (!mounted) return;
      final locked = (snap.data()?['locked'] == true);
      if (locked && !_locked) {
        setState(() => _locked = true);
      }
    });

    _subSeat = seatRef.snapshots().listen((snap) {
      if (!mounted) return;
      if (!snap.exists) return;
      setState(() => _seat = snap);
      final status = (snap.data()?['status'] ?? '').toString().toLowerCase();
      final isLocked = (snap.data()?['locked'] == true);
      if ((status == 'boarded' || isLocked) && !_locked) {
        setState(() => _locked = true);
      }
    });
  }

  Future<void> _cancelThisSeat() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _trip == null || _seat == null) return;

    final seatData = _seat!.data() ?? {};
    final seatNumber = (seatData['seatNumber'] ?? '').toString();
    final priceSen = (seatData['priceSen'] as num?)?.toInt() ?? 0;
    final paymentIntentId = (seatData['paymentIntentId'] ?? '').toString();
    final studentEmail = (seatData['studentEmail'] ?? '').toString();
    final studentName = (seatData['studentName'] ?? '').toString();

    final tripData = _trip!.data() ?? {};
    final dateStr = _fmtDate(tripData['date']);
    final timeStr = _fmtTime(tripData['time']);
    final origin = (tripData['origin'] ?? '').toString();
    final destination = (tripData['destination'] ?? '').toString();

    DateTime? tripDateTime;
    try {
      final parts = timeStr.split(':');
      if (parts.length == 2) {
        final hour = int.parse(parts[0]);
        final minute = int.parse(parts[1]);
        final dateParts = dateStr.split('-');
        if (dateParts.length == 3) {
          final year = int.parse(dateParts[0]);
          final month = int.parse(dateParts[1]);
          final day = int.parse(dateParts[2]);
          tripDateTime = DateTime(year, month, day, hour, minute);
        }
      }
    } catch (e) {}

    bool canCancel = true;
    String warningMessage = '';

    if (tripDateTime != null) {
      final now = DateTime.now();
      final minutesUntilTrip = tripDateTime.difference(now).inMinutes;

      if (minutesUntilTrip < 120) {
        canCancel = false;
        final hoursUntilTrip = minutesUntilTrip ~/ 60;
        final minsRemaining = minutesUntilTrip % 60;
        warningMessage = 'Cannot cancel within 2 hours of departure.\n'
            'Trip departs in ${hoursUntilTrip}h ${minsRemaining}m.';
      }
    }

    if (!canCancel) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cannot Cancel'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(warningMessage),
              const SizedBox(height: 12),
              const Text(
                'Cancellations must be made at least 2 hours before departure.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final priceRm = (priceSen / 100).toStringAsFixed(2);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this booking?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Seat: $seatNumber'),
            const SizedBox(height: 8),
            Text('Refund amount: RM $priceRm',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text(
              'The refund will be processed to your original payment method within 5-10 business days.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, cancel & refund'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => _busy = true);

    try {
      final driverTripRef = _trip!.reference;
      final t = _trip!.data() ?? {};
      final date = (t['date'] ?? '').toString();
      final time = (t['time'] ?? '').toString();

      // 1) Process refund
      if (paymentIntentId.isNotEmpty && priceSen > 0) {
        try {
          final fun = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
              .httpsCallable('refundPayment');

          final refundResp = await fun.call({
            'paymentIntentId': paymentIntentId,
            'amount': priceSen,
          });

          final refundData = Map<String, dynamic>.from(refundResp.data);
          final success = refundData['success'] == true;

          if (!success) {
            throw Exception('Refund failed');
          }

          await _seat!.reference.update({
            'refunded': true,
            'refundId': refundData['refundId'],
            'refundAmount': refundData['amount'],
            'refundedAt': FieldValue.serverTimestamp(),
          });

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Refund processed successfully'),
              backgroundColor: Colors.green,
            ),
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('⚠️ Refund failed: $e\nPlease contact support.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }


      // 2) Delete seat
      // 2) Delete seat
      await _seat!.reference.delete();

// 2.5) DELETE SCHEDULED NOTIFICATION using service
      try {
        debugPrint('🗑️ Deleting scheduled notification...');

        final notificationId = NotificationService.buildNotificationId(
          userId: user.uid,
          scheduleId: widget.tripId,
          date: dateStr,
        );

        await NotificationService().deleteScheduledNotification(notificationId);
      } catch (e) {
        debugPrint('❌ Error deleting scheduled notification: $e');
      }


      // 3) Send cancellation email
      try {
        final emailFun = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
            .httpsCallable('sendCancellationEmail');

        await emailFun.call({
          'email': studentEmail,
          'name': studentName,
          'origin': origin,
          'destination': destination,
          'date': dateStr,
          'time': timeStr,
          'seats': seatNumber,
          'refundAmount': priceRm,
        });

        debugPrint('✅ Cancellation email sent to $studentEmail');
      } catch (e) {
        debugPrint('⚠️ Cancellation email failed: $e');
      }

      // 4) Check remaining seats
      final myRemainingSeats = await _fs
          .collection('booked_seats')
          .where('studentId', isEqualTo: user.uid)
          .where('tripId', isEqualTo: driverTripRef.id)
          .limit(1)
          .get();

      if (myRemainingSeats.docs.isEmpty) {
        final bq = await _fs
            .collection('boardings')
            .where('tripId', isEqualTo: driverTripRef.id)
            .where('studentId', isEqualTo: user.uid)
            .get();
        if (bq.docs.isNotEmpty) {
          await _batchDelete(bq.docs.map((d) => d.reference).toList());
        }

        final scanRef = driverTripRef.collection('scans').doc(user.uid);
        final scan = await scanRef.get();
        if (scan.exists) await scanRef.delete();

        await _removeStudentMirrors(
          studentUid: user.uid,
          driverTripId: driverTripRef.id,
          origin: origin,
          destination: destination,
          date: date,
          time: time,
        );

        await _maybeDeleteEmptyDriverTrip(driverTripRef);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Booking cancelled & refund processed. Check your email.')),
        );
        Navigator.pop(context, true);
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Seat cancelled & refund processed. Check your email.')),
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