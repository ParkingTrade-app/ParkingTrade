import 'dart:convert';

class SpotAvailabilityPeriod {
  final String id;
  final String spotId;
  final DateTime startTime;
  final DateTime endTime;
  final bool isRecurring;
  final String? recurringPattern;
  final DateTime createdAt;

  SpotAvailabilityPeriod({
    required this.id,
    required this.spotId,
    required this.startTime,
    required this.endTime,
    this.isRecurring = false,
    this.recurringPattern,
    required this.createdAt,
  });

  factory SpotAvailabilityPeriod.fromJson(Map<String, dynamic> json) {
    return SpotAvailabilityPeriod(
      id: json['id'] as String,
      spotId: json['spot_id'] as String,
      startTime: DateTime.parse(json['start_time'] as String),
      endTime: DateTime.parse(json['end_time'] as String),
      isRecurring: json['is_recurring'] as bool? ?? false,
      recurringPattern: json['recurring_pattern'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'spot_id': spotId,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime.toIso8601String(),
      'is_recurring': isRecurring,
      if (recurringPattern != null) 'recurring_pattern': recurringPattern,
      'created_at': createdAt.toIso8601String(),
    };
  }

  // Check if a requested time period overlaps with this availability period
  // Two periods overlap if: start1 < end2 AND end1 > start2
  // Also handle exact boundary matches (if requested starts exactly when period ends, no overlap)
  bool overlapsWith(DateTime requestedStart, DateTime requestedEnd) {
    // Normalize to UTC for comparison (Supabase stores in UTC)
    final periodStartUtc = startTime.toUtc();
    final periodEndUtc = endTime.toUtc();
    final requestedStartUtc = requestedStart.toUtc();
    final requestedEndUtc = requestedEnd.toUtc();
    
    // Overlap check: requestedStart < periodEnd AND requestedEnd > periodStart
    final overlaps = requestedStartUtc.isBefore(periodEndUtc) && 
                     requestedEndUtc.isAfter(periodStartUtc);
    
    return overlaps;
  }

  /// `until` from a weekly JSON pattern, if present.
  DateTime? get recurrenceUntil {
    if (!isRecurring) return null;
    final raw = recurringPattern?.trim();
    if (raw == null || !raw.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final untilRaw = decoded['until'];
      if (untilRaw is String && untilRaw.isNotEmpty) {
        return DateTime.tryParse(untilRaw);
      }
    } catch (_) {}
    return null;
  }

  /// One-shots expire when `endTime` is not after [now]. Recurring templates
  /// with an `until` expire the same way; templates without `until` never do.
  bool isExpired([DateTime? now]) {
    final t = now ?? DateTime.now();
    if (!isRecurring) return !endTime.isAfter(t);
    final until = recurrenceUntil;
    if (until == null) return false;
    return !until.isAfter(t);
  }
}
