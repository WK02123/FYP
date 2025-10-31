// lib/pages/student_driver_live_page.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

/// StudentDriverLivePage
/// Shows LIVE driver location ONLY if the signed-in student has a valid booking
/// for today/soon. If no booking → shows an info card (no live pin).
///
/// Collections used (expected fields):
/// - student_trips: { studentId, origin, destination, date:"YYYY-MM-DD", time:"HH:mm" }
/// - driver_trips:  { driverId,  origin, destination, date:"YYYY-MM-DD", time:"HH:mm" }
///                   (optional: assignedDriverId is also OK; we try both)
/// - drivers:       { lat, lng, heading, status:"online"|"offline" }
class StudentDriverLivePage extends StatefulWidget {
  const StudentDriverLivePage({super.key});

  @override
  State<StudentDriverLivePage> createState() => _StudentDriverLivePageState();
}

class _StudentDriverLivePageState extends State<StudentDriverLivePage> {
  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  GoogleMapController? _map;

  // subscriptions
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _driverSub;

  // chosen context
  String? _driverId;
  String? _routeLabel; // "Origin → Destination @ HH:mm"

  // live driver state
  LatLng? _driverPos;
  double _bearing = 0;
  String _driverStatus = 'offline';

  // my location (optional for re-center)
  LatLng? _myPos;

  // ui state
  bool _loading = true;
  String? _error; // reason why we can't show live location
  bool _follow = true;

