import 'dart:convert';
import 'dart:io' show Platform; // for Platform.isAndroid
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';

class RouteTimesPage extends StatefulWidget {
  const RouteTimesPage({super.key});
  @override
  State<RouteTimesPage> createState() => _RouteTimesPageState();
}

class _RouteTimesPageState extends State<RouteTimesPage> {
  final _fs = FirebaseFirestore.instance;

  // ========= Keys / Endpoints =========
  static const String _directionsKey = 'AIzaSyBq_qP5gXHGTYVWnlr8MqX6d3uEQnAnCO4';

  // Toggle when you deploy
  static const bool _useEmulator = true; // true = local emulator, false = prod
  static const String _projectId = 'shuttlebus-e0cef';
  static const String _region = 'asia-southeast1';

  String get _cfDirectionsBase {
    if (_useEmulator) {
      final host = kIsWeb ? '127.0.0.1' : (Platform.isAndroid ? '10.0.2.2' : '127.0.0.1');
      return 'http://$host:5001/$_projectId/$_region';
    } else {
      return 'https://$_region-$_projectId.cloudfunctions.net';
    }
  }

  // ========= Route selection =========
  List<String> _routeKeys = [];
  String? _selectedRouteKey;
  bool _loadingRoutes = true;

  // ========= Current route fields =========
  List<String> _times = [];
  int _capacity = 15;
  final _capacityCtrl = TextEditingController(text: '15');
  final _busCodeCtrl = TextEditingController();
  final _driverIdCtrl = TextEditingController();
  final _priceCtrl = TextEditingController(text: '5.00'); // RM shown, store as sen

  // ========= Stops / Map =========
  List<_Stop> _stops = [];
  bool _loadingStops = true;
  _Stop? _originStop;
  _Stop? _destStop;

  GoogleMapController? _map;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final LatLng _defaultCenter = const LatLng(5.3540, 100.3010);
  bool _fetchingRoute = false;

  // Values from Directions / Firestore
  int? _distanceMeters;
  int? _durationSeconds;
  String? _encodedPolyline;

  // Quick place search
  final _searchCtrl = TextEditingController();
  bool _searchingPlace = false;
  static const LatLng _penangCenter = LatLng(5.3540, 100.3010);

  @override
  void initState() {
    super.initState();
    _fetchRoutes();
    _loadStops();
  }

  @override
  void dispose() {
    _capacityCtrl.dispose();
    _busCodeCtrl.dispose();
    _driverIdCtrl.dispose();
    _priceCtrl.dispose();
    _searchCtrl.dispose();
    _map?.dispose();
    super.dispose();
  }

