// lib/pages/booking_qr_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class BookingQrPage extends StatefulWidget {
  final String tripId; // This is the trips doc ID
  const BookingQrPage({super.key, required this.tripId});

  @override
  State<BookingQrPage> createState() => _BookingQrPageState();
}

class _BookingQrPageState extends State<BookingQrPage> {
  DocumentSnapshot<Map<String, dynamic>>? _trip;
  List<String> _seats = [];
  String? _error;
  String _payload = '';

  @override
  void initState() {
    super.initState();
    _loadTripAndSeats();
  }

  Future<void> _loadTripAndSeats() async {
    try {
      setState(() {
        _trip = null;
        _seats = [];
        _payload = '';
        _error = null;
      });

      final fs = FirebaseFirestore.instance;
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        setState(() => _error = 'You are not signed in.');
        return;
      }

      // 1) Trip (single doc by id)
      final t = await fs.collection('trips').doc(widget.tripId).get();
      if (!t.exists) {
        setState(() => _error = 'Trip not found: ${widget.tripId}');
        return;
      }
      final data = t.data()!;
      final date = (data['date'] ?? '').toString(); // "YYYY-MM-DD"
      final time = (data['time'] ?? '').toString(); // "HH:mm"
      final tripId = (data['tripId'] ?? widget.tripId).toString();

      // 2) Seats (filter by tripId + studentId to avoid composite index)
      final bs = await fs
          .collection('booked_seats')
          .where('tripId', isEqualTo: tripId)
          .where('studentId', isEqualTo: uid)
          .get();

      final seats = bs.docs
          .map((d) => (d.data()['seatNumber'] as String?) ?? '')
          .where((s) => s.isNotEmpty)
          .toList();

      // 3) Build QR payload (compact & deterministic)
      // RIDEMATE|<tripId>|<uid>|<date>|<time>|<seat,seat,...>
      final parts = <String>['RIDEMATE', tripId, uid, date, time, seats.join(',')];
      final payload = parts.any((p) => p.isEmpty) ? '' : parts.join('|');

      setState(() {
        _trip = t;
        _seats = seats;
        _payload = payload;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      title: const Text('Booking Details'),
      backgroundColor: const Color(0xFFD32F2F),
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          tooltip: 'Reload',
          icon: const Icon(Icons.refresh),
          onPressed: _loadTripAndSeats,
        ),
      ],
    );

    if (_error != null) {
      return Scaffold(
        appBar: appBar,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Text('⚠️ $_error', style: const TextStyle(color: Colors.red)),
          ),
        ),
      );
    }

    if (_trip == null) {
      return Scaffold(appBar: appBar, body: const Center(child: CircularProgressIndicator()));
    }

    final t = _trip!.data()!;
    final origin = (t['origin'] ?? '').toString();
    final destination = (t['destination'] ?? '').toString();
    final date = (t['date'] ?? '').toString();
    final time = (t['time'] ?? '').toString(); // 24h
    final busCode = (t['busCode'] ?? '').toString();
    final status = (t['status'] ?? 'scheduled').toString();

    return Scaffold(
      appBar: appBar,
      backgroundColor: const Color(0xFFFDFDFD),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            // Trip summary card
            Card(
              elevation: 1.5,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: Colors.red.shade100,
                  child: const Icon(Icons.directions_bus, color: Colors.red),
                ),
                title: Text(
                  '$origin → $destination',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('$date  •  $time  •  $busCode'),
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: status == 'scheduled'
                        ? Colors.green.withOpacity(0.12)
                        : Colors.orange.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: status == 'scheduled' ? Colors.green[800] : Colors.orange[800],
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Seats card
            Card(
              elevation: 1.5,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.event_seat),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _seats.isEmpty
                            ? 'No seats found for this booking'
                            : 'Seats: ${_seats.join(', ')}',
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            // QR card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(color: Colors.black12, blurRadius: 12, offset: Offset(0, 5))
                ],
              ),
              child: Column(
                children: [
                  const Text(
                    'Show this QR to the driver',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  const SizedBox(height: 14),

                  if (_payload.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Column(
                        children: [
                          Icon(Icons.qr_code_2, size: 64, color: Colors.black26),
                          SizedBox(height: 10),
                          Text(
                            'QR unavailable.\nMissing tripId / uid / date / time.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.black54),
                          ),
                        ],
                      ),
                    )
                  else
                    Column(
                      children: [
                        QrImageView(
                          data: _payload,
                          version: QrVersions.auto,
                          size: 260,
                          gapless: true,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _payload));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('QR payload copied')),
                            );
                          },
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy payload'),
                        ),
                      ],
                    ),

                  const SizedBox(height: 10),
                  SelectableText(
                    'Payload: $_payload',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.black45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
