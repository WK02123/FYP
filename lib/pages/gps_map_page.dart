import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';

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

  StreamSubscription<QuerySnapshot>? _stopsSub;
  StreamSubscription<QuerySnapshot>? _routesSub;
  StreamSubscription<DocumentSnapshot>? _driverSub;

  // Optional: Google Directions (used only if route doc has no polyline)
  static const String _directionsKey = 'YOUR_GOOGLE_KEY';

  // Bottom info
  String? _summary; // e.g. "5.6 km • 12 mins"

  // Custom icons (optional)
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  BitmapDescriptor? _driverIcon;

  // Demo driver id (safe if missing)
  static const String _demoDriverId = 'driver_demo_1';

  // ===== Route model (from Firestore `routes`) =====
  final Map<String, _RouteDoc> _routeIndex = {}; // key -> route doc

  @override
  void initState() {
    super.initState();
    _loadMarkerIcons();
    _initLocation();
    _subscribeRoutes(); // <— NEW: show pins from `routes`
    _subscribeStops();  // still supported if you also keep `stops`
    _subscribeDriver(_demoDriverId);
  }

  @override
  void dispose() {
    _stopsSub?.cancel();
    _routesSub?.cancel();
    _driverSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _loadMarkerIcons() async {
    try {
      final pickup = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/map/pin_pickup.png',
      );
      final drop = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/map/pin_drop.png',
      );
      final driver = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/map/pin_driver.png',
      );
      setState(() {
        _pickupIcon = pickup;
        _dropIcon = drop;
        _driverIcon = driver;
      });
    } catch (_) {
      _pickupIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
      _dropIcon   = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose);
      _driverIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
      setState(() {});
    }
  }

  // ===== Location =====
  Future<void> _initLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _snack('Please enable GPS/location services');
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
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

  // ===== Subscribe ROUTES and draw two pins per route =====
  void _subscribeRoutes() {
    _routesSub = _fs.collection('routes').snapshots().listen((snap) async {
      // Keep any non-route markers (driver, manual/test, stops)
      final keep = _markers.where((m) =>
      !m.markerId.value.startsWith('route_o_') &&
          !m.markerId.value.startsWith('route_d_')).toList();

      final routeMarkers = <Marker>{};
      _routeIndex.clear();

      for (final d in snap.docs) {
        final data = d.data() as Map<String, dynamic>;
        final key = d.id;

        // Accept either GeoPoint or (later) resolved from stop docs
        final originGp = data['origin'] as GeoPoint?;
        final destGp   = data['destination'] as GeoPoint?;

        // Skip if missing geos
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
          originStopId: (data['originStopId'] ?? '').toString(),
          destinationStopId: (data['destinationStopId'] ?? '').toString(),
        );
        _routeIndex[key] = r;

        // Make two markers for this route
        routeMarkers.add(
          Marker(
            markerId: MarkerId('route_o_$key'),
            position: r.origin,
            icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
            infoWindow: InfoWindow(title: r.originName, snippet: 'Tap to view ${key} route'),
            onTap: () => _showRoute(r),
          ),
        );
        routeMarkers.add(
          Marker(
            markerId: MarkerId('route_d_$key'),
            position: r.destination,
            icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
            infoWindow: InfoWindow(title: r.destinationName, snippet: 'Tap to view ${key} route'),
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
    });
  }

  // ===== (Optional) stops: still supported and tappable as waypoints =====
  void _subscribeStops() {
    _stopsSub = _fs.collection('stops').snapshots().listen((snap) {
      final keep = _markers.where((m) => !m.markerId.value.startsWith('stop_')).toList();
      final ms = <Marker>{};

      for (final doc in snap.docs) {
        final m = doc.data() as Map<String, dynamic>;
        final lat = (m['lat'] as num?)?.toDouble();
        final lng = (m['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;

        final name = (m['name'] ?? 'Stop').toString();
        final code = (m['code'] ?? '').toString();
        final pos = LatLng(lat, lng);

        ms.add(
          Marker(
            markerId: MarkerId('stop_${doc.id}'),
            position: pos,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
            infoWindow: InfoWindow(title: name, snippet: code),
            onTap: () {
              // When a loose stop is tapped, try to find a route that uses it (by stopId)
              final rid = _matchRouteByStopId(doc.id);
              if (rid != null) {
                _showRoute(_routeIndex[rid]!);
              } else {
                _snack('No saved route uses this stop');
              }
            },
          ),
        );
      }

      setState(() {
        _markers
          ..removeWhere((m) => m.markerId.value.startsWith('stop_'))
          ..addAll(ms)
          ..addAll(keep.where((m) => !m.markerId.value.startsWith('stop_')));
      });
    });
  }

  String? _matchRouteByStopId(String stopId) {
    for (final e in _routeIndex.entries) {
      if (e.value.originStopId == stopId || e.value.destinationStopId == stopId) {
        return e.key;
      }
    }
    return null;
  }

  // ===== Driver live marker (optional) =====
  void _subscribeDriver(String driverId) {
    _driverSub = _fs.collection('drivers').doc(driverId).snapshots().listen((snap) {
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final heading = ((data['heading'] as num?) ?? 0).toDouble();
      if (lat == null || lng == null) return;

      final pos = LatLng(lat, lng);
      final m = Marker(
        markerId: const MarkerId('driver_live'),
        position: pos,
        rotation: heading,
        flat: true,
        anchor: const Offset(0.5, 0.5),
        icon: _driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      );

      setState(() {
        _markers.removeWhere((mk) => mk.markerId == const MarkerId('driver_live'));
        _markers.add(m);
      });
    });
  }

  // ===== Show route for a given route document =====
  Future<void> _showRoute(_RouteDoc r) async {
    _summary = null;

    // If polyline saved -> decode & draw (no API call)
    if (r.polyline.isNotEmpty) {
      final decoded = PolylinePoints().decodePolyline(r.polyline);
      await _drawPolylineAndFit(
        r.originName,
        r.destinationName,
        r.origin,
        r.destination,
        decoded.map((p) => LatLng(p.latitude, p.longitude)).toList(),
      );
      if (r.distanceMeters != null && r.durationSeconds != null) {
        final km = (r.distanceMeters! / 1000).toStringAsFixed(1);
        final mins = (r.durationSeconds! / 60).round();
        setState(() => _summary = '$km km • $mins mins');
      }
      return;
    }

    // Else call Directions (fallback)
    await _drawRouteBetween(r.origin, r.destination, r.originName, r.destinationName);
  }

  // ===== Draw decoded points =====
  Future<void> _drawPolylineAndFit(
      String oName,
      String dName,
      LatLng origin,
      LatLng destination,
      List<LatLng> points,
      ) async {
    // remove any previous route
    _polylines.clear();

    // ensure endpoint markers are present & labeled
    _markers.removeWhere((m) =>
    m.markerId == const MarkerId('origin_pin') || m.markerId == const MarkerId('dest_pin'));
    _markers.add(
      Marker(
        markerId: const MarkerId('origin_pin'),
        position: origin,
        icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: oName),
      ),
    );
    _markers.add(
      Marker(
        markerId: const MarkerId('dest_pin'),
        position: destination,
        icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
        infoWindow: InfoWindow(title: dName),
      ),
    );

    _polylines.add(
      Polyline(
        polylineId: const PolylineId('route'),
        width: 6,
        color: const Color(0xFFD32F2F),
        points: points,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
    );

    setState(() {});

    final bounds = _boundsFrom([
      origin,
      destination,
      ...points,
    ]);
    _controller?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
  }

  // ===== Directions fallback (if no polyline saved) =====
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
    if (res.statusCode != 200) {
      _snack('Directions error: HTTP ${res.statusCode}');
      return;
    }
    final data = json.decode(res.body);
    if ((data['status'] ?? '') != 'OK') {
      _snack('Directions failed: ${data['status']}');
      return;
    }

    final routes = (data['routes'] as List?) ?? [];
    if (routes.isEmpty) {
      _snack('No route found');
      return;
    }

    final r0 = routes[0];
    final points = (r0['overview_polyline']?['points'] ?? '').toString();
    if (points.isEmpty) {
      _snack('Empty polyline');
      return;
    }
    final decoded = PolylinePoints().decodePolyline(points);

    // distance/duration summary
    final legs = (r0['legs'] as List?) ?? [];
    final dist = legs.fold<int>(0, (a, l) => a + ((l['distance']?['value'] ?? 0) as num).toInt());
    final dur  = legs.fold<int>(0, (a, l) => a + ((l['duration']?['value'] ?? 0) as num).toInt());
    final km = (dist / 1000).toStringAsFixed(1);
    final mins = (dur / 60).round();
    setState(() => _summary = '$km km • $mins mins');

    await _drawPolylineAndFit(
      oName,
      dName,
      origin,
      dest,
      decoded.map((e) => LatLng(e.latitude, e.longitude)).toList(),
    );
  }

  // ===== Helpers =====
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final initial = _myPos ?? const LatLng(5.3540, 100.3010);

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
        onPressed: () {
          if (_myPos != null) {
            _controller?.animateCamera(CameraUpdate.newLatLngZoom(_myPos!, 16));
          } else {
            _snack('Getting your location...');
            _initLocation();
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
  final String polyline; // encoded
  final int? distanceMeters;
  final int? durationSeconds;
  final String originStopId;
  final String destinationStopId;

  _RouteDoc({
    required this.key,
    required this.origin,
    required this.destination,
    required this.originName,
    required this.destinationName,
    required this.polyline,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.originStopId,
    required this.destinationStopId,
  });
}
