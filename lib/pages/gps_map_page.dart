// lib/pages/gps_map_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;                       // 👈 for bitmap scaling

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; // 👈 for asset bytes
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';

/// --- Ensure we can read Firestore under your rules ---
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
  final Set<Circle> _circles = {};                 // soft halo for buses

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _routesSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _driversSub;

  // Fallback Directions key if route has no saved polyline
  static const String _directionsKey = 'YOUR_GOOGLE_KEY_HERE';

  String? _summary; // distance • duration

  // Icons
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  BitmapDescriptor? _carIcon;                     // 👈 fixed-size car

  // Config: car marker width (px)
  static const int carWidthPx = 64;               // try 48 / 64 / 72

  // Route cache + current active route key
  final Map<String, _RouteDoc> _routeIndex = {};
  String? _activeRouteKey;

  // --- driver auto-center helpers ---
  bool _autoCenteredOnce = false;
  List<Marker> _driverMarkers() =>
      _markers.where((m) => m.markerId.value.startsWith('drv_')).toList();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _ensureSignedIn();
    await _loadMarkerIcons();
    await _initLocation();
    _subscribeRoutes();
    _subscribeAllOnlineDrivers();
  }

  @override
  void dispose() {
    _routesSub?.cancel();
    _driversSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /* ---------------- Icons ---------------- */

  Future<BitmapDescriptor> _bitmapFromAsset(String path, {int width = 64}) async {
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: width, // 👈 force fixed size
    );
    final frame = await codec.getNextFrame();
    final bytes = (await frame.image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    return BitmapDescriptor.fromBytes(bytes);
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
      // 👇 your bus icon, scaled to a fixed width
      _carIcon = await _bitmapFromAsset('assets/map/car.png', width: carWidthPx);
    } catch (_) {
      _pickupIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
      _dropIcon   = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose);
      _carIcon    = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    }
    if (mounted) setState(() {});
  }

  /* ---------------- My location ---------------- */

  Future<void> _initLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) { _snack('Please enable GPS/location services'); return; }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      _snack('Location permission denied. Enable it in settings.'); return;
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

  /* ---------------- Routes snapshot ---------------- */

  void _subscribeRoutes() {
    _routesSub = _fs.collection('routes').snapshots().listen((snap) async {
      // Keep non-route markers (drivers & active pins)
      final keep = _markers.where((m) =>
      !m.markerId.value.startsWith('route_o_') &&
          !m.markerId.value.startsWith('route_d_')
      ).toList();

      final routeMarkers = <Marker>{};
      _routeIndex.clear();

      for (final d in snap.docs) {
        final data = d.data();
        final key  = d.id;

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
    }, onError: (e) => _snack('Routes stream error: $e'));
  }

  /* ---------------- Drivers (active:true or status:"online") ---------------- */

  void _subscribeAllOnlineDrivers() {
    _driversSub = _fs
        .collection('drivers')
        .where('active', isEqualTo: true)
        .snapshots()
        .listen((snap) async {
      if (snap.docs.isEmpty) {
        try {
          final alt = await _fs
              .collection('drivers')
              .where('status', isEqualTo: 'online')
              .get();
          _applyDriverDocs(alt.docs);
        } catch (e) {
          _snack('Drivers (fallback) error: $e');
        }
      } else {
        _applyDriverDocs(snap.docs);
      }
    }, onError: (e) => _snack('Drivers stream error: $e'));
  }

  void _applyDriverDocs(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    // Remove existing driver markers + halos
    _markers.removeWhere((m) => m.markerId.value.startsWith('drv_'));
    _circles.removeWhere((c) => c.circleId.value.startsWith('drv_'));

    int shown = 0, missing = 0; int idx = 0;

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
      if (lat == null || lng == null) { missing++; continue; }

      shown++;
      final pos = LatLng(lat, lng);
      final busCode  = (d['busCode'] ?? 'Bus').toString();
      final heading  = (d['heading'] as num?)?.toDouble() ?? 0.0;
      final routeLbl = await _resolveDriverRouteLabel(doc.id, d);

      // 👉 fixed-size custom car marker, rotated by heading if available
      _markers.add(
        Marker(
          markerId: MarkerId('drv_${doc.id}'),
          position: pos,
          icon: _carIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          rotation: heading,     // 0..360
          flat: true,
          anchor: const Offset(0.5, 0.5),
          zIndex: 10000.0 + idx,
          infoWindow: InfoWindow(title: '🚌 $busCode', snippet: routeLbl),
        ),
      );

      // Soft halo to make it pop
      _circles.add(
        Circle(
          circleId: CircleId('drv_${doc.id}_halo'),
          center: pos,
          radius: 25.0,
          strokeWidth: 2,
          strokeColor: const Color(0xFFE53935),
          fillColor: const Color(0x33E53935),
          zIndex: 9999,
        ),
      );

      idx++;
    }

    // Debug
    // ignore: avoid_print
    print('🗺️ Drivers snapshot: total=${docs.length}, shown=$shown, missingCoords=$missing');

    if (mounted) setState(() {});

    if (shown > 0) _fitToDrivers();
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
        final m = d.data();
        final t = _todayAt((m['time'] ?? '').toString());
        if (t == null) continue;
        if (!t.isBefore(now) && (chosenTime == null || t.isBefore(chosenTime!))) {
          chosen = m; chosenTime = t;
        }
      }
      chosen ??= qs.docs.first.data();
      final origin = (chosen?['origin'] ?? 'Origin').toString();
      final dest   = (chosen?['destination'] ?? 'Destination').toString();
      return '$origin → $dest';
    } catch (_) {
      return 'On duty';
    }
  }

  void _fitToDrivers({bool force = false}) {
    if (_controller == null) return;
    final drivers = _driverMarkers();
    if (drivers.isEmpty) return;

    if (!force && _autoCenteredOnce) return;

    if (drivers.length == 1) {
      final id = drivers.first.markerId;
      _controller!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: drivers.first.position, zoom: 17),
        ),
      );
      _controller!.showMarkerInfoWindow(id);
    } else {
      final pts = drivers.map((m) => m.position).toList();
      final b = _boundsFrom(pts);
      _controller!.animateCamera(CameraUpdate.newLatLngBounds(b, 60));
    }
    _autoCenteredOnce = true;
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

  /* ---------------- Open / apply active route ---------------- */

  Future<void> _showRoute(_RouteDoc r) async {
    _summary = null;
    _activeRouteKey = r.key;

    _markers.removeWhere((m) =>
    m.markerId.value == 'route_o_${r.key}' ||
        m.markerId.value == 'route_d_${r.key}'
    );

    await _applyActiveRoute(r);
  }

  Future<void> _applyActiveRoute(_RouteDoc r, {bool keepViewport = false}) async {
    _markers.removeWhere((m) =>
    m.markerId == const MarkerId('origin_pin') ||
        m.markerId == const MarkerId('dest_pin')
    );
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

  /* ---------------- Directions fallback ---------------- */

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

  /* ---------------- Helpers ---------------- */

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

  /* ---------------- UI ---------------- */

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
          IconButton(
            tooltip: 'Locate buses',
            icon: const Icon(Icons.directions_bus_filled),
            onPressed: () => _fitToDrivers(force: true),
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
        circles: _circles,
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

/* ---------------- Model ---------------- */

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
