import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'seat_selection_page.dart';

class SchedulePage extends StatefulWidget {
  final String origin;
  final String destination;
  final String date;

  const SchedulePage({
    super.key,
    required this.origin,
    required this.destination,
    required this.date,
  });

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  /// Route-configured times (admin-managed). No defaults.
  List<String> _times = [];
  int _capacity = 15; // safe fallback if not set on route
  bool _loadingRouteMeta = true;
  String? _loadError;

  String get _routeKey => '${widget.origin.trim()}|${widget.destination.trim()}';

  @override
  void initState() {
    super.initState();
    _loadRouteMeta();
  }

  Future<void> _loadRouteMeta() async {
    setState(() {
      _loadingRouteMeta = true;
      _loadError = null;
    });

    try {
      final doc = await FirebaseFirestore.instance
          .collection('routes')
          .doc(_routeKey)
          .get();

      if (!doc.exists) {
        _times = [];
        _loadError = 'No route found for $_routeKey';
      } else {
        final data = doc.data()!;
        final timesRaw = data['times'];
        final capacity = (data['capacity'] as num?)?.toInt();

        // Only use times if admin provided them
        if (timesRaw is List && timesRaw.isNotEmpty) {
          _times = timesRaw.map((e) => e.toString()).toList();
        } else {
          _times = []; // explicitly empty when admin hasn't added times
        }
        if (capacity != null && capacity > 0) _capacity = capacity;
      }
    } catch (e) {
      _times = [];
      _loadError = 'Failed to load route info: $e';
    } finally {
      if (mounted) setState(() => _loadingRouteMeta = false);
    }
  }

  /// Build the same scheduleId you use in booked_seats
  String _scheduleIdFor(String time) {
    final o = widget.origin.replaceAll(' ', '');
    final d = widget.destination.replaceAll(' ', '');
    final t = time.replaceAll(' ', '');
    return '${o}_${d}_$t';
  }

  void _openSeatSelection(String time) {
    final scheduleId = _scheduleIdFor(time);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeatSelectionPage(
          scheduleId: scheduleId,
          origin: widget.origin,
          destination: widget.destination,
          time: time,
          date: widget.date,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = "Depart: ${widget.origin} to ${widget.destination}";

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // 🔴 Top App Bar (original design)
          Container(
            width: double.infinity,
            height: 100,
            padding: const EdgeInsets.only(left: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFD32F2F),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                )
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Date row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.calendar_month, color: Colors.red),
                const SizedBox(width: 6),
                Text(
                  widget.date,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (_loadingRouteMeta)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_loadError != null)
          // Error state
            Padding(
              padding: const EdgeInsets.all(16),
              child: _InfoCard(
                icon: Icons.error_outline,
                color: Colors.red,
                title: 'Unable to load schedule',
                message: _loadError!,
                actionLabel: 'Retry',
                onAction: _loadRouteMeta,
              ),
            )
          else if (_times.isEmpty)
            // Empty state (admin hasn’t set times)
              Padding(
                padding: const EdgeInsets.all(16),
                child: _InfoCard(
                  icon: Icons.access_time,
                  color: Colors.orange,
                  title: 'No times configured',
                  message:
                  'No departure times have been set for this route yet.\n'
                      'Please check again later.',
                ),
              )
            else
            // 🚌 Bus Times List (tap a card -> SeatSelectionPage)
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _times.length,
                  itemBuilder: (context, index) {
                    final time = _times[index];
                    final scheduleId = _scheduleIdFor(time);

                    return StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('booked_seats')
                          .where('scheduleId', isEqualTo: scheduleId)
                          .where('date', isEqualTo: widget.date)
                          .snapshots(),
                      builder: (context, snapshot) {
                        int bookedCount = 0;
                        if (snapshot.hasData) {
                          bookedCount = snapshot.data!.docs.length;
                        }

                        final availableSeats =
                        (_capacity - bookedCount).clamp(0, _capacity);
                        final isFull = availableSeats <= 0;

                        return GestureDetector(
                          onTap: isFull ? null : () => _openSeatSelection(time),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 10),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(15),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black12,
                                  blurRadius: 6,
                                  offset: Offset(0, 3),
                                ),
                              ],
                              border: Border.all(
                                color: isFull
                                    ? Colors.grey.shade300
                                    : Colors.transparent,
                                width: 1.2,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      time,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      isFull
                                          ? 'Full'
                                          : '$availableSeats Seat(s)',
                                      style: TextStyle(
                                        color: isFull
                                            ? Colors.grey
                                            : Colors.green,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(widget.origin),
                                    const Text(
                                      '15 Min',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                    Text(widget.destination),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _InfoCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Icon(icon, color: color, size: 36),
            const SizedBox(height: 10),
            Text(title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color,
                )),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black87),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: color.withOpacity(0.5)),
                ),
                child: Text(actionLabel!,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