  // ====== Stops list (for optional references) ======
  Future<void> _loadStops() async {
    try {
      final snap = await _fs.collection('stops').get();
      _stops = snap.docs.map((d) {
        final m = d.data() as Map<String, dynamic>;
        return _Stop(
          id: d.id,
          name: (m['name'] ?? 'Stop').toString(),
          code: (m['code'] ?? '').toString(),
          lat: (m['lat'] as num).toDouble(),
          lng: (m['lng'] as num).toDouble(),
        );
      }).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (_) {
      _stops = [];
    } finally {
      if (mounted) setState(() => _loadingStops = false);
    }
  }

  _Stop? _findStopById(String id) {
    try { return _stops.firstWhere((s) => s.id == id); } catch (_) { return null; }
  }

  // ====== Fetch route IDs for dropdown ======
  Future<void> _fetchRoutes() async {
    try {
      final snap = await _fs.collection('routes').get();
      _routeKeys = snap.docs.map((d) => d.id).toList()..sort();
    } catch (_) {
      _routeKeys = [];
    } finally {
      if (mounted) setState(() => _loadingRoutes = false);
    }
  }

  // ====== Load selected route (also rebuild small map) ======
  Future<void> _loadRoute(String key) async {
    setState(() {
      _selectedRouteKey = key;
      _times = [];
      _capacity = 15;
      _capacityCtrl.text = '15';
      _busCodeCtrl.text = '';
      _driverIdCtrl.text = '';
      _priceCtrl.text = '5.00';

      _originStop = null;
      _destStop = null;
      _markers.clear();
      _polylines.clear();
      _distanceMeters = null;
      _durationSeconds = null;
      _encodedPolyline = null;
    });

    final doc = await _fs.collection('routes').doc(key).get();
    if (!doc.exists) { setState(() {}); return; }

    final data = doc.data()!;

    final times = (data['times'] as List?)?.map((e) => e.toString()).toList() ?? [];
    _times = times..sort((a, b) => _as24(a).compareTo(_as24(b)));
    _capacity = (data['capacity'] as num?)?.toInt() ?? 15;
    _capacityCtrl.text = _capacity.toString();
    _busCodeCtrl.text = (data['busCode'] ?? '').toString();
    _driverIdCtrl.text = (data['driverId'] ?? '').toString();
    final priceSen = (data['priceSen'] as num?)?.toInt();
    if (priceSen != null && priceSen >= 0) _priceCtrl.text = (priceSen / 100).toStringAsFixed(2);

    final originId = (data['originStopId'] ?? '').toString();
    final destId = (data['destinationStopId'] ?? '').toString();
    final originGeo = data['origin'] as GeoPoint?;
    final destGeo = data['destination'] as GeoPoint?;
    _encodedPolyline = (data['polyline'] ?? '').toString();
    _distanceMeters = (data['distance_meters'] as num?)?.toInt();
    _durationSeconds = (data['duration_seconds'] as num?)?.toInt();

    _Stop? originCandidate = _findStopById(originId);
    if (originCandidate == null && originGeo != null) {
      originCandidate = _Stop(
        id: 'origin_geo',
        name: (data['originName'] ?? 'Origin').toString(),
        code: '',
        lat: originGeo.latitude,
        lng: originGeo.longitude,
      );
    }
    _originStop = originCandidate;

    _Stop? destCandidate = _findStopById(destId);
    if (destCandidate == null && destGeo != null) {
      destCandidate = _Stop(
        id: 'dest_geo',
        name: (data['destinationName'] ?? 'Destination').toString(),
        code: '',
        lat: destGeo.latitude,
        lng: destGeo.longitude,
      );
    }
    _destStop = destCandidate;

    _markers.clear();
    if (_originStop != null) {
      _markers.add(Marker(
        markerId: const MarkerId('o'),
        position: LatLng(_originStop!.lat, _originStop!.lng),
        infoWindow: InfoWindow(title: 'From: ${_originStop!.name}'),
      ));
    }
    if (_destStop != null) {
      _markers.add(Marker(
        markerId: const MarkerId('d'),
        position: LatLng(_destStop!.lat, _destStop!.lng),
        infoWindow: InfoWindow(title: 'To: ${_destStop!.name}'),
      ));
    }

    _polylines.clear();
    if (_encodedPolyline != null && _encodedPolyline!.isNotEmpty) {
      final decoded = PolylinePoints().decodePolyline(_encodedPolyline!);
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        width: 6,
        color: const Color(0xFFD32F2F),
        points: decoded.map((p) => LatLng(p.latitude, p.longitude)).toList(),
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ));

      final all = <LatLng>[
        if (_originStop != null) LatLng(_originStop!.lat, _originStop!.lng),
        if (_destStop != null) LatLng(_destStop!.lat, _destStop!.lng),
        ...decoded.map((p) => LatLng(p.latitude, p.longitude)),
      ];
      if (all.length >= 2) {
        _map?.animateCamera(CameraUpdate.newLatLngBounds(_boundsFrom(all), 60));
      }
    }
    setState(() {});
  }

  // ====== Create new route (manual key) ======
  Future<void> _createRouteDialog() async {
    final o = TextEditingController();
    final d = TextEditingController();
    final b = TextEditingController();
    final p = TextEditingController(text: '5.00');

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Create Route'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: o, decoration: const InputDecoration(labelText: 'Origin', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: d, decoration: const InputDecoration(labelText: 'Destination', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: b, decoration: const InputDecoration(labelText: 'Bus Code (e.g. INTI-01)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(
              controller: p,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price (RM)', hintText: 'e.g. 5.00', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    final key = '${o.text.trim()}|${d.text.trim()}';
    if (key == '|' || key.trim().isEmpty) return;

    final priceSen = _parsePriceToSen(p.text);

    await _fs.collection('routes').doc(key).set({
      'busCode': b.text.trim(),
      'capacity': 15,
      'times': [],
      'active': true,
      'priceSen': priceSen,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _fetchRoutes();
    await _loadRoute(key);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Route "$key" created')));
  }

  // ====== Times ======
  Future<void> _addTime() async {
    if (_selectedRouteKey == null) {
      _snack('Pick a route first');
      return;
    }
    final picked = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 7, minute: 0));
    if (picked == null) return;

    final t12 = _format12(picked);
    if (_times.contains(t12)) {
      _snack('Time already exists');
      return;
    }

    setState(() => _times = [..._times, t12]..sort((a, b) => _as24(a).compareTo(_as24(b))));
    await _fs.collection('routes').doc(_selectedRouteKey).set({
      'times': FieldValue.arrayUnion([t12]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _removeTime(String t12) async {
    if (_selectedRouteKey == null) return;
    setState(() => _times.remove(t12));
    await _fs.collection('routes').doc(_selectedRouteKey).set({
      'times': FieldValue.arrayRemove([t12]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _saveMeta() async {
    if (_selectedRouteKey == null) return;
    final cap = int.tryParse(_capacityCtrl.text.trim());
    if (cap == null || cap <= 0) { _snack('Capacity must be > 0'); return; }
    final priceSen = _parsePriceToSen(_priceCtrl.text);

    await _fs.collection('routes').doc(_selectedRouteKey).set({
      'capacity': cap,
      'busCode': _busCodeCtrl.text.trim(),
      'driverId': _driverIdCtrl.text.trim(),
      'priceSen': priceSen,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (!mounted) return;
    _snack('Saved');
  }

  // ====== Build preview via Cloud Function ======
  Future<void> _buildPreview() async {
    if (_selectedRouteKey == null) { _snack('Pick a route first'); return; }
    if (_originStop == null || _destStop == null) { _snack('Select origin and destination'); return; }
    setState(() => _fetchingRoute = true);

    try {
      final url = Uri.parse(
        '$_cfDirectionsBase/directions'
            '?origin=${_originStop!.lat},${_originStop!.lng}'
            '&destination=${_destStop!.lat},${_destStop!.lng}'
            '&mode=driving',
      );

      final res = await http.get(url);
      if (res.statusCode != 200) { _snack('Directions error: HTTP ${res.statusCode}'); return; }

      final data = json.decode(res.body);
      if ((data['status'] ?? '') != 'OK') { _snack('Directions failed: ${data['status'] ?? 'UNKNOWN'}'); return; }

      final routes = (data['routes'] as List?) ?? [];
      if (routes.isEmpty) { _snack('No route found between the two points.'); return; }

      final r0 = routes[0];
      _encodedPolyline = (r0['overview_polyline']?['points'] ?? '').toString();
      if (_encodedPolyline == null || _encodedPolyline!.isEmpty) { _snack('Directions returned empty polyline.'); return; }
      final decoded = PolylinePoints().decodePolyline(_encodedPolyline!);

      final legs = (r0['legs'] as List?) ?? [];
      _distanceMeters = legs.fold<int>(0, (a, l) {
        final v = (l['distance']?['value'] ?? 0) as num;
        return a + v.toInt();
      });
      _durationSeconds = legs.fold<int>(0, (a, l) {
        final v = (l['duration']?['value'] ?? 0) as num;
        return a + v.toInt();
      });

      _markers
        ..removeWhere((m) => m.markerId == const MarkerId('o') || m.markerId == const MarkerId('d'))
        ..add(Marker(
          markerId: const MarkerId('o'),
          position: LatLng(_originStop!.lat, _originStop!.lng),
          infoWindow: InfoWindow(title: 'From: ${_originStop!.name}'),
        ))
        ..add(Marker(
          markerId: const MarkerId('d'),
          position: LatLng(_destStop!.lat, _destStop!.lng),
          infoWindow: InfoWindow(title: 'To: ${_destStop!.name}'),
        ));

      _polylines
        ..clear()
        ..add(Polyline(
          polylineId: const PolylineId('route'),
          width: 6,
          color: const Color(0xFFD32F2F),
          points: decoded.map((p) => LatLng(p.latitude, p.longitude)).toList(),
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        ));

      final bounds = _boundsFrom([
        LatLng(_originStop!.lat, _originStop!.lng),
        LatLng(_destStop!.lat, _destStop!.lng),
        ...decoded.map((p) => LatLng(p.latitude, p.longitude)),
      ]);
      _map?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
    } catch (e) {
      _snack('Directions error: $e');
    } finally {
      if (mounted) setState(() => _fetchingRoute = false);
    }
  }

  // ====== Save map route (with REPLACE old doc if key changes) ======
  Future<void> _saveMapRoute() async {
    if (_selectedRouteKey == null) { _snack('Pick a route first'); return; }
    if (_originStop == null || _destStop == null || _encodedPolyline == null || _encodedPolyline!.isEmpty) {
      _snack('Build the preview first');
      return;
    }

    // Map payload we want to save
    final mapFields = {
      'originStopId': _originStop!.id,
      'originName'  : _originStop!.name,
      'origin'      : GeoPoint(_originStop!.lat, _originStop!.lng),
      'destinationStopId': _destStop!.id,
      'destinationName'  : _destStop!.name,
      'destination'      : GeoPoint(_destStop!.lat, _destStop!.lng),
      'polyline'         : _encodedPolyline,
      'distance_meters'  : _distanceMeters,
      'duration_seconds' : _durationSeconds,
      'updatedAt'        : FieldValue.serverTimestamp(),
    };

    // Compute new key from names (trim + single-space)
    final newKey = _makeKeyFromNames(_originStop!.name, _destStop!.name);
    final oldKey = _selectedRouteKey!;

    if (newKey == oldKey) {
      // Simple update in-place
      await _fs.collection('routes').doc(oldKey).set(mapFields, SetOptions(merge: true));
      _snack('Map route saved');
      await _loadRoute(oldKey);
      return;
    }

    // Key changed: copy meta to new doc, delete old doc, update selection
    final oldDoc = await _fs.collection('routes').doc(oldKey).get();
    final old = oldDoc.data() ?? {};

    // preserve meta
    final newDocData = {
      // meta
      'capacity' : _capacity,
      'busCode'  : _busCodeCtrl.text.trim(),
      'driverId' : _driverIdCtrl.text.trim(),
      'priceSen' : _parsePriceToSen(_priceCtrl.text),
      'times'    : _times,
      'active'   : (old['active'] ?? true),
      // map
      ...mapFields,
    };

    final batch = _fs.batch();
    final newRef = _fs.collection('routes').doc(newKey);
    final oldRef = _fs.collection('routes').doc(oldKey);

    batch.set(newRef, newDocData);
    batch.delete(oldRef);
    await batch.commit();

    _snack('Route updated & replaced: $oldKey → $newKey');

    // refresh dropdown list & select new route
    await _fetchRoutes();
    await _loadRoute(newKey);
  }

  // ====== Create and save stops when picking on the full-screen map ======
  Future<_Stop> _createStopInFirestore({
    required String name, required String code, required double lat, required double lng,
  }) async {
    final ref = await _fs.collection('stops').add({
      'name': name, 'code': code, 'lat': lat, 'lng': lng,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    final s = _Stop(id: ref.id, name: name, code: code, lat: lat, lng: lng);
    _stops = [..._stops, s]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return s;
  }

  // ====== Place search ======
  Future<void> _searchPlace(String query) async {
    if (query.trim().isEmpty) return _snack('Enter a location name');
    setState(() => _searchingPlace = true);

    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/textsearch/json'
          '?query=${Uri.encodeComponent(query)}'
          '&region=my'
          '&location=${_penangCenter.latitude},${_penangCenter.longitude}'
          '&radius=40000'
          '&key=$_directionsKey',
    );

    try {
      final res = await http.get(url);
      final data = json.decode(res.body);
      final results = (data['results'] as List?) ?? [];
      if (res.statusCode != 200 || results.isEmpty) { _snack('No place found'); return; }

      final first = results.first;
      final geo = first['geometry']?['location'] ?? {};
      final name = (first['name'] ?? query).toString();
      final pos = LatLng((geo['lat'] as num).toDouble(), (geo['lng'] as num).toDouble());

      _markers.add(Marker(
        markerId: const MarkerId('search'),
        position: pos,
        infoWindow: InfoWindow(title: name),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ));
      setState(() {});
      await _map?.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
    } catch (_) {
      _snack('Search error');
    } finally {
      if (mounted) setState(() => _searchingPlace = false);
    }
  }

  // ====== Helpers ======
  String _makeKeyFromNames(String oName, String dName) {
    String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${norm(oName)}|${norm(dName)}';
  }

  int _parsePriceToSen(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9\.,]'), '').replaceAll(',', '.');
    final v = double.tryParse(cleaned) ?? 0.0;
    final sen = (v * 100).round();
    return sen < 0 ? 0 : sen;
  }

  String _format12(TimeOfDay tod) {
    final h = tod.hourOfPeriod == 0 ? 12 : tod.hourOfPeriod;
    final m = tod.minute.toString().padLeft(2, '0');
    final suffix = tod.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $suffix';
  }

  String _as24(String t12) {
    final up = t12.toUpperCase().trim();
    final am = up.endsWith('AM');
    final pm = up.endsWith('PM');
    final core = up.replaceAll('AM', '').replaceAll('PM', '').trim();
    final parts = core.split(':');
    int h = int.parse(parts[0]);
    final m = parts.length > 1 ? int.parse(parts[1]) : 0;
    if (pm && h != 12) h += 12;
    if (am && h == 12) h = 0;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  LatLngBounds _boundsFrom(List<LatLng> list) {
    double? minLat, maxLat, minLng, maxLng;
    for (final p in list) {
      minLat = (minLat == null) ? p.latitude : (p.latitude < minLat ? p.latitude : minLat);
      maxLat = (maxLat == null) ? p.latitude : (p.latitude > maxLat ? p.latitude : maxLat);
      minLng = (minLng == null) ? p.longitude : (p.longitude < minLng ? p.longitude : minLng);
      maxLng = (maxLng == null) ? p.longitude : (p.longitude > maxLng ? p.longitude : maxLng);
    }
    return LatLngBounds(southwest: LatLng(minLat!, minLng!), northeast: LatLng(maxLat!, maxLng!));
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route Times'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: _searchingPlace ? 'Searching…' : 'Search place',
            onPressed: _searchingPlace
                ? null
                : () async {
              await showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Search location'),
                  content: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'e.g. INTI College Penang',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => Navigator.pop(context),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Search')),
                  ],
                ),
              );
              final q = _searchCtrl.text.trim();
              if (q.isNotEmpty) await _searchPlace(q);
            },
            icon: const Icon(Icons.search),
          ),
          IconButton(tooltip: 'New Route', onPressed: _createRouteDialog, icon: const Icon(Icons.add_road)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Route picker
            Row(
              children: [
                const Text('Route:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                Expanded(
                  child: _loadingRoutes
                      ? const LinearProgressIndicator()
                      : DropdownButtonFormField<String>(
                    value: _selectedRouteKey,
                    hint: const Text('Select route (Origin|Destination)'),
                    items: _routeKeys.map((k) => DropdownMenuItem(value: k, child: Text(k))).toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      _loadRoute(v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (_selectedRouteKey == null)
              const Expanded(child: Center(child: Text('Pick a route or create a new one')))
            else
              Expanded(
                child: ListView(
                  children: [
                    // ==== Map Route Builder card ====
                    Card(
                      elevation: 1,
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Map Route', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    if (_selectedRouteKey == null) { _snack('Pick a route first'); return; }
                                    // Full-screen picker
                                    final result = await Navigator.of(context).push<_PickerResult>(
                                      MaterialPageRoute(
                                        builder: (_) => _MapPickerPage(
                                          apiKey: _directionsKey,
                                          initialCenter: _originStop != null
                                              ? LatLng(_originStop!.lat, _originStop!.lng)
                                              : (_destStop != null
                                              ? LatLng(_destStop!.lat, _destStop!.lng)
                                              : _defaultCenter),
                                        ),
                                        fullscreenDialog: true,
                                      ),
                                    );
                                    if (result == null) return;

                                    // Create/attach stops
                                    final o = await _createStopInFirestore(
                                      name: result.originName,
                                      code: result.originCode,
                                      lat: result.origin.latitude,
                                      lng: result.origin.longitude,
                                    );
                                    final d = await _createStopInFirestore(
                                      name: result.destName,
                                      code: result.destCode,
                                      lat: result.destination.latitude,
                                      lng: result.destination.longitude,
                                    );

                                    setState(() {
                                      _originStop = o;
                                      _destStop = d;
                                    });

                                    await _buildPreview();          // draw + compute stats
                                    if (_encodedPolyline == null || _encodedPolyline!.isEmpty) {
                                      _snack('No route returned. Try moving pins closer to roads or check API key.');
                                      return;
                                    }
                                    await _saveMapRoute();          // <-- may REPLACE doc if key changed
                                  },
                                  icon: const Icon(Icons.map),
                                  label: const Text('Open Map Picker'),
                                ),
                                const SizedBox(width: 10),
                                if (_distanceMeters != null && _durationSeconds != null)
                                  Text('${(_distanceMeters! / 1000).toStringAsFixed(1)} km  •  ${(_durationSeconds! / 60).round()} mins'),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 220,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: GoogleMap(
                                  initialCameraPosition: CameraPosition(target: _defaultCenter, zoom: 13),
                                  onMapCreated: (c) => _map = c,
                                  markers: _markers,
                                  polylines: _polylines,
                                  myLocationButtonEnabled: false,
                                  zoomControlsEnabled: false,
                                  onTap: (_) async {
                                    final result = await Navigator.of(context).push<_PickerResult>(
                                      MaterialPageRoute(
                                        builder: (_) => _MapPickerPage(
                                          apiKey: _directionsKey,
                                          initialCenter: _originStop != null
                                              ? LatLng(_originStop!.lat, _originStop!.lng)
                                              : (_destStop != null
                                              ? LatLng(_destStop!.lat, _destStop!.lng)
                                              : _defaultCenter),
                                        ),
                                        fullscreenDialog: true,
                                      ),
                                    );
                                    if (result == null) return;

                                    final o = await _createStopInFirestore(
                                      name: result.originName,
                                      code: result.originCode,
                                      lat: result.origin.latitude,
                                      lng: result.origin.longitude,
                                    );
                                    final d = await _createStopInFirestore(
                                      name: result.destName,
                                      code: result.destCode,
                                      lat: result.destination.latitude,
                                      lng: result.destination.longitude,
                                    );

                                    setState(() {
                                      _originStop = o;
                                      _destStop = d;
                                    });

                                    await _buildPreview();
                                    if (_encodedPolyline == null || _encodedPolyline!.isEmpty) {
                                      _snack('No route returned. Try moving pins closer to roads or check API key.');
                                      return;
                                    }
                                    await _saveMapRoute(); // <-- replace if needed
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // capacity / busCode
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _capacityCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Capacity',
                              filled: true,
                              fillColor: Color(0xFFF5F5F5),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _busCodeCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Bus Code (e.g. INTI-01)',
                              filled: true,
                              fillColor: Color(0xFFF5F5F5),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Price (RM)
                    TextFormField(
                      controller: _priceCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Price (RM)',
                        hintText: 'e.g. 5.00',
                        helperText: 'Students will be charged this amount per seat.',
                        filled: true,
                        fillColor: Color(0xFFF5F5F5),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // driver id (optional)
                    TextFormField(
                      controller: _driverIdCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Driver UID (optional)',
                        hintText: 'If set, bookings will use this driverId directly',
                        filled: true,
                        fillColor: Color(0xFFF5F5F5),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    ElevatedButton.icon(
                      onPressed: _saveMeta,
                      icon: const Icon(Icons.save),
                      label: const Text('Save Route Settings'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD32F2F),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: .2),
                      ),
                    ),
                    const SizedBox(height: 18),

                    Row(
                      children: [
                        const Text('Times', style: TextStyle(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        TextButton.icon(onPressed: _addTime, icon: const Icon(Icons.add), label: const Text('Add Time')),
                      ],
                    ),

                    if (_times.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No time slots yet. Tap "Add Time".'),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _times.map((t) {
                          return Chip(label: Text(t), deleteIcon: const Icon(Icons.close), onDeleted: () => _removeTime(t));
                        }).toList(),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/* ===================== FULL-SCREEN MAP PICKER ===================== */

class _MapPickerPage extends StatefulWidget {
  final String apiKey;
  final LatLng initialCenter;
  const _MapPickerPage({required this.apiKey, required this.initialCenter});

  @override
  State<_MapPickerPage> createState() => _MapPickerPageState();
}

class _MapPickerPageState extends State<_MapPickerPage> {
  GoogleMapController? _controller;
  Marker? _o;
  Marker? _d;

  final _oName = TextEditingController(text: 'Origin Stop');
  final _oCode = TextEditingController(text: 'ORIG');
  final _dName = TextEditingController(text: 'Destination Stop');
  final _dCode = TextEditingController(text: 'DEST');

  _PinMode _mode = _PinMode.origin;

  @override
  void dispose() {
    _controller?.dispose();
    _oName.dispose();
    _oCode.dispose();
    _dName.dispose();
    _dCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>{
      if (_o != null) _o!,
      if (_d != null) _d!,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick Origin & Destination'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: () async {
              if (_o == null || _d == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pin both points first')));
                return;
              }
              Navigator.pop(
                context,
                _PickerResult(
                  origin: _o!.position,
                  destination: _d!.position,
                  originName: _oName.text.trim().isEmpty ? 'Origin Stop' : _oName.text.trim(),
                  originCode: _oCode.text.trim(),
                  destName: _dName.text.trim().isEmpty ? 'Destination Stop' : _dName.text.trim(),
                  destCode: _dCode.text.trim(),
                ),
              );
            },
            child: const Text('SAVE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Pin Origin'),
                  selected: _mode == _PinMode.origin,
                  onSelected: (_) => setState(() => _mode = _PinMode.origin),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Pin Destination'),
                  selected: _mode == _PinMode.destination,
                  onSelected: (_) => setState(() => _mode = _PinMode.destination),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Text('Tap map to place pin. Drag to adjust.')),
              ],
            ),
          ),
          // Names / codes inputs
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _oName,
                    decoration: const InputDecoration(labelText: 'Origin name', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _oCode,
                    decoration: const InputDecoration(labelText: 'Code', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dName,
                    decoration: const InputDecoration(labelText: 'Destination name', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _dCode,
                    decoration: const InputDecoration(labelText: 'Code', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: widget.initialCenter, zoom: 14),
              onMapCreated: (c) => _controller = c,
              markers: markers,
              onTap: (pos) {
                setState(() {
                  if (_mode == _PinMode.origin) {
                    _o = Marker(
                      markerId: const MarkerId('o'),
                      position: pos,
                      draggable: true,
                      infoWindow: const InfoWindow(title: 'Origin'),
                      onDragEnd: (p) => _o = _o!.copyWith(positionParam: p),
                    );
                  } else {
                    _d = Marker(
                      markerId: const MarkerId('d'),
                      position: pos,
                      draggable: true,
                      infoWindow: const InfoWindow(title: 'Destination'),
                      onDragEnd: (p) => _d = _d!.copyWith(positionParam: p),
                    );
                  }
                });
              },
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
            ),
          ),
        ],
      ),
    );
  }
}

/* ===================== SUPPORT TYPES ===================== */

enum _PinMode { origin, destination }

class _PickerResult {
  final LatLng origin;
  final LatLng destination;
  final String originName;
  final String originCode;
  final String destName;
  final String destCode;

  _PickerResult({
    required this.origin,
    required this.destination,
    required this.originName,
    required this.originCode,
    required this.destName,
    required this.destCode,
  });
}

/* ===================== STOP MODEL ===================== */

class _Stop {
  final String id;
  final String name;
  final String code;
  final double lat;
  final double lng;

  _Stop({required this.id, required this.name, required this.code, required this.lat, required this.lng});
  @override
  String toString() => '$name ($code)';
}
