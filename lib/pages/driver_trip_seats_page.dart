// lib/pages/driver_trip_seats_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class DriverTripSeatsPage extends StatelessWidget {
  final String tripId;                 // DRIVER /trips doc id
  final Map<String, dynamic>? trip;    // optional
  const DriverTripSeatsPage({super.key, required this.tripId, this.trip});

  @override
  Widget build(BuildContext context) {
    final fs = FirebaseFirestore.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip Seats'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        // NOTE: no orderBy here -> no composite index needed
        stream: fs
            .collection('booked_seats')
            .where('tripId', isEqualTo: tripId)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          // Sort locally by seatNumber like A1 < A2 < A10 < B1...
          final docs = [...snap.data!.docs];
          docs.sort((a, b) => _seatCompare(
            (a.data()['seatNumber'] ?? '').toString(),
            (b.data()['seatNumber'] ?? '').toString(),
          ));

          final total = docs.length;
          final boarded = docs
              .where((d) => (d.data()['status'] ?? '') == 'boarded')
              .length;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    _MetricChip(label: 'Total', value: '$total'),
                    const SizedBox(width: 8),
                    _MetricChip(label: 'Boarded', value: '$boarded'),
                    const SizedBox(width: 8),
                    _MetricChip(label: 'Remaining', value: '${total - boarded}'),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final d = docs[i].data();
                    final seat = (d['seatNumber'] ?? '').toString();
                    final status = (d['status'] ?? 'reserved').toString();
                    final isBoarded = status == 'boarded';

                    final name = (d['studentName'] ?? '').toString().trim();
                    final sid = (d['studentId'] ?? '').toString();
                    final display = name.isEmpty ? sid : name;

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                        isBoarded ? Colors.green : Colors.blueGrey,
                        child: Text(
                          seat.isEmpty ? '?' : seat,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                      title: Text(display,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        isBoarded ? 'Boarded' : 'Reserved',
                        style: TextStyle(
                          color: isBoarded ? Colors.green[800] : Colors.orange[800],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: isBoarded
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : const Icon(Icons.schedule, color: Colors.orange),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// Compare seat labels like "A1", "A10", "B2"
int _seatCompare(String a, String b) {
  final ra = RegExp(r'^([A-Za-z]+)(\d+)$');
  final ma = ra.firstMatch(a.trim());
  final mb = ra.firstMatch(b.trim());
  if (ma != null && mb != null) {
    final la = ma.group(1)!.toUpperCase();
    final lb = mb.group(1)!.toUpperCase();
    if (la != lb) return la.compareTo(lb);
    final na = int.tryParse(ma.group(2)!) ?? 0;
    final nb = int.tryParse(mb.group(2)!) ?? 0;
    return na.compareTo(nb);
  }
  // fallback: plain string compare
  return a.compareTo(b);
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  const _MetricChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(color: Colors.black54)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
