import 'package:flutter/material.dart';
import 'driver_service.dart';

class EditDriverPage extends StatefulWidget {
  final String name;
  final String phone;
  const EditDriverPage({super.key, required this.name, required this.phone});

  @override
  State<EditDriverPage> createState() => _EditDriverPageState();
}

class _EditDriverPageState extends State<EditDriverPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name);
  late final _phone = TextEditingController(text: widget.phone);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        title: const Text('Edit Profile'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full Name', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Phone', border: OutlineInputBorder()),
                keyboardType: TextInputType.phone,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter phone' : null,
              ),
              const SizedBox(height: 20),
              _saving
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                onPressed: () async {
                  if (!_form.currentState!.validate()) return;
                  setState(() => _saving = true);
                  await DriverService.instance.updateDriver(
                    name: _name.text.trim(),
                    phone: _phone.text.trim(),
                  );
                  if (!mounted) return;
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
