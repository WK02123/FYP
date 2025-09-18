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
  final _firestore = FirebaseFirestore.instance;

  GoogleMapController? _controller;
  LatLng? _myPos;

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  StreamSubscription<QuerySnapshot>? _stopsSub;

  // TODO: Replace with your own Directions API key
  static const String _directionsKey = 'YOUR_DIRECTIONS_API_KEY';

  // Selected route endpoints
  LatLng? _origin;
  String? _originName;
  LatLng? _dest;
  String? _destName;

  @override
  void initState() {
    super.initState();
    _initLocation();
    _subscribeStops();
  }

  @override
  void dispose() {
    _stopsSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // ======= Location =======
  Future<void> _initLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _toast("Please enable GPS/location services");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      _toast("Location permission denied. Please enable it in settings.");
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _myPos = LatLng(pos.latitude, pos.longitude);
      if (!mounted) return;
      setState(() {});
      _controller?.animateCamera(CameraUpdate.newLatLngZoom(_myPos!, 15));
    } catch (e) {
      _toast("Failed to get location: $e");
    }
  }

  // ======= Firestore stops -> markers =======
  void _subscribeStops() {
    _stopsSub = _firestore.collection('stops').snapshots().listen((snap) {
      final ms = <Marker>{};
      for (final doc in snap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final lat = (data['lat'] as num?)?.toDouble();
        final lng = (data['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;

        final name = (data['name'] ?? 'Stop').toString();
        final code = (data['code'] ?? '').toString();
        final pos = LatLng(lat, lng);

        ms.add(
          Marker(
            markerId: MarkerId(doc.id),
            position: pos,
            infoWindow: InfoWindow(title: name, snippet: code),
            onTap: () => _showStopSheet(name: name, code: code, pos: pos),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
          ),
        );
      }
      setState(() {
        _markers
          ..clear()
          ..addAll(ms);
      });
    });
  }

  // ======= Bottom sheet for a stop =======
  void _showStopSheet({
    required String name,
    required String code,
    required LatLng pos,
  }) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          runSpacing: 12,
          children: [
            Text(
              '$name ($code)',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              'Lat: ${pos.latitude.toStringAsFixed(6)}, '
              'Lng: ${pos.longitude.toStringAsFixed(6)}',
            ),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() {
                      _origin = pos;
                      _originName = name;
                    });
                    _controller?.animateCamera(
                      CameraUpdate.newLatLngZoom(pos, 17),
                    );
                    _maybeRoute();
                  },
                  icon: const Icon(Icons.trip_origin),
                  label: const Text('Set as Origin'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() {
                      _dest = pos;
                      _destName = name;
                    });
                    _controller?.animateCamera(
                      CameraUpdate.newLatLngZoom(pos, 17),
                    );
                    _maybeRoute();
                  },
                  icon: const Icon(Icons.flag),
                  label: const Text('Set as Destination'),
                ),
              ],
            ),
            if (_origin != null || _dest != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'From: ${_originName ?? '-'}\nTo:     ${_destName ?? '-'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _origin = null;
                        _dest = null;
                        _originName = null;
                        _destName = null;
                        _polylines.clear();
                      });
                    },
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ======= Directions API routing =======
  Future<void> _maybeRoute() async {
    if (_origin == null || _dest == null) return;
    await _drawRouteBetween(_origin!, _dest!);
  }

  Future<void> _drawRouteBetween(LatLng origin, LatLng dest) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${dest.latitude},${dest.longitude}'
      '&mode=driving'
      '&key=$_directionsKey',
    );

    final res = await http.get(url);
    if (res.statusCode != 200) {
      _toast('Directions API error: HTTP ${res.statusCode}');
      return;
    }
    final data = json.decode(res.body);
    final routes = (data['routes'] as List?) ?? [];
    if (routes.isEmpty) {
      _toast('No route found');
      return;
    }

    final points = routes[0]['overview_polyline']['points'] as String;
    final decoded = PolylinePoints().decodePolyline(points);

    final polyline = Polyline(
      polylineId: const PolylineId('route'),
      width: 6,
      points: decoded.map((e) => LatLng(e.latitude, e.longitude)).toList(),
    );

    setState(() {
      _polylines
        ..clear()
        ..add(polyline);
    });

    // Fit camera to route
    final bounds = _boundsFrom([
      origin,
      dest,
      ...decoded.map((e) => LatLng(e.latitude, e.longitude)),
    ]);
    _controller?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
  }

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

  // ======= Nearest stop helpers =======
  double _deg2rad(double d) => d * (math.pi / 180.0);

  double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000.0; // meters
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLng = _deg2rad(b.longitude - a.longitude);
    final la1 = _deg2rad(a.latitude);
    final la2 = _deg2rad(b.latitude);

    final h =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(la1) * math.cos(la2) * math.pow(math.sin(dLng / 2), 2);
    return 2 * R * math.asin(math.min(1, math.sqrt(h)));
  }

  void _showNearestStop() {
    if (_myPos == null || _markers.isEmpty) {
      _toast('Need location and at least one stop');
      return;
    }
    Marker? nearest;
    double? best;
    for (final m in _markers) {
      final d = _haversineMeters(_myPos!, m.position);
      if (best == null || d < best) {
        best = d;
        nearest = m;
      }
    }
    if (nearest == null) {
      _toast('No stops found');
      return;
    }

    final meters = best!;
    final dist = (meters < 1000)
        ? '${meters.toStringAsFixed(0)} m'
        : '${(meters / 1000).toStringAsFixed(2)} km';

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nearest stop: ${nearest!.infoWindow.title ?? nearest.markerId.value}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text('Distance: $dist'),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () {
                    Navigator.pop(context);
                    _controller?.animateCamera(
                      CameraUpdate.newLatLngZoom(nearest!.position, 17),
                    );
                  },
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text('Center here'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() {
                      _origin = _myPos;
                      _originName = 'My Location';
                      _dest = nearest!.position;
                      _destName = nearest!.infoWindow.title ?? 'Stop';
                    });
                    _maybeRoute();
                  },
                  icon: const Icon(Icons.directions),
                  label: const Text('Route to stop'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ======= UI =======
  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    // Default to Penang if GPS not ready
    final initial = _myPos ?? const LatLng(5.3540, 100.3010);

    return Scaffold(
      appBar: AppBar(
        title: const Text('GPS'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Nearest stop',
            icon: const Icon(Icons.near_me),
            onPressed: _showNearestStop,
          ),
          IconButton(
            tooltip: 'Demo: route first 2 stops',
            icon: const Icon(Icons.alt_route),
            onPressed: () async {
              if (_markers.length >= 2) {
                final m = _markers.toList();
                await _drawRouteBetween(m[0].position, m[1].position);
                setState(() {
                  _origin = m[0].position;
                  _dest = m[1].position;
                  _originName =
                      m[0].infoWindow.title ?? 'Stop ${m[0].markerId.value}';
                  _destName =
                      m[1].infoWindow.title ?? 'Stop ${m[1].markerId.value}';
                });
              } else {
                _toast('Add at least two stops in Firestore');
              }
            },
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
            _toast('Getting your location...');
            _initLocation();
          }
        },
        child: const Icon(Icons.my_location, color: Colors.white),
      ),
    );
  }
}
