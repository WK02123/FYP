// lib/pages/driver_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
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
