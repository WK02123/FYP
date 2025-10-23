// lib/pages/student_bookings_page.dart
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
  final _fs = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  /// If true, delete past seats in Firestore (and delete orphan /trips the student created).
  static const bool PURGE_PAST_FROM_DB = true;

  /// Cache trips to avoid repeated reads (key = /trips docId)
  final Map<String, DocumentSnapshot<Map<String, dynamic>>> _tripCache = {};

  @override
  void initState() {
    super.initState();
    _purgePastForUser(); // best-effort cleanup once the page opens
  }

  // -------------------- Trip cache --------------------
  Future<DocumentSnapshot<Map<String, dynamic>>?> _getTrip(String tripId) async {
    if (tripId.isEmpty) return null;
    if (_tripCache.containsKey(tripId)) return _tripCache[tripId];

    var snap = await _fs.collection('trips').doc(tripId).get();

    // backward-compat: some older docs use a generated id and store "tripId" field
    if (!snap.exists) {
      final q = await _fs
          .collection('trips')
          .where('tripId', isEqualTo: tripId)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) snap = q.docs.first;
    }

    if (snap.exists) _tripCache[tripId] = snap;
    return snap.exists ? snap : null;
  }

  // -------------------- Time parsing --------------------
  /// Returns a local DateTime from date (YYYY-MM-DD) and time which may be
  /// "HH:mm" or "h:mm AM/PM". Returns null if it can’t parse.
  DateTime? _parseLocal(String date, String timeRaw) {
    if (date.isEmpty || timeRaw.isEmpty) return null;
    String t = timeRaw.trim();

    // AM/PM?
    final hasAmPm = RegExp(r'(AM|PM)$', caseSensitive: false)
        .hasMatch(t.replaceAll(' ', ''));
    if (hasAmPm) {
      final up = t.toUpperCase().replaceAll(' ', '');
      final am = up.endsWith('AM');
      final pm = up.endsWith('PM');
      final core = up.substring(0, up.length - 2); // "1:05" or "1"
      final parts = core.split(':');
      int h = int.tryParse(parts[0]) ?? 0;
      final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
      if (pm && h != 12) h += 12;
      if (am && h == 12) h = 0;
      t = '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    } else if (!t.contains(':')) {
      // "13" -> "13:00"
      final hh = int.tryParse(t) ?? 0;
      t = '${hh.toString().padLeft(2, '0')}:00';
    }

    return DateTime.tryParse('${date}T$t:00');
  }

  // -------------------- scheduleId variants (legacy support) --------------------
  List<String> _scheduleIdCandidates({
    required String origin,
    required String destination,
    required String timeRaw, // "13:00" or "1:00 PM"
  }) {
    String noSpace(String s) => s.replaceAll(' ', '');
    String to12h(String time24) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time24.trim());
      if (m == null) return time24;
      var h = int.tryParse(m.group(1)!) ?? 0;
      final min = m.group(2)!;
      final am = h < 12;
      if (h == 0) h = 12;
      if (h > 12) h -= 12;
      return '$h:$min ${am ? 'AM' : 'PM'}';
    }

    final ori = origin.trim();
    final dst = destination.trim();
    final dstNo = noSpace(dst);

    final up = timeRaw.trim();
    final hasAmPm =
        up.toUpperCase().endsWith('AM') || up.toUpperCase().endsWith('PM');
    final t12 = hasAmPm ? up.toUpperCase() : to12h(up).toUpperCase();
    final t24NoColon = up.replaceAll(':', '');
    final t12NoSpace = t12.replaceAll(' ', '');
    final t12NoColon = t12.replaceAll(':', '');
    final t12NoColonNoSpace = t12NoColon.replaceAll(' ', '');

    final set = <String>{
      '${ori}_${dst}_$up',
      '${ori}_${dstNo}_$up',
      '${ori}_${dst}_$t24NoColon',
      '${ori}_${dstNo}_$t24NoColon',
      '${ori}_${dst}_$t12',
      '${ori}_${dstNo}_$t12',
      '${ori}_${dst}_$t12NoSpace',
      '${ori}_${dstNo}_$t12NoSpace',
      '${ori}_${dstNo}_$t12NoColonNoSpace',
    };
    return set.take(10).toList(); // Firestore whereIn limit
  }

  // -------------------- Delete a /trips doc and subcollections --------------------
  Future<void> _deleteTripCompletely(
      DocumentReference<Map<String, dynamic>> tripRef) async {
    final tripId = tripRef.id;

    // delete scans/*
    final scans = await tripRef.collection('scans').get();
    for (int i = 0; i < scans.docs.length; i += 400) {
      final part = scans.docs.sublist(
          i, (i + 400 > scans.docs.length) ? scans.docs.length : i + 400);
      final b = _fs.batch();
      for (final d in part) {
        b.delete(d.reference);
      }
      await b.commit();
    }

    // delete boardings with this tripId
    final bq = await _fs
        .collection('boardings')
        .where('tripId', isEqualTo: tripId)
        .get();
    for (int i = 0; i < bq.docs.length; i += 400) {
      final part = bq.docs
          .sublist(i, (i + 400 > bq.docs.length) ? bq.docs.length : i + 400);
      final b = _fs.batch();
      for (final d in part) {
        b.delete(d.reference);
      }
      await b.commit();
    }

    await tripRef.delete();
  }

  // -------------------- After seat deletion, remove orphan trips --------------------
  Future<void> _maybeDeleteOrphanTrip(String tripId) async {
    if (tripId.isEmpty) return;
    final snap = await _getTrip(tripId);
    if (snap == null || !snap.exists) return;

    final t = snap.data()!;
    final uid = _auth.currentUser?.uid;

    // Only delete trips created by THIS student
    if (uid == null || (t['studentId'] ?? '') != uid) return;

    final origin = (t['origin'] ?? '').toString();
    final dest = (t['destination'] ?? '').toString();
    final time = (t['time'] ?? t['time12'] ?? '').toString();

    // Is there any seat left?
    bool anyLeft = false;

    // a) modern linkage by tripId
    final qTripId = await _fs
        .collection('booked_seats')
        .where('tripId', isEqualTo: tripId)
        .limit(1)
        .get();
    anyLeft = qTripId.docs.isNotEmpty;

    // b) legacy scheduleId variants
    if (!anyLeft && origin.isNotEmpty && dest.isNotEmpty && time.isNotEmpty) {
      final cands = _scheduleIdCandidates(
          origin: origin, destination: dest, timeRaw: time);
      for (int i = 0; i < cands.length && !anyLeft; i += 10) {
        final chunk =
        cands.sublist(i, (i + 10 > cands.length) ? cands.length : i + 10);
        final q = await _fs
            .collection('booked_seats')
            .where('scheduleId', whereIn: chunk)
            .limit(1)
            .get();
        anyLeft = q.docs.isNotEmpty;
      }
    }

    if (!anyLeft) {
      await _deleteTripCompletely(snap.reference);
      _tripCache.remove(tripId);
    }
  }

  // -------------------- Purge past seats (and orphan trips) --------------------
  Future<void> _purgePastForUser() async {
    if (!PURGE_PAST_FROM_DB) return;
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    final snap = await _fs
        .collection('booked_seats')
        .where('studentId', isEqualTo: uid)
        .get();

    if (snap.docs.isEmpty) return;

    final toDelete = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final affectedTripIds = <String>{};

    for (final d in snap.docs) {
      final s = d.data();
      final tripId = (s['tripId'] ?? '').toString();
      affectedTripIds.add(tripId);

      // Prefer trip's canonical date/time
      String date = '';
      String time = '';
      final trip = await _getTrip(tripId);
      if (trip != null && trip.exists) {
        final t = trip.data()!;
        date = (t['date'] ?? '').toString();
        time = (t['time'] ?? t['time12'] ?? '').toString();
      }
      if (date.isEmpty) date = (s['date'] ?? '').toString();
      if (time.isEmpty) time = (s['time'] ?? s['time12'] ?? s['time24'] ?? '').toString();

      final dt = _parseLocal(date, time);
      if (dt == null) continue;

      // leave 1-minute grace
      if (dt.isBefore(DateTime.now().subtract(const Duration(minutes: 1)))) {
        toDelete.add(d);
      }
    }

    // Batch-delete past seats
    if (toDelete.isNotEmpty) {
      const chunk = 400;
      for (int i = 0; i < toDelete.length; i += chunk) {
        final part = toDelete.sublist(
            i, (i + chunk > toDelete.length) ? toDelete.length : i + chunk);
        final b = _fs.batch();
        for (final d in part) b.delete(d.reference);
        try {
          await b.commit();
        } catch (e) {
          debugPrint('Purge seats failed: $e');
        }
      }
    }

    // Remove orphan /trips created by this student
    for (final tripId in affectedTripIds) {
      await _maybeDeleteOrphanTrip(tripId);
    }
  }

  // -------------------- Build each row (one seat = one card) --------------------
  Future<_SeatRow?> _buildRow(
      QueryDocumentSnapshot<Map<String, dynamic>> seatDoc) async {
    final s = seatDoc.data();
    final tripId = (s['tripId'] ?? '').toString();

    final tripSnap = await _getTrip(tripId);
    final trip = tripSnap?.data();

    final date = ((trip?['date'] ?? s['date']) ?? '').toString();
    final time =
    ((trip?['time'] ?? s['time'] ?? s['time12'] ?? s['time24']) ?? '')
        .toString();
    final origin = ((s['origin'] ?? trip?['origin']) ?? '').toString();
    final destination =
    ((s['destination'] ?? trip?['destination']) ?? '').toString();

    final dt = _parseLocal(date, time);
    if (dt == null) return null; // skip unparseable rows

    return _SeatRow(
      id: seatDoc.id, // booked_seats doc id
      tripId: tripId, // /trips doc id
      seat: (s['seatNumber'] ?? '').toString(),
      date: date,
      time: time,
      origin: origin,
      destination: destination,
      busCode: (trip?['busCode'] ?? '').toString(),
      status: (trip?['status'] ?? 'scheduled').toString(),
      dt: dt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Please sign in')));
    }

    final stream = _fs
        .collection('booked_seats')
        .where('studentId', isEqualTo: uid)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Bookings'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh & purge',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _purgePastForUser();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child:
                Text('Error: ${snap.error}', textAlign: TextAlign.center),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final seatDocs = snap.data!.docs;

          return FutureBuilder<List<_SeatRow?>>(
            future: Future.wait(seatDocs.map(_buildRow)),
            builder: (context, rowsSnap) {
              if (rowsSnap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              // Keep only upcoming (>= now - 1 min)
              final rows = rowsSnap.data
                  ?.whereType<_SeatRow>()
                  ?.where((r) => !r.dt
                  .isBefore(DateTime.now().subtract(const Duration(minutes: 1))))
                  .toList() ??
                  [];

              // Sort by soonest first
              rows.sort((a, b) => a.dt.compareTo(b.dt));

              if (rows.isEmpty) {
                return const Center(
                  child: Text(
                    'No upcoming bookings.',
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _BookingCard(row: rows[i]),
              );
            },
          );
        },
      ),
    );
  }
}

