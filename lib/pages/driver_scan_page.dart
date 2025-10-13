// lib/pages/driver_scan_page.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../utils/time_utils.dart';


/// Unified payload parsed from QR (supports 8-part and legacy 6-part)
class ParsedPayload {
  final String tripRefOrField; // may be trips docId OR value stored in trips.tripId
  final String studentId;
  final String? origin;        // present for 8-part payload
  final String? destination;   // present for 8-part payload
  final String dateStr;        // "YYYY-MM-DD"
  final String timeStr;        // "HH:mm" OR "h:mm AM/PM"
  final List<String> seats;    // at least one seat

  ParsedPayload({
    required this.tripRefOrField,
    required this.studentId,
    required this.dateStr,
    required this.timeStr,
    required this.seats,
    this.origin,
    this.destination,
  });
}

class DriverScanPage extends StatefulWidget {
  const DriverScanPage({super.key});
  @override
  State<DriverScanPage> createState() => _DriverScanPageState();
}

class _DriverScanPageState extends State<DriverScanPage> {
  final _auth = FirebaseAuth.instance;
  final _fs = FirebaseFirestore.instance;

  bool _handling = false;
  String? _lastError;
  String? _lastSuccess;

  final MobileScannerController controller = MobileScannerController(
    facing: CameraFacing.back,
    detectionSpeed: DetectionSpeed.noDuplicates,
    torchEnabled: false,
    formats: const [BarcodeFormat.qrCode],
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _showSnack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null),
    );
  }

  // ---------- helpers ----------
  String _norm(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'\s+'), '');
  String _fmtDate(dynamic v) {
    if (v == null) return '';
    if (v is Timestamp) {
      final d = v.toDate();
      return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    return v.toString().trim();
  }
  String _fmtTime(dynamic v) {
    if (v == null) return '';
    if (v is Timestamp) {
      final d = v.toDate();
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return v.toString().trim();
  }

  String _to24(String t) {
    final s = t.trim();
    if (RegExp(r'^\d{1,2}:\d{2}\s*(AM|PM)$', caseSensitive: false).hasMatch(s)) {
      final ampm = s.toUpperCase().endsWith('AM') ? 'AM' : 'PM';
      final hm = s.replaceAll(RegExp(r'\s*(AM|PM)', caseSensitive: false), '');
      final parts = hm.split(':');
      var h = int.tryParse(parts[0]) ?? 0;
      final m = parts[1];
      if (ampm == 'AM') {
        if (h == 12) h = 0;
      } else {
        if (h != 12) h += 12;
      }
      return '${h.toString().padLeft(2, '0')}:$m';
    }
    return s;
  }

  bool _timeEqualLoose(String a, String b) => to24h(a) == to24h(b);


  // ---------- parse QR ----------
  ParsedPayload? _parsePayloadFlexible(String raw) {
    final parts = raw.split('|');
    if (parts.isEmpty || parts[0] != 'RIDEMATE') return null;

    // 8-part (preferred)
    if (parts.length >= 8) {
      final seatName = parts[7].trim();
      return ParsedPayload(
        tripRefOrField: parts[1].trim(),
        studentId: parts[2].trim(),
        origin: parts[3].trim(),
        destination: parts[4].trim(),
        dateStr: parts[5].trim(),
        timeStr: parts[6].trim(),
        seats: seatName.isEmpty ? [] : [seatName],
      );
    }

    // 6-part (legacy)
    if (parts.length >= 6) {
      final seatsCsv = parts[5].trim();
      final seats = seatsCsv
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return ParsedPayload(
        tripRefOrField: parts[1].trim(),
        studentId: parts[2].trim(),
        dateStr: parts[3].trim(),
        timeStr: parts[4].trim(),
        seats: seats,
        origin: null,
        destination: null,
      );
    }
    return null;
  }

  // ---------- 1) BEST PATH: resolve via booked_seats ----------
  Future<DocumentSnapshot<Map<String, dynamic>>?> _resolveViaBookedSeats(
      ParsedPayload p,
      String driverUid,
      ) async {
    // Search student's booked seats for that date
    final q = await _fs
        .collection('booked_seats')
        .where('studentId', isEqualTo: p.studentId)
        .where('date', isEqualTo: p.dateStr)
        .get();

    if (q.docs.isEmpty) return null;

    // Prefer rows that match seat + route + time (loose 12/24h)
    String? wantSeat = p.seats.isNotEmpty ? p.seats.first : null;
    for (final d in q.docs) {
      final bs = d.data();
      final originOk = p.origin == null || _norm(bs['origin']) == _norm(p.origin);
      final destOk   = p.destination == null || _norm(bs['destination']) == _norm(p.destination);
      final timeOk   = bs['time'] != null && _timeEqualLoose(bs['time'].toString(), p.timeStr);
      final seatOk   = wantSeat == null || (bs['seatNumber']?.toString() == wantSeat);
      if (originOk && destOk && timeOk && seatOk) {
        final driverTripId = (bs['tripId'] ?? '').toString();
        if (driverTripId.isEmpty) continue;
        final tripSnap = await _fs.collection('trips').doc(driverTripId).get();
        if (tripSnap.exists && (tripSnap.data()?['driverId'] ?? '') == driverUid) {
          return tripSnap;
        }
      }
    }

    // If strict match didn't work, return first driver-owned trip for that date
    for (final d in q.docs) {
      final driverTripId = (d.data()['tripId'] ?? '').toString();
      if (driverTripId.isEmpty) continue;
      final tripSnap = await _fs.collection('trips').doc(driverTripId).get();
      if (tripSnap.exists && (tripSnap.data()?['driverId'] ?? '') == driverUid) {
        return tripSnap;
      }
    }
    return null;
  }

  // ---------- 2) fallbacks from your previous resolver ----------
  Future<DocumentSnapshot<Map<String, dynamic>>?> _findTripAfterScan(
      ParsedPayload p,
      String driverUid,
      ) async {
    final trips = _fs.collection('trips');

    // Try A: direct by docId
    final byId = await trips.doc(p.tripRefOrField).get();
    if (byId.exists) {
      final t = byId.data() ?? {};
      final isThisDriver = (t['driverId'] ?? '').toString() == driverUid;
      if (isThisDriver) return byId;

      // Map student trip -> driver trip
      final looksLikeStudent = t.containsKey('studentId') || t.containsKey('studentEmail') || t.containsKey('createdBy');
      if (looksLikeStudent) {
        final origin = _norm(t['origin']?.toString());
        final dest   = _norm(t['destination']?.toString());
        final date   = _fmtDate(t['date']);
        final time   = _fmtTime(t['time'] ?? t['time12']);

        final q = await trips
            .where('driverId', isEqualTo: driverUid)
            .where('origin', isEqualTo: t['origin'])
            .where('destination', isEqualTo: t['destination'])
            .get();

        for (final d in q.docs) {
          final dt = d.data();
          if (_fmtDate(dt['date']) == date &&
              _timeEqualLoose(_fmtTime(dt['time'] ?? dt['time12']), time) &&
              _norm(dt['origin']?.toString()) == origin &&
              _norm(dt['destination']?.toString()) == dest) {
            return d;
          }
        }

        final allForDriver = await trips.where('driverId', isEqualTo: driverUid).get();
        for (final d in allForDriver.docs) {
          final dt = d.data();
          if (_fmtDate(dt['date']) == date &&
              _timeEqualLoose(_fmtTime(dt['time'] ?? dt['time12']), time) &&
              _norm(dt['origin']?.toString()) == origin &&
              _norm(dt['destination']?.toString()) == dest) {
            return d;
          }
        }
      }
    }

    // Try B: trips.tripId == QR value
    final byField = await trips.where('tripId', isEqualTo: p.tripRefOrField).limit(1).get();
    if (byField.docs.isNotEmpty) {
      final d = byField.docs.first;
      final t = d.data();
      if ((t['driverId'] ?? '').toString() == driverUid) return d;

      if (t.containsKey('studentId') || t.containsKey('studentEmail') || t.containsKey('createdBy')) {
        final origin = _norm(t['origin']?.toString());
        final dest   = _norm(t['destination']?.toString());
        final date   = _fmtDate(t['date']);
        final time   = _fmtTime(t['time'] ?? t['time12']);

        final allForDriver = await trips.where('driverId', isEqualTo: driverUid).get();
        for (final m in allForDriver.docs) {
          final mt = m.data();
          if (_fmtDate(mt['date']) == date &&
              _timeEqualLoose(_fmtTime(mt['time'] ?? mt['time12']), time) &&
              _norm(mt['origin']?.toString()) == origin &&
              _norm(mt['destination']?.toString()) == dest) {
            return m;
          }
        }

        if ((t['driverId'] ?? '').toString() == driverUid) return d;
      }
    }

    // Try C: by route/date/time from QR
    final wantOrigin = _norm(p.origin);
    final wantDest   = _norm(p.destination);
    final wantDate   = p.dateStr;
    final wantTime   = p.timeStr;

    final allForDriver = await trips.where('driverId', isEqualTo: driverUid).get();
    final matches = allForDriver.docs.where((doc) {
      final t = doc.data();
      final dOrigin = _norm(t['origin']?.toString());
      final dDest   = _norm(t['destination']?.toString());
      final dDate   = _fmtDate(t['date']);
      final dTime   = _fmtTime(t['time'] ?? t['time12']);
      return (wantOrigin.isEmpty || dOrigin == wantOrigin) &&
          (wantDest.isEmpty   || dDest   == wantDest)   &&
          (dDate == wantDate) &&
          _timeEqualLoose(dTime, wantTime);
    }).toList();

    if (matches.isNotEmpty) return matches.first;

    // Last resort: scan ALL trips (loose time compare) – prefer this driver
    final allTrips = await trips.get();
    allTrips.docs.sort((a, b) {
      final ad = (a.data()['driverId'] ?? '').toString() == driverUid ? 0 : 1;
      final bd = (b.data()['driverId'] ?? '').toString() == driverUid ? 0 : 1;
      return ad.compareTo(bd);
    });
    for (final d in allTrips.docs) {
      final t = d.data();
      final dOrigin = _norm(t['origin']?.toString());
      final dDest   = _norm(t['destination']?.toString());
      final dDate   = _fmtDate(t['date']);
      final dTime   = _fmtTime(t['time'] ?? t['time12']);
      if ((wantOrigin.isEmpty || dOrigin == wantOrigin) &&
          (wantDest.isEmpty   || dDest   == wantDest)   &&
          dDate == wantDate &&
          _timeEqualLoose(dTime, wantTime)) {
        return d;
      }
    }

    return null;
  }

  // ---------- mark seats boarded in /booked_seats ----------
  Future<void> _markSeatsBoarded({
    required String driverTripId,
    required String studentId,
    required List<String> seats,
  }) async {
    for (final seat in seats) {
      final q = await _fs.collection('booked_seats')
          .where('tripId', isEqualTo: driverTripId)
          .where('studentId', isEqualTo: studentId)
          .where('seatNumber', isEqualTo: seat)
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        debugPrint('booked_seats not found for trip=$driverTripId student=$studentId seat=$seat');
        continue;
      }

      await q.docs.first.reference.set({
        'status': 'boarded',
        'boardedAt': FieldValue.serverTimestamp(),
        'boardedBy': _auth.currentUser?.uid,
        'locked': true,
      }, SetOptions(merge: true));
    }
  }

  // ---------- handle scan ----------
  Future<void> _handleScan(String raw) async {
    if (_handling) return;
    setState(() {
      _handling = true;
      _lastError = null;
      _lastSuccess = null;
    });

    try {
      final driver = _auth.currentUser;
      if (driver == null) throw Exception('Not signed in as driver.');

      final parsed = _parsePayloadFlexible(raw);
      if (parsed == null) throw Exception('Invalid QR payload.');

      // NEW: go to booked_seats first
      DocumentSnapshot<Map<String, dynamic>>? tripSnap =
      await _resolveViaBookedSeats(parsed, driver.uid);

      // fallback to previous resolver if needed
      tripSnap ??= await _findTripAfterScan(parsed, driver.uid);

      if (tripSnap == null || !tripSnap.exists) {
        throw Exception('No trips found for this QR.');
      }

      final t = tripSnap.data() ?? {};
      if ((t['driverId'] ?? '').toString() != driver.uid) {
        throw Exception('This trip is not assigned to you.');
      }

      final now = FieldValue.serverTimestamp();
      final boardedDocId = '${tripSnap.id}|${parsed.studentId}';

      final batch = _fs.batch();

      // /boardings
      batch.set(
        _fs.collection('boardings').doc(boardedDocId),
        {
          'tripId': tripSnap.id,
          'driverId': driver.uid,
          'studentId': parsed.studentId,
          'date': parsed.dateStr,
          'time': parsed.timeStr,
          'seats': parsed.seats,
          'boardedAt': now,
          'locked': true,
        },
        SetOptions(merge: true),
      );

      // /trips/{driverTrip}/scans/{student}
      batch.set(
        tripSnap.reference.collection('scans').doc(parsed.studentId),
        {
          'studentId': parsed.studentId,
          'seats': parsed.seats,
          'boardedAt': now,
          'locked': true,
        },
        SetOptions(merge: true),
      );

      await batch.commit();

      // Mark seats so the schedule/seat page updates live
      final seatList = parsed.seats.isNotEmpty ? parsed.seats : ['?'];
      await _markSeatsBoarded(
        driverTripId: tripSnap.id,
        studentId: parsed.studentId,
        seats: seatList,
      );

      setState(() {
        _lastSuccess = 'Boarded & locked: ${parsed.studentId} (${seatList.join(", ")})';
      });
      _showSnack('Boarded successfully');

      await controller.stop();
      await Future.delayed(const Duration(milliseconds: 700));
      await controller.start();
    } catch (e) {
      setState(() => _lastError = e.toString());
      _showSnack(_lastError!, error: true);
      await controller.stop();
      await Future.delayed(const Duration(milliseconds: 700));
      await controller.start();
    } finally {
      if (mounted) setState(() => _handling = false);
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan QR'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flash_on),
            onPressed: () => controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Camera',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              final codes = capture.barcodes;
              if (codes.isEmpty) return;
              final raw = codes.first.rawValue ?? '';
              if (raw.isEmpty) return;
              _handleScan(raw);
            },
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white70, width: 2),
                ),
              ),
            ),
          ),
          if (_lastSuccess != null)
            Positioned(
              left: 16, right: 16, bottom: 24,
              child: _Banner(text: _lastSuccess!, ok: true),
            ),
          if (_lastError != null)
            Positioned(
              left: 16, right: 16, bottom: 24,
              child: _Banner(text: _lastError!, ok: false),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final bool ok;
  const _Banner({required this.text, required this.ok});

  @override
  Widget build(BuildContext context) {
    final Color bg = (ok ? Colors.green : Colors.red).withOpacity(0.9);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
      ),
    );
  }
}
