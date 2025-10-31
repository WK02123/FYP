// lib/pages/gps_map_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';

/// -------- Auth helper (ensures we can read under your rules) --------
Future<void> _ensureSignedIn() async {
  final auth = FirebaseAuth.instance;
  if (auth.currentUser == null) {
    await auth.signInAnonymously();
  }
}

class GpsMapPage extends StatefulWidget {
  const GpsMapPage({super.key});

  @override
  State<GpsMapPage> createState() => _GpsMapPageState();
}

class _GpsMapPageState extends State<GpsMapPage> {
  final _fs = FirebaseFirestore.instance;

  GoogleMapController? _controller;
  LatLng? _myPos;

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  StreamSubscription<QuerySnapshot>? _routesSub;
  StreamSubscription<QuerySnapshot>? _driversSub;

  // Only used when a route doc has no saved polyline
  static const String _directionsKey = 'YOUR_GOOGLE_KEY_HERE';

  String? _summary; // distance • duration

  // Marker icons
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  BitmapDescriptor? _carIcon;

  // Route cache + current active route key
  final Map<String, _RouteDoc> _routeIndex = {};
  String? _activeRouteKey;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _ensureSignedIn();               // 👈 important for your Firestore rules
    await _loadMarkerIcons();
    await _initLocation();
    _subscribeRoutes();
    _subscribeAllOnlineDrivers();          // 👈 shows live buses
  }

  @override
  void dispose() {
    _routesSub?.cancel();
    _driversSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _loadMarkerIcons() async {
    try {
      _pickupIcon = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/map/pin_pickup.png',
      );
      _dropIcon = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/map/pin_drop.png',
      );
      _carIcon = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(96, 96)),
        'assets/map/car.png',
      );
    } catch (_) {
      _pickupIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
      _dropIcon   = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose);
      _carIcon    = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    }
    if (mounted) setState(() {});
  }

  // ---- User location ----
  Future<void> _initLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) { _snack('Please enable GPS/location services'); return; }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      _snack('Location permission denied. Enable it in settings.');
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _myPos = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {});
      _controller?.animateCamera(CameraUpdate.newLatLngZoom(_myPos!, 15));
    } catch (e) {
      _snack('Failed to get location: $e');
    }
  }

  // ================== ROUTES SNAPSHOT ==================
  void _subscribeRoutes() {
    _routesSub = _fs.collection('routes').snapshots().listen((snap) async {
      // Keep non-route markers (drivers & active pins)
      final keep = _markers.where((m) =>
      !m.markerId.value.startsWith('route_o_') &&
          !m.markerId.value.startsWith('route_d_')).toList();

      final routeMarkers = <Marker>{};
      _routeIndex.clear();

      for (final d in snap.docs) {
        final data = d.data() as Map<String, dynamic>;
        final key = d.id;

        final originGp = data['origin'] as GeoPoint?;
        final destGp   = data['destination'] as GeoPoint?;
        if (originGp == null || destGp == null) continue;

        final r = _RouteDoc(
          key: key,
          origin: LatLng(originGp.latitude, originGp.longitude),
          destination: LatLng(destGp.latitude, destGp.longitude),
          originName: (data['originName'] ?? 'Origin').toString(),
          destinationName: (data['destinationName'] ?? 'Destination').toString(),
          polyline: (data['polyline'] ?? '').toString(),
          distanceMeters: (data['distance_meters'] as num?)?.toInt(),
          durationSeconds: (data['duration_seconds'] as num?)?.toInt(),
        );
        _routeIndex[key] = r;

        if (_activeRouteKey == key) continue; // avoid duplicate pins

        routeMarkers.add(
          Marker(
            markerId: MarkerId('route_o_$key'),
            position: r.origin,
            icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
            infoWindow: InfoWindow(title: r.originName, snippet: 'Tap to view route'),
            onTap: () => _showRoute(r),
          ),
        );
        routeMarkers.add(
          Marker(
            markerId: MarkerId('route_d_$key'),
            position: r.destination,
            icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
            infoWindow: InfoWindow(title: r.destinationName, snippet: 'Tap to view route'),
            onTap: () => _showRoute(r),
          ),
        );
      }

      setState(() {
        _markers
          ..clear()
          ..addAll(keep)
          ..addAll(routeMarkers);
      });

      // If active route doc changed, re-apply its polyline/pins
      if (_activeRouteKey != null && _routeIndex[_activeRouteKey!] != null) {
        _applyActiveRoute(_routeIndex[_activeRouteKey!]!, keepViewport: true);
      }
    }, onError: (e) {
      _snack('Routes stream error: $e');
    });
  }

  // ================== LIVE DRIVERS (supports active:true or status:"online", lat/lng or pos) ==================
  void _subscribeAllOnlineDrivers() {
    _driversSub = _fs
        .collection('drivers')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen((snap) async {
      if (snap.docs.isEmpty) {
        // Fallback to the other schema once
        try {
          final alt = await _fs.collection('drivers').where('status', isEqualTo: 'online').get();
          _applyDriverDocs(alt.docs);
        } catch (e) {
          _snack('Drivers (fallback) error: $e');
        }
      } else {
        _applyDriverDocs(snap.docs);
      }
    }, onError: (e) {
      _snack('Drivers stream error: $e'); // will show permission errors here
    });
  }

  void _applyDriverDocs(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    _markers.removeWhere((m) => m.markerId.value.startsWith('drv_'));

    for (final doc in docs) {
      final d = doc.data();
      // Accept doubles or GeoPoint
      double? lat = (d['lat'] as num?)?.toDouble();
      double? lng = (d['lng'] as num?)?.toDouble();
      final posGp = d['pos'];
      if ((lat == null || lng == null) && posGp is GeoPoint) {
        lat = posGp.latitude;
        lng = posGp.longitude;
      }
      if (lat == null || lng == null) continue;

      final busCode = (d['busCode'] ?? 'Bus').toString();
      final routeLabel = await _resolveDriverRouteLabel(doc.id, d);

      _markers.add(
        Marker(
          markerId: MarkerId('drv_${doc.id}'),
          position: LatLng(lat, lng),
          flat: true,
          anchor: const Offset(0.5, 0.5),
          icon: _carIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: InfoWindow(title: '🚌 $busCode', snippet: routeLabel),
        ),
      );
    }
    if (mounted) setState(() {});
  }

  Future<String> _resolveDriverRouteLabel(String driverId, Map<String, dynamic> driver) async {
    final built = (driver['routeLabel'] ?? '').toString().trim();
    if (built.isNotEmpty) return built;

    try {
      final ymd = _todayYmd();
      final qs = await _fs
          .collection('driver_trips')
          .where('driverId', isEqualTo: driverId)
          .where('date', isEqualTo: ymd)
          .get();
      if (qs.docs.isEmpty) return 'On duty';

      DateTime now = DateTime.now();
      Map<String, dynamic>? chosen;
      DateTime? chosenTime;
      for (final d in qs.docs) {
        final m = d.data() as Map<String, dynamic>;
        final t = _todayAt((m['time'] ?? '').toString());
        if (t == null) continue;
        if (!t.isBefore(now) && (chosenTime == null || t.isBefore(chosenTime!))) {
          chosen = m; chosenTime = t;
        }
      }
      chosen ??= qs.docs.first.data() as Map<String, dynamic>;
      final origin = (chosen?['origin'] ?? 'Origin').toString();
      final dest   = (chosen?['destination'] ?? 'Destination').toString();
      return '$origin → $dest';
    } catch (_) {
      return 'On duty';
    }
  }

  String _todayYmd() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4,'0')}-${n.month.toString().padLeft(2,'0')}-${n.day.toString().padLeft(2,'0')}';
  }
  DateTime? _todayAt(String hhmm) {
    if (!hhmm.contains(':')) return null;
    final p = hhmm.split(':');
    final h = int.tryParse(p[0]); final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    final n = DateTime.now(); return DateTime(n.year, n.month, n.day, h, m);
  }

  // ================== OPEN / APPLY ACTIVE ROUTE ==================
  Future<void> _showRoute(_RouteDoc r) async {
    _summary = null;
    _activeRouteKey = r.key;

    _markers.removeWhere((m) =>
    m.markerId.value == 'route_o_${r.key}' ||
        m.markerId.value == 'route_d_${r.key}');

    await _applyActiveRoute(r);
  }

  Future<void> _applyActiveRoute(_RouteDoc r, {bool keepViewport = false}) async {
    _markers.removeWhere((m) =>
    m.markerId == const MarkerId('origin_pin') ||
        m.markerId == const MarkerId('dest_pin'));
    _polylines.clear();

    if (r.polyline.isNotEmpty) {
      final decoded = PolylinePoints().decodePolyline(r.polyline);

      _markers.add(Marker(
        markerId: const MarkerId('origin_pin'),
        position: r.origin,
        icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: r.originName),
      ));
      _markers.add(Marker(
        markerId: const MarkerId('dest_pin'),
        position: r.destination,
        icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
        infoWindow: InfoWindow(title: r.destinationName),
      ));

      final pts = decoded.map((p) => LatLng(p.latitude, p.longitude)).toList();
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        width: 6,
        color: const Color(0xFFD32F2F),
        points: pts,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ));

      setState(() {});
      if (!keepViewport) {
        final bounds = _boundsFrom([r.origin, r.destination, ...pts]);
        _controller?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
      }

      if (r.distanceMeters != null && r.durationSeconds != null) {
        final km = (r.distanceMeters! / 1000).toStringAsFixed(1);
        final mins = (r.durationSeconds! / 60).round();
        setState(() => _summary = '$km km • $mins mins');
      }
    } else {
      await _drawRouteBetween(r.origin, r.destination, r.originName, r.destinationName);
    }
  }

  // ================== GOOGLE DIRECTIONS FALLBACK ==================
  Future<void> _drawRouteBetween(
      LatLng origin,
      LatLng dest, [
        String oName = 'Origin',
        String dName = 'Destination',
      ]) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=${origin.latitude},${origin.longitude}'
          '&destination=${dest.latitude},${dest.longitude}'
          '&mode=driving'
          '&key=$_directionsKey',
    );

    final res = await http.get(url);
    if (res.statusCode != 200) { _snack('Directions error: HTTP ${res.statusCode}'); return; }
    final data = json.decode(res.body);
    if ((data['status'] ?? '') != 'OK') { _snack('Directions failed: ${data['status']}'); return; }

    final routes = (data['routes'] as List?) ?? [];
    if (routes.isEmpty) { _snack('No route found'); return; }

    final r0 = routes[0];
    final points = (r0['overview_polyline']?['points'] ?? '').toString();
    if (points.isEmpty) { _snack('Empty polyline'); return; }
    final decoded = PolylinePoints().decodePolyline(points);

    final legs = (r0['legs'] as List?) ?? [];
    final dist = legs.fold<int>(0, (a, l) => a + ((l['distance']?['value'] ?? 0) as num).toInt());
    final dur  = legs.fold<int>(0, (a, l) => a + ((l['duration']?['value'] ?? 0) as num).toInt());
    final km = (dist / 1000).toStringAsFixed(1);
    final mins = (dur / 60).round();
    setState(() => _summary = '$km km • $mins mins');

    _markers.add(Marker(
      markerId: const MarkerId('origin_pin'),
      position: origin,
      icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      infoWindow: InfoWindow(title: oName),
    ));
    _markers.add(Marker(
      markerId: const MarkerId('dest_pin'),
      position: dest,
      icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
      infoWindow: InfoWindow(title: dName),
    ));

    final pts = decoded.map((e) => LatLng(e.latitude, e.longitude)).toList();
    _polylines.add(Polyline(
      polylineId: const PolylineId('route'),
      width: 6,
      color: const Color(0xFFD32F2F),
      points: pts,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
    ));

    setState(() {});
    final bounds = _boundsFrom([origin, dest, ...pts]);
    _controller?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
  }

  // ---- helpers ----
  LatLngBounds _boundsFrom(List<LatLng> list) {
    double? minLat, maxLat, minLng, maxLng;
    for (final p in list) {
      minLat = (minLat == null) ? p.latitude : math.min(minLat, p.latitude);
      maxLat = (maxLat == null) ? p.latitude : math.max(maxLat, p.latitude);
      minLng = (minLng == null) ? p.longitude : math.min(minLng, p.longitude);
      maxLng = (maxLng == null) ? p.longitude : math.max(maxLng, p.longitude);
    }
    return LatLngBounds(
      southwest: LatLng(minLat!, minLng!),
      northeast: LatLng(maxLat!, maxLng!),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    final initial = _myPos ?? const LatLng(5.3540, 100.3010); // Penang default

    return Scaffold(
      appBar: AppBar(
        title: const Text('GPS'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          if (_summary != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(_summary!, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(target: initial, zoom: 14),
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        onMapCreated: (c) => _controller = c,
        markers: _markers,
        polylines: _polylines,
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFD32F2F),
        onPressed: () async {
          if (_myPos != null) {
            _controller?.animateCamera(CameraUpdate.newLatLngZoom(_myPos!, 16));
          } else {
            _snack('Getting your location...');
            await _initLocation();
          }
        },
        child: const Icon(Icons.my_location, color: Colors.white),
      ),
    );
  }
}

/* ===================== MODELS ===================== */

class _RouteDoc {
  final String key;
  final LatLng origin;
  final LatLng destination;
  final String originName;
  final String destinationName;
  final String polyline; // encoded polyline from Firestore (optional)
  final int? distanceMeters;
  final int? durationSeconds;

  _RouteDoc({
    required this.key,
    required this.origin,
    required this.destination,
    required this.originName,
    required this.destinationName,
    required this.polyline,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}
