// lib/pages/route_times_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class RouteTimesPage extends StatefulWidget {
  const RouteTimesPage({super.key});

  @override
  State<RouteTimesPage> createState() => _RouteTimesPageState();
}

class _RouteTimesPageState extends State<RouteTimesPage> {
  final _fs = FirebaseFirestore.instance;

  // route selection
  List<String> _routeKeys = [];
  String? _selectedRouteKey;
  bool _loadingRoutes = true;

  // current route doc fields
  List<String> _times = [];
  int _capacity = 15;
  final _capacityCtrl = TextEditingController(text: '15');
  final _busCodeCtrl = TextEditingController();
  final _driverIdCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchRoutes();
  }

  @override
  void dispose() {
    _capacityCtrl.dispose();
    _busCodeCtrl.dispose();
    _driverIdCtrl.dispose();
    super.dispose();
  }

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

  Future<void> _loadRoute(String key) async {
    setState(() {
      _selectedRouteKey = key;
      _times = [];
      _capacity = 15;
      _capacityCtrl.text = '15';
      _busCodeCtrl.text = '';
      _driverIdCtrl.text = '';
    });

    final doc = await _fs.collection('routes').doc(key).get();
    if (doc.exists) {
      final data = doc.data()!;
      final times = (data['times'] as List?)?.map((e) => e.toString()).toList() ?? [];
      _times = times..sort((a, b) => _as24(a).compareTo(_as24(b)));
      final cap = (data['capacity'] as num?)?.toInt() ?? 15;
      _capacity = cap;
      _capacityCtrl.text = _capacity.toString();
      _busCodeCtrl.text = (data['busCode'] ?? '').toString();
      _driverIdCtrl.text = (data['driverId'] ?? '').toString();
      setState(() {});
    } else {
      // not exist yet — keep defaults until saved
      setState(() {});
    }
  }

  // create a new route quickly
  Future<void> _createRouteDialog() async {
    final o = TextEditingController();
    final d = TextEditingController();
    final b = TextEditingController();

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

    await _fs.collection('routes').doc(key).set({
      'busCode': b.text.trim(),
      'capacity': 15,
      'times': [],
      'active': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _fetchRoutes();
    await _loadRoute(key);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Route "$key" created')));
  }

  // add a time via picker, store as e.g. "7:00 AM"
  Future<void> _addTime() async {
    if (_selectedRouteKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a route first')));
      return;
    }

    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 7, minute: 0),
    );
    if (picked == null) return;

    final t12 = _format12(picked); // "7:00 AM"
    if (_times.contains(t12)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Time already exists')));
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
    if (cap == null || cap <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Capacity must be > 0')));
      return;
    }

    await _fs.collection('routes').doc(_selectedRouteKey).set({
      'capacity': cap,
      'busCode': _busCodeCtrl.text.trim(),
      'driverId': _driverIdCtrl.text.trim(), // optional
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  // helpers: format & sort times
  String _format12(TimeOfDay tod) {
    final h = tod.hourOfPeriod == 0 ? 12 : tod.hourOfPeriod;
    final m = tod.minute.toString().padLeft(2, '0');
    final suffix = tod.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $suffix';
  }

  String _as24(String t12) {
    // parse "7:05 AM" => "07:05" for sorting
    final up = t12.toUpperCase().trim();
    final am = up.endsWith('AM');
    final pm = up.endsWith('PM');
    final core = up.replaceAll('AM', '').replaceAll('PM', '').trim(); // "7:05"
    final parts = core.split(':');
    int h = int.parse(parts[0]);
    final m = parts.length > 1 ? int.parse(parts[1]) : 0;
    if (pm && h != 12) h += 12;
    if (am && h == 12) h = 0;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route Times'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'New Route',
            onPressed: _createRouteDialog,
            icon: const Icon(Icons.add_road),
          ),
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
                    items: _routeKeys
                        .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                        .toList(),
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
              const Expanded(
                child: Center(child: Text('Pick a route or create a new one')),
              )
            else
              Expanded(
                child: ListView(
                  children: [
                    // capacity / busCode / driverId
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
                      ),
                    ),
                    const SizedBox(height: 18),

                    Row(
                      children: [
                        const Text('Times', style: TextStyle(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _addTime,
                          icon: const Icon(Icons.add),
                          label: const Text('Add Time'),
                        ),
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
                          return Chip(
                            label: Text(t),
                            deleteIcon: const Icon(Icons.close),
                            onDeleted: () => _removeTime(t),
                          );
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
