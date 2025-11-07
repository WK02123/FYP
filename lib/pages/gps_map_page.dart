// lib/pages/gps_map_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';

Future<void> _ensureSignedIn() async {
  final auth = FirebaseAuth.instance;
  if (auth.currentUser == null) {
    await auth.signInAnonymously();
  }
}

class GpsMapPage extends StatefulWidget {
  final String? routeKey;   // lock to a route if provided
  final String? driverId;   // (optional) future filter

  const GpsMapPage({super.key, this.routeKey, this.driverId});

  @override
  State<GpsMapPage> createState() => _GpsMapPageState();
}

class _GpsMapPageState extends State<GpsMapPage> {
  final _fs = FirebaseFirestore.instance;

  GoogleMapController? _controller;
  LatLng? _myPos;

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final Set<Circle> _circles = {};

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _routesSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _driversSub;

  // Use your key or proxy if needed for fallback directions
  static const String _directionsKey = 'GOOGLE_DIRECTIONS_KEY';

  String? _summary;

  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _dropIcon;
  BitmapDescriptor? _carIcon;

  static const int carWidthPx = 64;

  final Map<String, _RouteDoc> _routeIndex = {};
  String? _activeRouteKey;

  bool get _forcedRouteMode => widget.routeKey != null;

  bool _autoCenteredOnce = false;

  // Live driver ticker (always-visible info at top)
  List<_DriverInfo> _driverList = [];

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
      targetWidth: width,
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

        final active = (data['active'] as bool?) ?? true;

        final r = _RouteDoc(
          key: key,
          origin: LatLng(originGp.latitude, originGp.longitude),
          destination: LatLng(destGp.latitude, destGp.longitude),
          originName: (data['originName'] ?? 'Origin').toString(),
          destinationName: (data['destinationName'] ?? 'Destination').toString(),
          polyline: (data['polyline'] ?? '').toString(),
          distanceMeters: (data['distance_meters'] as num?)?.toInt(),
          durationSeconds: (data['duration_seconds'] as num?)?.toInt(),
          active: active,
        );
        _routeIndex[key] = r;

        if (!_forcedRouteMode && active) {
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
      }

      setState(() {
        _markers
          ..clear()
          ..addAll(keep)
          ..addAll(routeMarkers);
      });

