import 'package:flutter/material.dart';
import 'driver_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class DriverSchedulePage extends StatelessWidget {
  const DriverSchedulePage({super.key});

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
          // 🔹 Show error if query/index/rules fail
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

          // 🔹 Loading indicator
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          // 🔹 Show trips
          final trips = snap.data?.docs ?? [];
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
              final t = trips[i].data();
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
                    t['time']?.toString() ?? '--:--',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    '${t['origin'] ?? '-'} → ${t['destination'] ?? '-'}',
                  ),
                  trailing: Text(
                    t['status']?.toString() ?? 'scheduled',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
