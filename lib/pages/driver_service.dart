// lib/pages/driver_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';

class DriverService {
  DriverService._();
  static final instance = DriverService._();

  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  StreamSubscription<Position>? _posSub;

  // Cache the latest busCode so we can publish it with location updates
  String? _busCodeCached;

  // ----------------- Helpers -----------------
  String _todayYmd() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  DateTime? _todayAt(String? hhmm) {
    if (hhmm == null || !hhmm.contains(':')) return null;
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, h, m);
  }

  String? _uid() => _auth.currentUser?.uid;
  String? _email() => _auth.currentUser?.email;

  // ----------------- Driver Profile -----------------
  Stream<DocumentSnapshot<Map<String, dynamic>>> driverStream() {
    final uid = _uid();
    if (uid == null) return const Stream.empty();
    return _fs.collection('drivers').doc(uid).snapshots();
  }

  Future<void> updateDriver({
    String? name,
    String? phone,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');

    await _fs.collection('drivers').doc(uid).set({
      if (name != null) 'name': name,
      if (phone != null) 'phone': phone,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ----------------- Trip & Seats -----------------
  Stream<QuerySnapshot<Map<String, dynamic>>> todayTrips() {
    final uid = _uid()!;
    final ymd = _todayYmd();
    return _fs
        .collection('driver_trips')
        .where('driverId', isEqualTo: uid)
        .where('date', isEqualTo: ymd)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> seatsForTrip(String tripId) {
    return _fs
        .collection('booked_seats')
        .where('tripId', isEqualTo: tripId)
        .snapshots();
  }

  // ----------------- Issue Reporting -----------------
  Future<void> reportIssue({
    required String type,
    String? note,
    String? tripId,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');

    await _fs.collection('issues').add({
      'type': type,
      'note': (note ?? '').trim(),
      'driverId': uid,
      'driverEmail': _email(),
      'tripId': tripId,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> reportIssueAndNotify({
    required String type,
    String? note,
    int? delayMinutes,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');

    await reportIssue(type: type, note: note);

    final ymd = _todayYmd();
    final qs = await _fs
        .collection('driver_trips')
        .where('driverId', isEqualTo: uid)
        .where('date', isEqualTo: ymd)
        .get();

    if (qs.docs.isEmpty) return;

    final now = DateTime.now();
    Map<String, dynamic>? chosen;
    DateTime? chosenTime;

    for (final d in qs.docs) {
      final data = d.data();
      final dt = _todayAt(data['time']?.toString());
      if (dt == null) continue;
      if (!dt.isBefore(now) &&
          (chosenTime == null || dt.isBefore(chosenTime!))) {
        chosen = data;
        chosenTime = dt;
      }
    }

    chosen ??= (() {
      DateTime? latest;
      Map<String, dynamic>? pick;
      for (final d in qs.docs) {
        final data = d.data();
        final dt = _todayAt(data['time']?.toString());
        if (dt == null) continue;
        if (latest == null || dt.isAfter(latest)) {
          latest = dt;
          pick = data;
        }
      }
      return pick;
    })();

    if (chosen == null) return;

    final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
        .httpsCallable('reportDriverIssue');

    await callable.call(<String, dynamic>{
      'origin': chosen['origin'] ?? '',
      'destination': chosen['destination'] ?? '',
      'date': chosen['date'] ?? ymd,
      'time': chosen['time'] ?? '',
      'type': type,
      'note': (note ?? '').trim(),
      'delayMinutes': delayMinutes ?? 0,
    });
  }

  // ----------------- Live Location Sharing -----------------
  Future<void> _ensurePerms() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) throw 'Please enable location services';

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      throw 'Location permission denied';
    }
  }

  Future<void> startSharingLocation() async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');
    await _ensurePerms();

    // Read current driver doc to cache busCode (if any)
    try {
      final snap = await _fs.collection('drivers').doc(uid).get();
      _busCodeCached = (snap.data()?['busCode'] ?? '').toString().trim().isEmpty
          ? null
          : (snap.data()?['busCode'] as String);
    } catch (_) {
      _busCodeCached = null;
    }

    // Mark online immediately (keeps existing busCode if present)
    await _fs.collection('drivers').doc(uid).set({
      'status': 'online',
      'active': true,
      if (_busCodeCached != null) 'busCode': _busCodeCached,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5, // every 5m
      ),
    ).listen((pos) async {
      // ignore: avoid_print
      print(
          '📍 Driver GPS = ${pos.latitude}, ${pos.longitude}, heading=${pos.heading}');
      try {
        await _fs.collection('drivers').doc(uid).set({
          'lat': pos.latitude,
          'lng': pos.longitude,
          'pos': GeoPoint(pos.latitude, pos.longitude),
          'heading': pos.heading,
          'status': 'online',
          'active': true,
          if (_busCodeCached != null) 'busCode': _busCodeCached,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}
    });
  }

  Future<void> stopSharingLocation() async {
    final uid = _uid();
    await _posSub?.cancel();
    _posSub = null;

    if (uid == null) return;
    await _fs.collection('drivers').doc(uid).set({
      'status': 'offline',
      'active': false,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> disposeSharing() async {
    await _posSub?.cancel();
    _posSub = null;
  }

  // ----------------- Leave Requests -----------------
  Future<void> requestLeave({
    required DateTime from,
    required DateTime to,
    required String reason,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');
    if (to.isBefore(from)) throw Exception('Invalid date range.');

    await _fs.collection('leave_requests').add({
      'driverId': uid,
      'driverEmail': _email(),        // optional – useful for debugging
      'from': Timestamp.fromDate(from),
      'to': Timestamp.fromDate(to),
      'reason': reason,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
