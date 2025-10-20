import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'seat_selection_page.dart';

class SchedulePage extends StatefulWidget {
  final String origin;
  final String destination;
  final String date; // "YYYY-MM-DD" in MYT

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
  List<String> _times = [];
  int _capacity = 15;
  bool _loadingRouteMeta = true;
  String? _loadError;

  String get _routeKey => '${widget.origin.trim()}|${widget.destination.trim()}';

  @override
  void initState() {
    super.initState();
    _loadRouteMeta();
  }

  // ---------------- Firestore route meta ----------------

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

        _times = (timesRaw is List && timesRaw.isNotEmpty)
            ? timesRaw.map((e) => e.toString()).toList()
            : <String>[];

        if (capacity != null && capacity > 0) _capacity = capacity;
      }
    } catch (e) {
      _times = [];
      _loadError = 'Failed to load route info: $e';
    } finally {
      if (mounted) setState(() => _loadingRouteMeta = false);
    }
  }

  // ---------------- MYT helpers (UTC+8) ----------------

  /// Current time in Malaysia (UTC+8).
  DateTime _nowMYT() => DateTime.now().toUtc().add(const Duration(hours: 8));

  /// Format a DateTime as "YYYY-MM-DD".
  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

  /// Parse "YYYY-MM-DD" (assumed MYT calendar, no TZ conversion).
  DateTime? _parseDateYMD(String ymd) {
    try {
      final p = ymd.trim().split('-');
      if (p.length != 3) return null;
      return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    } catch (_) {
      return null;
    }
  }

  /// Parse "7:00 AM" / "07:00" -> (hour24, minute)
  (int, int)? _parseTimeTo24(String raw) {
    final s = raw.trim();
    final m24 = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
    if (m24 != null) {
      return (int.parse(m24.group(1)!), int.parse(m24.group(2)!));
    }
    final up = s.toUpperCase().replaceAll(' ', '');
    final am = up.endsWith('AM');
    final pm = up.endsWith('PM');
    if (am || pm) {
      final core = up.substring(0, up.length - 2);
      final parts = core.split(':');
      int h = int.tryParse(parts[0]) ?? 0;
      final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
      if (pm && h != 12) h += 12; // 1 PM -> 13
      if (am && h == 12) h = 0;   // 12 AM -> 00
      return (h, m);
    }
    return null;
  }

  /// Times to show, filtered by Malaysia "now".
  List<String> _visibleTimes() {
    final nowMYT = _nowMYT();
    final todayMYT = _ymd(nowMYT);
    final selected = widget.date.trim();

    // Convert to minutes since midnight in MYT for robust comparison.
    final nowMinutes = nowMYT.hour * 60 + nowMYT.minute;

    // sort times asc + filter if selected day is today (in MYT)
    final parsed = _times
        .map((t) {
      final hm = _parseTimeTo24(t);
      return (t, hm == null ? -1 : (hm.$1 * 60 + hm.$2));
    })
        .where((e) => e.$2 >= 0)
        .toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));

    if (selected != todayMYT) {
      return parsed.map((e) => e.$1).toList();
    }

    // 2-minute grace window
    const grace = 2;
    return parsed
        .where((e) => e.$2 > nowMinutes + grace)
        .map((e) => e.$1)
        .toList();
  }

  // ---------------- Other helpers ----------------

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
          date: widget.date, // already MYT date string
        ),
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final title = "Depart: ${widget.origin} to ${widget.destination}";
    final times = _visibleTimes();

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // Header
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
                Text(widget.date.trim(),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
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
              Padding(
                padding: const EdgeInsets.all(16),
                child: _InfoCard(
                  icon: Icons.access_time,
                  color: Colors.orange,
                  title: 'No times configured',
                  message:
                  'No departure times have been set for this route yet.\nPlease check again later.',
                ),
              )
            else if (times.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _InfoCard(
                    icon: Icons.update_disabled,
                    color: Colors.grey,
                    title: 'No upcoming trips today',
                    message: 'All earlier departures have passed (MYT).',
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: times.length,
                    itemBuilder: (context, index) {
                      final time = times[index];
                      final scheduleId = _scheduleIdFor(time);

                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('booked_seats')
                            .where('scheduleId', isEqualTo: scheduleId)
                            .where('date', isEqualTo: widget.date.trim())
                            .snapshots(),
                        builder: (context, snapshot) {
                          int bookedCount = 0;
                          if (snapshot.hasData) bookedCount = snapshot.data!.docs.length;

                          final available =
                          (_capacity - bookedCount).clamp(0, _capacity);
                          final isFull = available <= 0;

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
                                        isFull ? 'Full' : '$available Seat(s)',
                                        style: TextStyle(
                                          color:
                                          isFull ? Colors.grey : Colors.green,
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
                                      const Text('15 Min',
                                          style: TextStyle(color: Colors.red)),
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
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
