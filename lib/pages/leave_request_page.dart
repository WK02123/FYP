import 'package:flutter/material.dart';
import 'driver_service.dart';

class LeaveRequestPage extends StatefulWidget {
  const LeaveRequestPage({super.key});

  @override
  State<LeaveRequestPage> createState() => _LeaveRequestPageState();
}

class _LeaveRequestPageState extends State<LeaveRequestPage> {
  DateTime? _from;
  DateTime? _to;
  final _reason = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool from}) async {
    final now = DateTime.now();
    final result = await showDatePicker(
      context: context,
      initialDate: from ? (_from ?? now) : (_to ?? _from ?? now),
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (result != null) {
      setState(() {
        if (from) {
          _from = result;
          if (_to != null && _to!.isBefore(_from!)) _to = _from;
        } else {
          _to = result;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateText = (_from == null || _to == null)
        ? 'Select date range'
        : '${_from!.toString().split(' ').first} → ${_to!.toString().split(' ').first}';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        title: const Text('Request Leave / MC'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.date_range, color: Colors.red),
              title: Text(dateText),
              onTap: () async {
                await _pickDate(from: true);
                if (mounted && _from != null) await _pickDate(from: false);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Reason',
                border: OutlineInputBorder(),
                hintText: 'MC / Personal / Other...',
              ),
            ),
            const SizedBox(height: 20),
            _sending
                ? const CircularProgressIndicator()
                : ElevatedButton(
              onPressed: () async {
                if (_from == null || _to == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please select date range')),
                  );
                  return;
                }
                setState(() => _sending = true);
                await DriverService.instance.requestLeave(
                  from: DateTime(_from!.year, _from!.month, _from!.day, 0, 0),
                  to: DateTime(_to!.year, _to!.month, _to!.day, 23, 59),
                  reason: _reason.text.trim().isEmpty ? 'N/A' : _reason.text.trim(),
                );
                if (!mounted) return;
                setState(() => _sending = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Leave request sent')),
                );
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );
  }
}
