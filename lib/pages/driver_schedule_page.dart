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
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final trips = snap.data?.docs ?? [];
          if (trips.isEmpty) {
            return const Center(child: Text('No trips today'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: trips.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final t = trips[i].data();
              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.red.shade100,
                    child: const Icon(Icons.access_time, color: Colors.red),
                  ),
                  title: Text('${t['time']}'),
                  subtitle: Text('${t['origin']}  →  ${t['destination']}'),
                  trailing: Text(t['status'] ?? 'scheduled'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