class _SeatRow {
  final String id;        // booked_seats doc id
  final String tripId;    // /trips doc id
  final String seat;
  final String date;
  final String time;
  final String origin;
  final String destination;
  final String busCode;
  final String status;
  final DateTime dt;
  _SeatRow({
    required this.id,
    required this.tripId,
    required this.seat,
    required this.date,
    required this.time,
    required this.origin,
    required this.destination,
    required this.busCode,
    required this.status,
    required this.dt,
  });
}

class _BookingCard extends StatelessWidget {
  final _SeatRow row;
  const _BookingCard({required this.row});

  @override
  Widget build(BuildContext context) {
    void openQr() {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookingQrPage(
            tripId: row.tripId,
            seatDocId: row.id, // show QR for this specific seat
          ),
        ),
      );
    }

    return Card(
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: openQr,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: Colors.red.shade100,
                child:
                const Icon(Icons.directions_bus, color: Color(0xFFD32F2F)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${row.origin.isEmpty ? '—' : row.origin} → ${row.destination.isEmpty ? '—' : row.destination}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${row.date}  •  ${row.time}'
                          '${row.busCode.isNotEmpty ? '  •  ${row.busCode}' : ''}\n'
                          'Seat: ${row.seat}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.black54,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: row.status == 'scheduled'
                          ? Colors.green.withOpacity(0.15)
                          : Colors.orange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      row.status,
                      style: TextStyle(
                        color: row.status == 'scheduled'
                            ? Colors.green[800]
                            : Colors.orange[800],
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  IconButton(
                    tooltip: 'Show QR',
                    iconSize: 22,
                    padding: EdgeInsets.zero,
                    constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.qr_code_2),
                    onPressed: openQr,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
