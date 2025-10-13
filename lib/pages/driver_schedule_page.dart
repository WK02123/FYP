import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'driver_service.dart';
import 'driver_trip_seats_page.dart';

class DriverSchedulePage extends StatelessWidget {
  const DriverSchedulePage({super.key});

  String _prettyDate(String? ymd) {
    if (ymd == null || ymd.isEmpty) return '--';
    try {
      final dt = DateTime.parse(ymd);
      const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${dt.day} ${m[dt.month - 1]} ${dt.year}';
    } catch (_) {
      return ymd;
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = DriverService.instance;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFD32F2F),
        title: const Text("Schedule"),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: svc.todayTrips(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Error loading trips:\n${snap.error}',
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          // 🔎 Filter out student copies (those that have studentId / studentEmail)
          final all = snap.data?.docs ?? [];
          final trips = all.where((d) {
            final t = d.data();
            final looksStudent =
                t.containsKey('studentId') || t.containsKey('studentEmail');
            return !looksStudent; // keep only driver copies
          }).toList();

          if (trips.isEmpty) {
            return const Center(
              child: Text(
                'No trips today',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: trips.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final doc = trips[i];
              final t = doc.data();
              final tripId = doc.id;

              final dateStr = _prettyDate(t['date']?.toString());
              final timeStr = (t['time'] ?? t['time12'] ?? '--:--').toString();
              final origin = (t['origin'] ?? '-').toString();
              final dest = (t['destination'] ?? '-').toString();

              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.red.shade100,
                    child: const Icon(Icons.access_time, color: Colors.red),
                  ),
                  title: Text(
                    '$dateStr • $timeStr',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('$origin → $dest'),

                  // live booked-seat count
                  trailing: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: svc.seatsForTrip(tripId),
                    builder: (context, seatSnap) {
                      if (!seatSnap.hasData) {
                        return const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        );
                      }
                      final count = seatSnap.data!.docs.length;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.red.shade100),
                        ),
                        child: Text(
                          '$count booked',
                          style: const TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),

                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DriverTripSeatsPage(tripId: tripId, trip: t),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