      if (_forcedRouteMode && widget.routeKey != null) {
        final r = _routeIndex[widget.routeKey!];
        if (r == null) return;
        if (!r.active) {
          _clearActiveRoute();
          if (mounted) {
            _summary = null;
            setState(() {});
          }
        } else {
          _activeRouteKey = r.key;
          await _applyActiveRoute(r, keepViewport: true);
        }
      } else if (_activeRouteKey != null && _routeIndex[_activeRouteKey!] != null) {
        final r = _routeIndex[_activeRouteKey!]!;
        if (!r.active) {
          _clearActiveRoute();
          if (mounted) { _summary = null; setState(() {}); }
        } else {
          _applyActiveRoute(r, keepViewport: true);
        }
      }
    }, onError: (e) => _snack('Routes stream error: $e'));
  }

  /* ---------------- Drivers (status:"online" OR active:true) ---------------- */

  void _subscribeAllOnlineDrivers() {
    _driversSub?.cancel();
    _driversSub = _fs.collection('drivers').snapshots().listen((snap) {
      // live filter: doc qualifies if position exists AND (online || active)
      final live = snap.docs.where((d) {
        final m = d.data();
        final isOnline = (m['status'] ?? '').toString().toLowerCase() == 'online';
        final isActive = (m['active'] as bool?) ?? false;
        final hasLatLng = (m['lat'] is num && m['lng'] is num) || (m['pos'] is GeoPoint);
        return hasLatLng && (isOnline || isActive);
      }).toList();
      _applyDriverDocs(live);
    }, onError: (e) => _snack('Drivers stream error: $e'));
  }

  Future<String> _labelForRouteKey(String routeKey) async {
    // Try Firestore 'routes/<key>' for pretty names
    try {
      final doc = await _fs.collection('routes').doc(routeKey).get();
      if (doc.exists) {
        final m = doc.data()!;
        final o = (m['originName'] ?? '').toString().trim();
        final d = (m['destinationName'] ?? '').toString().trim();
        if (o.isNotEmpty && d.isNotEmpty) return '$o → $d';
      }
    } catch (_) {
      // ignore and fall back
    }
    // Fallback: split "Origin|Destination"
    final parts = routeKey.split('|');
    if (parts.length == 2) {
      return '${parts[0].trim()} → ${parts[1].trim()}';
    }
    return routeKey.replaceAll('|', ' → ');
  }

  Future<String> _resolveDriverRouteLabel(String driverId, Map<String, dynamic> driver) async {
    // 0) precomputed label
    final built = (driver['routeLabel'] ?? '').toString().trim();
    if (built.isNotEmpty) return built;

    // 1) explicit current route key
    final currentKey = (driver['currentRouteKey'] ?? '').toString().trim();
    if (currentKey.isNotEmpty) return await _labelForRouteKey(currentKey);

    // 2) routes[] can be strings or maps
    final rawRoutes = driver['routes'];
    if (rawRoutes is List && rawRoutes.isNotEmpty) {
      // case A: list of strings
      if (rawRoutes.first is String) {
        final key = (rawRoutes.first as String).trim();
        if (key.isNotEmpty) return await _labelForRouteKey(key);
      }
      // case B: list of maps
      if (rawRoutes.first is Map) {
        try {
          final m = Map<String, dynamic>.from(rawRoutes.first as Map);
          final mapKey = (m['key'] ?? '').toString().trim();
          if (mapKey.isNotEmpty) return await _labelForRouteKey(mapKey);
          final o = (m['origin'] ?? m['originName'] ?? '').toString().trim();
          final d = (m['destination'] ?? m['destinationName'] ?? '').toString().trim();
          if (o.isNotEmpty && d.isNotEmpty) return '$o → $d';
        } catch (_) {/* ignore */}
      }
    }

    // 3) last fallback: show something but not "On duty" if we know their bus
    final bus = (driver['busCode'] ?? '').toString().trim();
    return bus.isNotEmpty ? '$bus on duty' : 'On duty';
  }

  void _applyDriverDocs(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    // Remove existing driver markers + halos
    _markers.removeWhere((m) => m.markerId.value.startsWith('drv_'));
    _circles.removeWhere((c) => c.circleId.value.startsWith('drv_'));

    final infos = <_DriverInfo>[];
    int shown = 0; int idx = 0;

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

      shown++;
      final pos = LatLng(lat, lng);
      final busCode  = (d['busCode'] ?? 'Bus').toString();
      final name     = (d['name'] ?? '').toString();
      final heading  = (d['heading'] as num?)?.toDouble() ?? 0.0;
      final routeLbl = await _resolveDriverRouteLabel(doc.id, d);

      // Marker
      final mkId = MarkerId('drv_${doc.id}');
      _markers.add(
        Marker(
          markerId: mkId,
          position: pos,
          icon: _carIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          rotation: heading,
          flat: true,
          anchor: const Offset(0.5, 0.5),
          zIndex: 10000.0 + idx,
          infoWindow: InfoWindow(title: '🚌 $busCode${name.isNotEmpty ? ' • $name' : ''}', snippet: routeLbl),
        ),
      );

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

      infos.add(_DriverInfo(busCode: busCode, name: name, routeLabel: routeLbl, latLng: pos));
      idx++;
    }

    if (mounted) {
      setState(() {
        _driverList = infos; // update persistent ticker
      });
    }

    // Auto-show the first driver's infoWindow so info is visible without taps
    if (shown > 0 && _controller != null && _markers.isNotEmpty) {
      final first = _markers.firstWhere((m) => m.markerId.value.startsWith('drv_'));
      _controller!.showMarkerInfoWindow(first.markerId);
    }

    if (mounted) setState(() {});
    if (shown > 0) _fitToDrivers();
  }

  /* ---------------- Camera helpers ---------------- */

  List<Marker> _driverMarkers() =>
      _markers.where((m) => m.markerId.value.startsWith('drv_')).toList();

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
    if (_forcedRouteMode) return;
    _summary = null;
    _activeRouteKey = r.key;

    _markers.removeWhere((m) =>
    m.markerId.value == 'route_o_${r.key}' ||
        m.markerId.value == 'route_d_${r.key}'
    );

    await _applyActiveRoute(r);
  }

  Future<void> _applyActiveRoute(_RouteDoc r, {bool keepViewport = false}) async {
    if (!r.active) {
      _clearActiveRoute();
      if (mounted) { _summary = null; setState(() {}); }
      return;
    }

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

  void _clearActiveRoute() {
    _polylines.clear();
    _markers.removeWhere((m) =>
    m.markerId == const MarkerId('origin_pin') ||
        m.markerId == const MarkerId('dest_pin')
    );
  }

  /* ---------------- Directions fallback (direct to Google) ---------------- */

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
    final lockedLabel = widget.routeKey;

    return Scaffold(
      appBar: AppBar(
        title: Text(lockedLabel ?? 'GPS'),
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
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: initial, zoom: 14),
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            onMapCreated: (c) => _controller = c,
            markers: _markers,
            polylines: _polylines,
            circles: _circles,
          ),

          // Always-visible live driver ticker (no click needed)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: _driverList.isEmpty
                ? const SizedBox.shrink()
                : Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black12)],
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _driverList.map((d) {
                    final title = d.busCode.isEmpty ? 'Bus' : d.busCode;
                    final subtitle = d.name.isEmpty ? d.routeLabel : '${d.name} • ${d.routeLabel}';
                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: InkWell(
                        onTap: () {
                          if (_controller != null) {
                            _controller!.animateCamera(CameraUpdate.newLatLngZoom(d.latLng, 17));
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF7F7F7),
                            border: Border.all(color: const Color(0xFFE0E0E0)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('🚌 $title', style: const TextStyle(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text(subtitle, style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),

          if (_forcedRouteMode && widget.routeKey != null)
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _fs.collection('routes').doc(widget.routeKey!).snapshots(),
              builder: (context, snap) {
                final active = (snap.data?.data()?['active'] as bool?) ?? true;
                if (active) return const SizedBox.shrink();
                return Positioned(
                  bottom: 18,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8E1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFFE082)),
                    ),
                    child: Text(
                      'This route has been cancelled by admin.',
                      style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              },
            ),
        ],
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

/* ---------------- Model types ---------------- */

class _DriverInfo {
  final String busCode;
  final String name;
  final String routeLabel;
  final LatLng latLng;
  _DriverInfo({required this.busCode, required this.name, required this.routeLabel, required this.latLng});
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
  final bool active;

  _RouteDoc({
    required this.key,
    required this.origin,
    required this.destination,
    required this.originName,
    required this.destinationName,
    required this.polyline,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.active,
  });
}
