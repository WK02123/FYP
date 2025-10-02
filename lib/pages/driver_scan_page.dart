import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Expected QR payload created in BookingQrPage:
/// RIDEMATE|<tripId>|<studentId>|<date YYYY-MM-DD>|<time HH:mm>|<seats comma-separated>
/// Example:
/// RIDEMATE|uid|Relau|INTIPenang|2025-10-10|07:00|A1,A2
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

  MobileScannerController controller = MobileScannerController(
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

  Map<String, String>? _parsePayload(String raw) {
    // RIDEMATE|tripId|studentId|date|time|seats
    final parts = raw.split('|');
    if (parts.length < 6) return null;
    if (parts[0] != 'RIDEMATE') return null;
    return {
      'tripId': parts[1],
      'studentId': parts[2],
      'date': parts[3],
      'time': parts[4],
      'seats': parts[5], // comma separated
    };
  }

  Future<void> _handleScan(String payload) async {
    if (_handling) return;
    setState(() {
      _handling = true;
      _lastError = null;
      _lastSuccess = null;
    });

    try {
      final driver = _auth.currentUser;
      if (driver == null) throw Exception('Not signed in as driver.');

      final map = _parsePayload(payload);
      if (map == null) throw Exception('Invalid QR payload.');

      final tripId = map['tripId']!;
      final studentId = map['studentId']!;
      final date = map['date']!;
      final time = map['time']!;
      final seatsCsv = map['seats']!;
      final seats = seatsCsv.split(',').where((s) => s.trim().isNotEmpty).toList();

      // 1) Load trip
      final tripSnap = await _fs.collection('trips').doc(tripId).get();
      if (!tripSnap.exists) {
        throw Exception('Trip not found.');
      }
      final trip = tripSnap.data()!;
      final tripDriverId = (trip['driverId'] ?? '').toString();

      // 2) Verify this driver is allowed to board this trip
      if (tripDriverId.isEmpty || tripDriverId != driver.uid) {
        throw Exception('This booking is not assigned to you.');
      }

      // 3) Optional: check date/time not in the past (soft warning)
      final dt = DateTime.tryParse('${date}T${time.padLeft(5, '0')}:00');
      if (dt != null && dt.isBefore(DateTime.now().subtract(const Duration(hours: 1)))) {
        // Not fatal; you can choose to reject if you want.
        // throw Exception('This trip appears to be in the past.');
      }

      // 4) Write boarding record (idempotent by student)
      // Store both top-level and subcollection for easy queries
      final boardedDocId = '$tripId|$studentId';
      final now = FieldValue.serverTimestamp();

      final batch = _fs.batch();

      // top-level collection
      final topRef = _fs.collection('boardings').doc(boardedDocId);
      batch.set(topRef, {
        'tripId': tripId,
        'driverId': driver.uid,
        'studentId': studentId,
        'date': date,
        'time': time,
        'seats': seats,
        'boardedAt': now,
      }, SetOptions(merge: true));

      // nested under trip
      final nestedRef = _fs.collection('trips').doc(tripId)
          .collection('scans').doc(studentId);
      batch.set(nestedRef, {
        'studentId': studentId,
        'seats': seats,
        'boardedAt': now,
      }, SetOptions(merge: true));

      // (Optional) mark trip status or increment counters, etc.

      await batch.commit();

      setState(() {
        _lastSuccess = 'Boarded: $studentId  (${seats.join(", ")})';
      });
      _showSnack('Boarded successfully');

      // Briefly pause scanning so we don't double-read the same QR
      await controller.stop();
      await Future.delayed(const Duration(seconds: 1));
      await controller.start();
    } catch (e) {
      setState(() => _lastError = e.toString());
      _showSnack(_lastError!, error: true);
      // stop briefly to avoid duplicate scans after error
      await controller.stop();
      await Future.delayed(const Duration(milliseconds: 800));
      await controller.start();
    } finally {
      if (mounted) setState(() => _handling = false);
    }
  }

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

          // Simple overlay
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
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ok ? Colors.green.withOpacity(.9) : Colors.red.withOpacity(.9),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
