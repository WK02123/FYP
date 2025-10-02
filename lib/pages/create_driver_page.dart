// lib/pages/create_driver_page.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'admin_helpers.dart';

class CreateDriverPage extends StatefulWidget {
  const CreateDriverPage({super.key});
  @override
  State<CreateDriverPage> createState() => _CreateDriverPageState();
}

class _CreateDriverPageState extends State<CreateDriverPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _bus = TextEditingController();
  final _pass = TextEditingController();

  bool _sending = false;
  bool _sendVerification = true;

  // routes
  final Set<String> _selectedRouteKeys = {};
  List<String> _allRouteKeys = [];
  bool _loadingRoutes = true;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('routes').get();
      _allRouteKeys = snap.docs.map((d) => d.id).toList()..sort();
    } catch (_) {
      _allRouteKeys = [];
    } finally {
      if (mounted) setState(() => _loadingRoutes = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _bus.dispose();
    _pass.dispose();
    super.dispose();
  }

  String? _emailV(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Email required';
    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
    if (!ok) return 'Invalid email';
    return null;
  }

  String? _phoneV(String? v) {
    final s = (v ?? '').replaceAll(' ', '');
    if (s.isEmpty) return 'Phone required';
    final ok = RegExp(r'^\+?6?0\d{8,10}$').hasMatch(s);
    if (!ok) return 'Enter MY phone (e.g. +60123456789)';
    return null;
  }

  String? _passV(String? v) => (v == null || v.length < 6) ? 'Min 6 chars' : null;

  String _routeKey(String a, String b) => '${a.trim()}|${b.trim()}';

  Future<void> _addNewRouteDialog() async {
    final origin = TextEditingController();
    final dest = TextEditingController();
    final busCode = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Route'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: origin,
              decoration: const InputDecoration(
                labelText: 'Origin',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: dest,
              decoration: const InputDecoration(
                labelText: 'Destination',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: busCode,
              decoration: const InputDecoration(
                labelText: 'Bus Code (e.g. INTI-01)',
                border: OutlineInputBorder(),
              ),
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

    final key = _routeKey(origin.text, dest.text);
    if (key.trim().isEmpty) return;

    try {
      await FirebaseFirestore.instance.collection('routes').doc(key).set({
        'busCode': busCode.text.trim(),
        'active': true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // refresh + select the new route
      await _loadRoutes();
      setState(() => _selectedRouteKeys.add(key));

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Route "$key" added')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add route: $e')),
      );
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (_selectedRouteKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one route')),
      );
      return;
    }

    setState(() => _sending = true);

    final msg = await adminCreateDriverAccount(
      email: _email.text,
      password: _pass.text,
      name: _name.text,
      phone: _phone.text,
      busCode: _bus.text,
      routes: _selectedRouteKeys.toList(), // <-- pass selected routes
      attachDriverToRoutes: true,          // also write driverId into those route docs
      sendVerification: _sendVerification,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    setState(() => _sending = false);

    if (msg.toLowerCase().startsWith('driver created')) {
      Navigator.pop(context); // back to Admin page
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Driver'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _f('Full Name', _name, validator: (v) => v!.trim().isEmpty ? 'Name required' : null),
            _f('Email', _email, keyboard: TextInputType.emailAddress, validator: _emailV),
            _f('Phone (+60 …)', _phone, keyboard: TextInputType.phone, validator: _phoneV),
            _f('Bus Code (e.g. INTI-01)', _bus),
            _f('Temp Password', _pass, isPassword: true, validator: _passV),

            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Assign Routes', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addNewRouteDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Route'),
                ),
              ],
            ),
            const SizedBox(height: 6),

            if (_loadingRoutes)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_allRouteKeys.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No routes yet. Tap "Add Route" to create one.'),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _allRouteKeys.map((key) {
                  final selected = _selectedRouteKeys.contains(key);
                  return FilterChip(
                    selected: selected,
                    label: Text(key),
                    onSelected: (v) {
                      setState(() {
                        if (v) {
                          _selectedRouteKeys.add(key);
                        } else {
                          _selectedRouteKeys.remove(key);
                        }
                      });
                    },
                    selectedColor: Colors.red.shade100,
                    checkmarkColor: Colors.red,
                  );
                }).toList(),
              ),

            const SizedBox(height: 12),
            SwitchListTile(
              value: _sendVerification,
              onChanged: (v) => setState(() => _sendVerification = v),
              title: const Text('Send verification email'),
              subtitle: const Text('Driver must verify before first login'),
            ),

            const SizedBox(height: 8),
            _sending
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.person_add),
              label: const Text('Create Driver'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: const Color(0xFFD32F2F),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _f(
      String label,
      TextEditingController c, {
        TextInputType? keyboard,
        bool isPassword = false,
        String? Function(String?)? validator,
      }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        obscureText: isPassword,
        keyboardType: keyboard,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFFF5F5F5),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}
