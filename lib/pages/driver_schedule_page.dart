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

  // Convert "1:00 PM" -> "13:00"
  String? _to24h(String? time12) {
    if (time12 == null) return null;
    final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*(AM|PM)\s*$',
        caseSensitive: false)
        .firstMatch(time12);
    if (m == null) return null;
    var h = int.parse(m.group(1)!);
    final mm = m.group(2)!;
    final ap = m.group(3)!.toUpperCase();
    if (ap == 'PM' && h < 12) h += 12;
    if (ap == 'AM' && h == 12) h = 0;
    return '${h.toString().padLeft(2, '0')}:$mm';
  }

  /// Combine trip's `date` (YYYY-MM-DD) and `time` (HH:mm or "h:mm AM/PM")
  /// into a local DateTime. Returns null if it can’t parse.
  DateTime? _tripDateTime(Map<String, dynamic> t) {
    final date = (t['date'] ?? '').toString();
    if (date.isEmpty) return null;

    String? hhmm = t['time']?.toString();
    hhmm ??= _to24h(t['time12']?.toString());
    if (hhmm == null) return null;

    try {
      // ISO 8601 local time (seconds optional)
      return DateTime.parse('${date}T$hhmm:00');
    } catch (_) {
      return null;
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
        // reads from driver_trips via service (today)
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

          final now = DateTime.now();

          // Filter out past trips and sort by time ascending
          final upcoming = (snap.data?.docs ?? [])
              .where((d) {
            final t = d.data();
            final dt = _tripDateTime(t);
            if (dt == null) return true; // if we can’t parse, keep it visible
            return !dt.isBefore(now);
          })
              .toList()
            ..sort((a, b) {
              final ta = _tripDateTime(a.data());
              final tb = _tripDateTime(b.data());
              if (ta == null && tb == null) return 0;
              if (ta == null) return 1;
              if (tb == null) return -1;
              return ta.compareTo(tb);
            });

          if (upcoming.isEmpty) {
            return const Center(
              child: Text(
                'No upcoming trips',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: upcoming.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final doc = upcoming[i];
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
                    stream: DriverService.instance.seatsForTrip(tripId),
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
