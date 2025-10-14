// lib/pages/driver_scan_page.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Parsed payload structure (works for 12-part legacy, 8-part current, 6-part very old)
class ParsedPayload {
  final String tripRefOrField; // driverTripId OR driverTrips.tripId value
  final String studentId;
  final String? origin;
  final String? destination;
  final String dateStr;  // "YYYY-MM-DD"
  final String timeStr;  // "HH:mm" or "h:mm AM/PM"
  final List<String> seats;
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

  // ---------------------- small helpers ----------------------
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
    final m24 = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
    if (m24 != null) {
      final h = int.parse(m24.group(1)!);
      final mm = m24.group(2)!;
      return '${h.toString().padLeft(2, '0')}:$mm';
    }
    if (RegExp(r'(AM|PM)$', caseSensitive: false).hasMatch(s.replaceAll(' ', ''))) {
      final up = s.toUpperCase().replaceAll(' ', '');
      final am = up.endsWith('AM');
      final core = up.substring(0, up.length - 2); // "1:05" or "1"
      final parts = core.split(':');
      int h = int.tryParse(parts[0]) ?? 0;
      final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
      if (!am && h != 12) h += 12;
      if (am && h == 12) h = 0;
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    }
    return s;
  }
  bool _timeEqualLoose(String a, String b) => _to24(a) == _to24(b);

  // ---------------------- QR parse (supports 12/8/6) ----------------------
  ParsedPayload? _parsePayloadFlexible(String raw) {
    final parts = raw.split('|');
    if (parts.isEmpty || parts[0] != 'RIDEMATE') return null;

    // 12-part legacy you showed:
    // RIDEMATE|<driverTripId>|Relau|INTIPenang|2025-10-14|19:00|<studentId>|Relau|INTI Penang|2025-10-14|19:00|B2
    if (parts.length >= 12) {
      return ParsedPayload(
        tripRefOrField: parts[1].trim(),
        studentId: parts[6].trim(),
        origin: parts[2].trim(),
        destination: parts[3].trim(),
        dateStr: parts[4].trim(),
        timeStr: parts[5].trim(),
        seats: [parts[11].trim()],
      );
    }

    // 8-part (current):
    // RIDEMATE|driverTripId|studentId|origin|destination|date|time|seat
    if (parts.length >= 8) {
      final seat = parts[7].trim();
      return ParsedPayload(
        tripRefOrField: parts[1].trim(),
        studentId: parts[2].trim(),
        origin: parts[3].trim(),
        destination: parts[4].trim(),
        dateStr: parts[5].trim(),
        timeStr: parts[6].trim(),
        seats: seat.isEmpty ? [] : [seat],
      );
    }

    // 6-part (very old)
    // RIDEMATE|trip|student|date|time|A1,A2
    if (parts.length >= 6) {
      final seats = parts[5]
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
      );
    }

    return null;
  }

  // ---------------------- Resolver 1: via booked_seats ----------------------
  Future<DocumentSnapshot<Map<String, dynamic>>?> _resolveViaBookedSeats(
      ParsedPayload p,
      String driverUid,
      ) async {
    final seatsForDay = await _fs
        .collection('booked_seats')
        .where('studentId', isEqualTo: p.studentId)
        .where('date', isEqualTo: p.dateStr)
        .get();

    if (seatsForDay.docs.isEmpty) return null;

    final wantSeat = p.seats.isNotEmpty ? p.seats.first : null;

    // Try strict match: route + time + (seat)
    for (final d in seatsForDay.docs) {
      final bs = d.data();
      final originOk = p.origin == null || _norm(bs['origin']) == _norm(p.origin);
      final destOk   = p.destination == null || _norm(bs['destination']) == _norm(p.destination);
      final timeOk   = bs['time'] != null && _timeEqualLoose(bs['time'].toString(), p.timeStr);
      final seatOk   = wantSeat == null || (bs['seatNumber']?.toString() == wantSeat);
      if (originOk && destOk && timeOk && seatOk) {
        final driverTripId = (bs['tripId'] ?? '').toString();
        if (driverTripId.isEmpty) continue;
        final tripSnap = await _fs.collection('driver_trips').doc(driverTripId).get();
        if (tripSnap.exists && (tripSnap.data()?['driverId'] ?? '') == driverUid) {
          return tripSnap;
        }
      }
    }

    // Fallback: first driver-owned seat that day
    for (final d in seatsForDay.docs) {
      final driverTripId = (d.data()['tripId'] ?? '').toString();
      if (driverTripId.isEmpty) continue;
      final tripSnap = await _fs.collection('driver_trips').doc(driverTripId).get();
      if (tripSnap.exists && (tripSnap.data()?['driverId'] ?? '') == driverUid) {
        return tripSnap;
      }
    }

    return null;
  }

  // ---------------------- Resolver 2: search driver_trips ----------------------
  Future<DocumentSnapshot<Map<String, dynamic>>?> _findTripAfterScan(
      ParsedPayload p,
      String driverUid,
      ) async {
    final trips = _fs.collection('driver_trips');

    // A) direct by docId
    final byId = await trips.doc(p.tripRefOrField).get();
    if (byId.exists && (byId.data()?['driverId'] ?? '') == driverUid) {
      return byId;
    }

    // B) by field tripId
    final byField = await trips.where('tripId', isEqualTo: p.tripRefOrField).limit(1).get();
    if (byField.docs.isNotEmpty) {
      final d = byField.docs.first;
      if ((d.data()['driverId'] ?? '') == driverUid) return d;
    }

    // C) match on route/date/time
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

    // D) last resort: scan ALL driver_trips
    final allTrips = await trips.get();
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

  // ---------------------- mark seats boarded in booked_seats ----------------------
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
        debugPrint('booked_seats row not found: trip=$driverTripId student=$studentId seat=$seat');
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

  // ---------------------- handle scan ----------------------
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

      // 1) best path: via booked_seats
      DocumentSnapshot<Map<String, dynamic>>? tripSnap =
      await _resolveViaBookedSeats(parsed, driver.uid);

      // 2) fallback resolver
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

      // /driver_trips/{trip}/scans/{student}
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

      // mark seats so the driver seat page updates live
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

  // ---------------------- UI ----------------------
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
            Positioned(left: 16, right: 16, bottom: 24, child: _Banner(text: _lastSuccess!, ok: true)),
          if (_lastError != null)
            Positioned(left: 16, right: 16, bottom: 24, child: _Banner(text: _lastError!, ok: false)),
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
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
      ),
    );
  }
}
