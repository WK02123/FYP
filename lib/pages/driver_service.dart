import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class DriverService {
  DriverService._();
  static final instance = DriverService._();

  final _fs = FirebaseFirestore.instance;
  String get uid => FirebaseAuth.instance.currentUser!.uid;

  Stream<DocumentSnapshot<Map<String, dynamic>>> driverStream() {
    return _fs.collection('drivers').doc(uid).snapshots();
  }

  Future<void> updateDriver({
    required String name,
    required String phone,
  }) async {
    await _fs.collection('drivers').doc(uid).set({
      'name': name,
      'phone': phone,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  String todayKey() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> todayTrips() {
    return _fs.collection('trips')
        .where('driverId', isEqualTo: uid)
        .where('date', isEqualTo: todayKey())
        .orderBy('time')
        .snapshots();
  }

  Future<void> reportIssue({
    required String type,
    String? note,
    String? tripId,
  }) async {
    await _fs.collection('issues').add({
      'driverId': uid,
      'type': type,
      'note': note ?? '',
      'tripId': tripId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> requestLeave({
    required DateTime from,
    required DateTime to,
    required String reason,
  }) async {
    await _fs.collection('leaves').add({
      'driverId': uid,
      'from': Timestamp.fromDate(from),
      'to': Timestamp.fromDate(to),
      'reason': reason,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
