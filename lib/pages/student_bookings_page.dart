import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'booking_qr_page.dart';

class StudentsBookingsPage extends StatefulWidget {
  const StudentsBookingsPage({super.key});

  @override
  State<StudentsBookingsPage> createState() => _StudentsBookingsPageState();
}

class _StudentsBookingsPageState extends State<StudentsBookingsPage> {
  final _user = FirebaseAuth.instance.currentUser;

  // If you created a composite index for: where(studentId) + orderBy(date) + orderBy(time)
  // you can flip this to true to let Firestore sort. Otherwise we sort on the client.
  static const bool USE_FIRESTORE_SORTING = false;

  // Delete past trips automatically (best effort batch). Requires rules allowing the owner to delete their own trip.
  static const bool AUTO_DELETE_PAST = true;

  Stream<QuerySnapshot<Map<String, dynamic>>>? _stream;

  @override
  void initState() {
    super.initState();
    _buildStream();
  }

  void _buildStream() {
    final base = FirebaseFirestore.instance
        .collection('trips')
        .where('studentId', isEqualTo: _user?.uid);

    _stream = USE_FIRESTORE_SORTING
        ? base.orderBy('date').orderBy('time').snapshots()
        : base.snapshots();
    setState(() {});
  }

  // -------- Helpers --------

  /// Parse "YYYY-MM-DD" + "HH:mm" (24h) into a local DateTime.
  DateTime? _parseTripDateTime(String date, String time) {
    try {
      final parts = date.split('-');
      final tparts = time.split(':');
      if (parts.length != 3 || tparts.length != 2) return null;
      final y = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final d = int.parse(parts[2]);
      final hh = int.parse(tparts[0]);
      final mm = int.parse(tparts[1]);
      return DateTime(y, m, d, hh, mm);
    } catch (_) {
      return null;
    }
  }

  /// True if this trip already happened (strictly before "now").
  bool _isPast(Map<String, dynamic> data) {
    final dt = _parseTripDateTime(
      (data['date'] ?? '').toString(),
      (data['time'] ?? '').toString(),
    );
    if (dt == null) return false;
    return dt.isBefore(DateTime.now());
  }

  Future<void> _deletePastTrips(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    if (!AUTO_DELETE_PAST || _user == null) return;

    final fs = FirebaseFirestore.instance;
    final batch = fs.batch();
    int count = 0;

    for (final d in docs) {
      final data = d.data();
      if (_isPast(data)) {
        batch.delete(d.reference);
        count++;
      }
    }
    if (count > 0) {
      try {
        await batch.commit();
      } catch (_) {/* ignore cleanup failures */}
    }
  }

  // -------- UI --------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Bookings'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: _stream == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) {
            final msg = snap.error.toString();
            final isIndexError = msg.contains('failed-precondition') && msg.contains('index');
            return _ErrorCard(
              message: msg,
              onShowWithoutSorting: isIndexError && USE_FIRESTORE_SORTING
                  ? () {
                // fallback to client-sort
                // (Set USE_FIRESTORE_SORTING=false above instead of here)
                _buildStream();
              }
                  : null,
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final all = snap.data!.docs;

          // optional best-effort cleanup
          _deletePastTrips(all);

          // keep only now/future
          final upcoming = all.where((d) => !_isPast(d.data())).toList();

          // local sort ASC by (date, time)
          upcoming.sort((a, b) {
            final ad = a.data(), bd = b.data();
            final at = _parseTripDateTime(
                (ad['date'] ?? '').toString(), (ad['time'] ?? '').toString()) ??
                DateTime.fromMillisecondsSinceEpoch(0);
            final bt = _parseTripDateTime(
                (bd['date'] ?? '').toString(), (bd['time'] ?? '').toString()) ??
                DateTime.fromMillisecondsSinceEpoch(0);
            return at.compareTo(bt);
          });

          if (upcoming.isEmpty) {
            return const Center(
              child: Text('No upcoming bookings.',
                  style: TextStyle(color: Colors.grey, fontSize: 16)),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(14),
            itemCount: upcoming.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final doc = upcoming[i];
              final data = doc.data();

              final origin = (data['origin'] ?? '—').toString();
              final dest = (data['destination'] ?? '—').toString();
              final date = (data['date'] ?? '—').toString(); // "YYYY-MM-DD"
              final time = (data['time'] ?? '—').toString(); // "HH:mm"
              final busCode = (data['busCode'] ?? '—').toString();
              final status = (data['status'] ?? 'scheduled').toString();

              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 2,
                child: ListTile(
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  visualDensity: VisualDensity.compact,
                  leading: CircleAvatar(
                    backgroundColor: Colors.red.shade100,
                    child: const Icon(Icons.directions_bus, color: Color(0xFFD32F2F)),
                  ),
                  title: Text('$origin → $dest',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      '$date  •  $time  •  Bus: $busCode',
                      style: const TextStyle(fontSize: 13, color: Colors.black54),
                    ),
                  ),

                  // ***** Compact trailing to avoid overflow *****
                  trailing: SizedBox(
                    width: 86,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          height: 26,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: status == 'scheduled'
                                    ? Colors.green.withOpacity(0.15)
                                    : Colors.orange.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                status,
                                style: TextStyle(
                                  color: status == 'scheduled'
                                      ? Colors.green[800]
                                      : Colors.orange[800],
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        IconButton(
                          tooltip: 'Show QR',
                          iconSize: 22,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          icon: const Icon(Icons.qr_code_2),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => BookingQrPage(tripId: doc.id),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BookingQrPage(tripId: doc.id),
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

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback? onShowWithoutSorting;

  const _ErrorCard({required this.message, this.onShowWithoutSorting});

  @override
  Widget build(BuildContext context) {
    final isIndexError =
        message.contains('failed-precondition') && message.contains('index');

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 12),
          const Text('Unable to load bookings',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red, fontSize: 12)),
          const SizedBox(height: 16),
          if (isIndexError && onShowWithoutSorting != null)
            ElevatedButton.icon(
              onPressed: onShowWithoutSorting,
              icon: const Icon(Icons.visibility),
              label: const Text('Show without sorting'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
              ),
            ),
        ],
      ),
    );
  }
}