  final Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _driverSub?.cancel();
    _map?.dispose();
    super.dispose();
  }

  // ====== Bootstrap flow ======
  Future<void> _bootstrap() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        setState(() {
          _error = 'Please sign in first.';
          _loading = false;
        });
        return;
      }

      // 1) Locate the student's nearest upcoming (or just-started) trip
      final booking = await _pickStudentsNearestTrip(user.uid);
      if (booking == null) {
        setState(() {
          _error = 'No upcoming booking found. Live driver location is only available for your booked trip.';
          _loading = false;
        });
        return;
      }

      final origin = (booking['origin'] ?? '').toString();
      final destination = (booking['destination'] ?? '').toString();
      final date = (booking['date'] ?? '').toString();     // YYYY-MM-DD
      final time = (booking['time'] ?? '').toString();     // HH:mm or 12h
      _routeLabel = '$origin → $destination • $date $time';

      // 2) Resolve driverId for that exact trip
      final driverId = await _resolveDriverIdForTrip(origin, destination, date, time);
      if (driverId == null || driverId.isEmpty) {
        setState(() {
          _error = 'Your booked trip has no assigned driver yet. Please check again later.';
          _loading = false;
        });
        return;
      }

      // 3) Subscribe to the driver's live document
      _driverId = driverId;
      _subscribeDriverLive(driverId);

      // 4) (optional) get user's location for “center to me”
      _initMyLocation();

      setState(() {
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load: $e';
        _loading = false;
      });
    }
  }

  // ====== Student booking selection ======
  Future<Map<String, dynamic>?> _pickStudentsNearestTrip(String studentId) async {
    // You may want to limit to today or the next N days. Here we fetch today's & future (simple approach).
    // If your data volume grows, consider composite indexes and tighter time windows.

    // We'll pull today's + upcoming by date >= today, then pick the soonest time >= now (else latest past today).
    final today = _todayYmd();
    final now = DateTime.now();

    // Try: same-day first
    final sameDay = await _fs
        .collection('student_trips')
        .where('studentId', isEqualTo: studentId)
        .where('date', isEqualTo: today)
        .get();

    Map<String, dynamic>? chosen;
    DateTime? chosenTime;

    // 1) pick soonest time >= now for today
    for (final d in sameDay.docs) {
      final data = d.data();
      final dt = _todayAt(data['time']?.toString());
      if (dt == null) continue;
      if (!dt.isBefore(now) && (chosenTime == null || dt.isBefore(chosenTime!))) {
        chosen = data;
        chosenTime = dt;
      }
    }

    // 2) if none upcoming today, fallback to latest past today (maybe bus is still running)
    if (chosen == null && sameDay.docs.isNotEmpty) {
      DateTime? latestPast;
      Map<String, dynamic>? pick;
      for (final d in sameDay.docs) {
        final data = d.data();
        final dt = _todayAt(data['time']?.toString());
        if (dt == null) continue;
        if (dt.isBefore(now) && (latestPast == null || dt.isAfter(latestPast))) {
          latestPast = dt;
          pick = data;
        }
      }
      chosen = pick;
    }

    // 3) else check the nearest upcoming FUTURE date
    if (chosen == null) {
      final upcoming = await _fs
          .collection('student_trips')
          .where('studentId', isEqualTo: studentId)
          .where('date', isGreaterThanOrEqualTo: today)
          .orderBy('date')
          .limit(10)
          .get();

      DateTime? soonest;
      Map<String, dynamic>? pick;
      for (final d in upcoming.docs) {
        final data = d.data();
        // If it's today, use time; if future date, use midnight as comparator
        final candidate = data['date'] == today
            ? _todayAt(data['time']?.toString())
            : _ymdAtStartOfDay(data['date']?.toString());
        if (candidate == null) continue;
        if (soonest == null || candidate.isBefore(soonest)) {
          soonest = candidate;
          pick = data;
        }
      }
      chosen = pick;
    }

    return chosen;
  }

  // ====== Resolve driverId for the chosen (origin, destination, date, time) ======
  Future<String?> _resolveDriverIdForTrip(
      String origin,
      String destination,
      String date,
      String time,
      ) async {
    // First try: driver_trips matching O/D/date/time
    final best = await _fs
        .collection('driver_trips')
        .where('origin', isEqualTo: origin)
        .where('destination', isEqualTo: destination)
        .where('date', isEqualTo: date)
        .where('time', isEqualTo: time) // must match stored format
        .limit(1)
        .get();

    if (best.docs.isNotEmpty) {
      final data = best.docs.first.data();
      final driverId = (data['driverId'] ?? data['assignedDriverId'] ?? '').toString();
      if (driverId.isNotEmpty) return driverId;
    }

    // Fallback: if your system stores an assignedDriverId in student_trips, check that
    final st = await _fs
        .collection('student_trips')
        .where('origin', isEqualTo: origin)
        .where('destination', isEqualTo: destination)
        .where('date', isEqualTo: date)
        .where('time', isEqualTo: time)
        .limit(1)
        .get();

    if (st.docs.isNotEmpty) {
      final data = st.docs.first.data();
      final assigned = (data['driverId'] ?? data['assignedDriverId'] ?? '').toString();
      if (assigned.isNotEmpty) return assigned;
    }

    return null; // not assigned yet
  }

  // ====== Live driver subscription ======
  void _subscribeDriverLive(String driverId) {
    _driverSub?.cancel();
    _driverSub = _fs.collection('drivers').doc(driverId).snapshots().listen((snap) {
      if (!snap.exists) {
        setState(() {
          _driverStatus = 'offline';
          _driverPos = null;
          _markers.removeWhere((m) => m.markerId.value == 'driver_live');
        });
        return;
      }
      final data = snap.data()!;
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final heading = (data['heading'] as num?)?.toDouble() ?? 0.0;
      _driverStatus = (data['status'] ?? 'offline').toString();

      if (lat == null || lng == null) {
        setState(() {
          _driverPos = null;
          _markers.removeWhere((m) => m.markerId.value == 'driver_live');
        });
        return;
      }

      _driverPos = LatLng(lat, lng);
      _bearing = heading;

      // marker
      _markers
        ..removeWhere((m) => m.markerId.value == 'driver_live')
        ..add(
          Marker(
            markerId: const MarkerId('driver_live'),
            position: _driverPos!,
            rotation: _bearing,
            flat: true,
            anchor: const Offset(0.5, 0.5),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
            infoWindow: InfoWindow(
              title: 'Driver',
              snippet: 'Status: $_driverStatus',
            ),
          ),
        );

      // follow
      if (_map != null && _follow && _driverPos != null) {
        _map!.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: _driverPos!, zoom: 17, bearing: _bearing),
          ),
        );
      }

      setState(() {});
    });
  }

  // ====== Location helpers (for "center on me") ======
  Future<void> _initMyLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;

      final p = await Geolocator.getCurrentPosition();
      _myPos = LatLng(p.latitude, p.longitude);
      setState(() {});
    } catch (_) {}
  }

  // ====== Time helpers ======
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
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1].replaceAll(RegExp(r'[^0-9]'), ''));
    if (h == null || m == null) return null;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, h, m);
  }

  DateTime? _ymdAtStartOfDay(String? ymd) {
    if (ymd == null || ymd.isEmpty) return null;
    try {
      final dt = DateTime.parse(ymd);
      return DateTime(dt.year, dt.month, dt.day);
    } catch (_) {
      return null;
    }
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
    final initial = _driverPos ?? _myPos ?? const LatLng(5.3540, 100.3010); // Penang fallback

    return Scaffold(
      appBar: AppBar(
        title: const Text('Track My Bus'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          if (_driverPos != null)
            IconButton(
              tooltip: _follow ? 'Following' : 'Follow',
              icon: Icon(_follow ? Icons.navigation : Icons.navigation_outlined),
              onPressed: () {
                setState(() => _follow = !_follow);
                if (_follow && _driverPos != null) {
                  _map?.animateCamera(
                    CameraUpdate.newCameraPosition(
                      CameraPosition(target: _driverPos!, zoom: 17, bearing: _bearing),
                    ),
                  );
                }
              },
            ),
          if (_driverPos != null)
            IconButton(
              tooltip: 'Center on driver',
              icon: const Icon(Icons.directions_bus_filled),
              onPressed: () {
                if (_driverPos == null) return;
                _follow = true;
                _map?.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(target: _driverPos!, zoom: 17, bearing: _bearing),
                  ),
                );
                setState(() {});
              },
            ),
          IconButton(
            tooltip: 'Center on me',
            icon: const Icon(Icons.my_location),
            onPressed: _myPos == null
                ? null
                : () {
              _follow = false;
              _map?.animateCamera(CameraUpdate.newLatLngZoom(_myPos!, 16));
              setState(() {});
            },
          ),
        ],
      ),

      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: initial, zoom: 14),
            myLocationEnabled: _myPos != null,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            onMapCreated: (c) => _map = c,
            onCameraMoveStarted: () => setState(() => _follow = false),
            markers: _markers,
          ),

          // Top info bar (route + status or errors)
          Positioned(
            left: 12, right: 12, top: 12,
            child: Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: _loading
                    ? Row(
                  children: const [
                    SizedBox(
                      height: 18, width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Expanded(child: Text('Checking your booking and assigned driver…')),
                  ],
                )
                    : (_error != null)
                    ? Row(
                  children: [
                    const Icon(Icons.info, color: Colors.red),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_error!)),
                  ],
                )
                    : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _routeLabel ?? 'Your booked trip',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _driverPos == null
                          ? (_driverStatus == 'online'
                          ? 'Waiting for driver GPS…'
                          : 'Driver is offline or GPS not available yet.')
                          : 'Driver live • bearing ${_bearing.toStringAsFixed(0)}°',
                      style: TextStyle(
                        color: _driverPos == null ? Colors.orange : Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),

      floatingActionButton: _driverPos == null
          ? null
          : FloatingActionButton.extended(
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.center_focus_strong),
        label: const Text('Re-center'),
        onPressed: () {
          if (_driverPos == null) return;
          _follow = true;
          _map?.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(target: _driverPos!, zoom: 17, bearing: _bearing),
            ),
          );
          setState(() {});
        },
      ),
    );
  }
}
