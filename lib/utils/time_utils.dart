// lib/utils/time_utils.dart
//
// Converts between 12-hour ("7:00 PM") and 24-hour ("19:00") time strings.

String to24h(String raw) {
  final s = raw.trim();
  // Already 24 h?
  final m24 = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s);
  if (m24 != null) {
    final h = int.parse(m24.group(1)!);
    final mm = m24.group(2)!;
    return '${h.toString().padLeft(2, '0')}:$mm';
  }

  // Handle “7:00 PM” or “07:00 am”
  final m12 = RegExp(r'^(\d{1,2}):(\d{2})\s*(AM|PM)$', caseSensitive: false).firstMatch(s);
  if (m12 == null) return s;
  var h = int.parse(m12.group(1)!);
  final mm = m12.group(2)!;
  final ap = m12.group(3)!.toUpperCase();
  if (ap == 'PM' && h != 12) h += 12;
  if (ap == 'AM' && h == 12) h = 0;
  return '${h.toString().padLeft(2, '0')}:$mm';
}

String prettyTime(String hhmm) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
  if (m == null) return hhmm;
  var h = int.parse(m.group(1)!);
  final mm = m.group(2)!;
  final ap = h >= 12 ? 'PM' : 'AM';
  if (h == 0) h = 12;
  if (h > 12) h -= 12;
  return '$h:$mm $ap';
}
