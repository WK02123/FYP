// lib/pages/driver_gps_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

import 'driver_service.dart';

class DriverGpsPage extends StatefulWidget {
  const DriverGpsPage({super.key});
  @override
  State<DriverGpsPage> createState() => _DriverGpsPageState();
}

class _DriverGpsPageState extends State<DriverGpsPage> {
  final _fs = FirebaseFirestore.instance;
  final _svc = DriverService.instance;

  GoogleMapController? _map;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  StreamSubscription<Position>? _posSub;
  LatLng? _me;
  double _bearing = 0;
  bool _follow = true;

  StreamSubscription<QuerySnapshot>? _routesSub;
  final Map<String, _RouteDoc> _routeIndex = {};
  String? _summary;

  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;

  static const String _directionsKey = 'YOUR_GOOGLE_KEY';

  @override
  void initState() {
    super.initState();
    _loadIcons();
    _startSharingAndFollow();
    _subscribeRoutes();
  }

  @override
  void dispose() {
    _routesSub?.cancel();
    _posSub?.cancel();
    _map?.dispose();
    // 👇 IMPORTANT: mark driver offline and stop publishing
    _svc.stopSharingLocation();
    super.dispose();
  }

  Future<void> _loadIcons() async {
    try {
      _pickupIcon = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/map/pin_pickup.png',
      );
      _dropIcon = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(size: Size(48, 48)),
        'assets/map/pin_drop.png',
      );
    } catch (_) {
      _pickupIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
      _dropIcon   = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose);
    }
    if (mounted) setState(() {});
  }

  Future<void> _startSharingAndFollow() async {
    try { await _svc.startSharingLocation(); } catch (_) {}

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) { _snack('Please enable location services'); return; }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack('Location permission denied.'); return;
    }

    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
      ),
    ).listen((p) {
      _me = LatLng(p.latitude, p.longitude);
      if (p.heading != -1) _bearing = p.heading;
      if (_map != null && _follow && _me != null) {
        _map!.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: _me!, zoom: 16.5, bearing: _bearing),
          ),
        );
      }
      if (mounted) setState(() {});
    });
  }

  void _subscribeRoutes() {
    _routesSub = _fs.collection('routes').snapshots().listen((snap) {
      final newMarkers = <Marker>{};
      _routeIndex.clear();

      for (final d in snap.docs) {
        final data = d.data() as Map<String, dynamic>;
        final key = d.id;
        final o = data['origin'] as GeoPoint?;
        final g = data['destination'] as GeoPoint?;
        if (o == null || g == null) continue;

        final r = _RouteDoc(
          key: key,
          origin: LatLng(o.latitude, o.longitude),
          destination: LatLng(g.latitude, g.longitude),
          originName: (data['originName'] ?? 'Origin').toString(),
          destinationName: (data['destinationName'] ?? 'Destination').toString(),
          polyline: (data['polyline'] ?? '').toString(),
          distanceMeters: (data['distance_meters'] as num?)?.toInt(),
          durationSeconds: (data['duration_seconds'] as num?)?.toInt(),
        );
        _routeIndex[key] = r;

        newMarkers.add(
          Marker(
            markerId: MarkerId('route_o_$key'),
            position: r.origin,
            icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
            infoWindow: InfoWindow(title: r.originName, snippet: 'Tap to view route'),
            onTap: () => _showRoute(r),
          ),
        );
        newMarkers.add(
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
          ..removeWhere((m) => m.markerId.value.startsWith('route_o_') || m.markerId.value.startsWith('route_d_'))
          ..addAll(newMarkers);
      });
    });
  }

  Future<void> _showRoute(_RouteDoc r) async {
    _summary = null;

    if (r.polyline.isNotEmpty) {
      final decoded = PolylinePoints().decodePolyline(r.polyline);
      await _drawPolylineAndFit(
        r.originName, r.destinationName, r.origin, r.destination,
        decoded.map((p) => LatLng(p.latitude, p.longitude)).toList(),
      );
      if (r.distanceMeters != null && r.durationSeconds != null) {
        final km = (r.distanceMeters! / 1000).toStringAsFixed(1);
        final mins = (r.durationSeconds! / 60).round();
        setState(() => _summary = '$km km • $mins mins');
      }
      return;
    }

    await _drawViaDirections(r.origin, r.destination, r.originName, r.destinationName);
  }

  Future<void> _drawPolylineAndFit(
      String oName, String dName, LatLng origin, LatLng destination, List<LatLng> points,
      ) async {
    _polylines
      ..clear()
      ..add(Polyline(
        polylineId: const PolylineId('route'),
        width: 6,
        color: const Color(0xFFD32F2F),
        points: points,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ));

    _markers
      ..removeWhere((m) => m.markerId == const MarkerId('origin_pin') || m.markerId == const MarkerId('dest_pin'))
      ..add(Marker(
        markerId: const MarkerId('origin_pin'),
        position: origin,
        icon: _pickupIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(title: oName),
      ))
      ..add(Marker(
        markerId: const MarkerId('dest_pin'),
        position: destination,
        icon: _dropIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
        infoWindow: InfoWindow(title: dName),
      ));

    setState(() {});
    final b = LatLngBounds(
      southwest: LatLng(
        [origin.latitude, destination.latitude, ...points.map((e) => e.latitude)].reduce((a, b) => math.min(a, b)),
        [origin.longitude, destination.longitude, ...points.map((e) => e.longitude)].reduce((a, b) => math.min(a, b)),
      ),
      northeast: LatLng(
        [origin.latitude, destination.latitude, ...points.map((e) => e.latitude)].reduce((a, b) => math.max(a, b)),
        [origin.longitude, destination.longitude, ...points.map((e) => e.longitude)].reduce((a, b) => math.max(a, b)),
      ),
    );
    _map?.animateCamera(CameraUpdate.newLatLngBounds(b, 60));
  }

  Future<void> _drawViaDirections(LatLng origin, LatLng dest, String oName, String dName) async {
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

    final r0 = (data['routes'] as List).first;
    final points = (r0['overview_polyline']?['points'] ?? '').toString();
    final decoded = PolylinePoints().decodePolyline(points);

    final legs = (r0['legs'] as List?) ?? [];
    final dist = legs.fold<int>(0, (a, l) => a + ((l['distance']?['value'] ?? 0) as num).toInt());
    final dur  = legs.fold<int>(0, (a, l) => a + ((l['duration']?['value'] ?? 0) as num).toInt());
    _summary = '${(dist/1000).toStringAsFixed(1)} km • ${(dur/60).round()} mins';

    await _drawPolylineAndFit(
      oName, dName, origin, dest,
      decoded.map((e) => LatLng(e.latitude, e.longitude)).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initial = _me ?? const LatLng(5.3540, 100.3010);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My GPS (Driver)'),
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
            tooltip: _follow ? 'Following' : 'Follow',
            icon: Icon(_follow ? Icons.navigation : Icons.navigation_outlined),
            onPressed: () {
              setState(() => _follow = !_follow);
              if (_follow && _me != null) {
                _map?.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(target: _me!, zoom: 16.5, bearing: _bearing),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(target: initial, zoom: 14),
        myLocationEnabled: true,
        myLocationButtonEnabled: true,
        zoomControlsEnabled: false,
        onMapCreated: (c) => _map = c,
        onCameraMoveStarted: () => setState(() => _follow = false),
        markers: _markers,
        polylines: _polylines,
      ),
      floatingActionButton: _me == null ? null : FloatingActionButton.extended(
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.my_location),
        label: const Text('Re-center'),
        onPressed: () {
          _follow = true;
          if (_me != null) {
            _map?.animateCamera(
              CameraUpdate.newCameraPosition(
                CameraPosition(target: _me!, zoom: 16.5, bearing: _bearing),
              ),
            );
          }
          setState(() {});
        },
      ),
    );
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }
}

class _RouteDoc {
  final String key;
  final LatLng origin;
  final LatLng destination;
  final String originName;
  final String destinationName;
  final String polyline;
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
