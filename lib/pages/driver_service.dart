// lib/pages/driver_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

class DriverService {
  DriverService._();
  static final instance = DriverService._();

  final _fs = FirebaseFirestore.instance;

  // ----------------- helpers -----------------
  String _todayYmd() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  DateTime? _todayAt(String? hhmm) {
    if (hhmm == null || !hhmm.contains(':')) return null;
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, h, m);
  }

  String? _uid() => FirebaseAuth.instance.currentUser?.uid;
  String? _email() => FirebaseAuth.instance.currentUser?.email;

  // ----------------- driver profile -----------------

  /// Live stream of the current driver's profile document.
  Stream<DocumentSnapshot<Map<String, dynamic>>> driverStream() {
    final uid = _uid();
    if (uid == null) return const Stream.empty();
    return _fs.collection('drivers').doc(uid).snapshots();
  }

  /// ✅ Add back this method (called in EditDriverPage)
  Future<void> updateDriver({
    String? name,
    String? phone,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');

    await _fs.collection('drivers').doc(uid).set({
      if (name != null) 'name': name,
      if (phone != null) 'phone': phone,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ----------------- schedule / seats -----------------

  /// ✅ Stream only THIS driver's trips for today (from driver_trips)
  Stream<QuerySnapshot<Map<String, dynamic>>> todayTrips() {
    final uid = _uid()!;
    final ymd = _todayYmd();

    return _fs
        .collection('driver_trips')
        .where('driverId', isEqualTo: uid)
        .where('date', isEqualTo: ymd)
        .snapshots();
  }

  /// Stream of booked seats for a given (driver) trip id.
  Stream<QuerySnapshot<Map<String, dynamic>>> seatsForTrip(String tripId) {
    return _fs
        .collection('booked_seats')
        .where('tripId', isEqualTo: tripId)
        .snapshots();
  }

  // ----------------- issue reporting -----------------

  /// Your existing "log issue" method (kept as-is).
  Future<void> reportIssue({
    required String type,
    String? note,
    String? tripId,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');

    await _fs.collection('issues').add({
      'type': type,
      'note': (note ?? '').trim(),
      'driverId': uid,
      'driverEmail': _email(),
      'tripId': tripId,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// 🔔 NEW: report issue AND notify students on the nearest schedule today.
  /// Uses your deployed callable: `reportDriverIssue`.
  Future<void> reportIssueAndNotify({
    required String type,
    String? note,
    int? delayMinutes,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');

    // 1) Log into your local "issues" collection (kept, optional for audit).
    await reportIssue(type: type, note: note);

    // 2) Fetch today's driver trips (same query you already use).
    final ymd = _todayYmd();
    final qs = await _fs
        .collection('driver_trips')
        .where('driverId', isEqualTo: uid)
        .where('date', isEqualTo: ymd)
        .get();

    if (qs.docs.isEmpty) {
      // Nothing to notify for today.
      return;
    }

    // 3) Pick the nearest schedule (the soonest time >= now; otherwise the latest past one).
    final now = DateTime.now();
    Map<String, dynamic>? chosen;
    DateTime? chosenTime;
    for (final d in qs.docs) {
      final data = d.data();
      final dt = _todayAt(data['time']?.toString());
      if (dt == null) continue;
      // choose the soonest that is >= now
      if (!dt.isBefore(now) && (chosenTime == null || dt.isBefore(chosenTime!))) {
        chosen = data;
        chosenTime = dt;
      }
    }
    // If none upcoming, fallback to the trip with the latest time today
    chosen ??= (() {
      DateTime? latest;
      Map<String, dynamic>? pick;
      for (final d in qs.docs) {
        final data = d.data();
        final dt = _todayAt(data['time']?.toString());
        if (dt == null) continue;
        if (latest == null || dt.isAfter(latest)) {
          latest = dt;
          pick = data;
        }
      }
      return pick;
    })();

    if (chosen == null) {
      // Could not parse any time field safely.
      return;
    }

    // 4) Call the Cloud Function to fan out to students on that exact route/time.
    final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
        .httpsCallable('reportDriverIssue');

    await callable.call(<String, dynamic>{
      'origin': chosen['origin'] ?? '',
      'destination': chosen['destination'] ?? '',
      'date': chosen['date'] ?? ymd, // YYYY-MM-DD
      'time': chosen['time'] ?? '',  // HH:mm
      'type': type,
      'note': (note ?? '').trim(),
      'delayMinutes': delayMinutes ?? 0,
    });
  }

  // ----------------- leave requests -----------------
  Future<void> requestLeave({
    required DateTime from,
    required DateTime to,
    required String reason,
  }) async {
    final uid = _uid();
    if (uid == null) throw Exception('Not signed in.');
    if (to.isBefore(from)) throw Exception('Invalid date range.');

    await _fs.collection('leave_requests').add({
      'driverId': uid,
      'driverEmail': _email(),
      'from': Timestamp.fromDate(from),
      'to': Timestamp.fromDate(to),
      'reason': reason,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
