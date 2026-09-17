import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/parking_spot.dart';
import '../models/spot_availability_period.dart';

class ParkingSpotService {
  SupabaseClient get _supabase => Supabase.instance.client;

  // Get user's parking spots
  Future<List<ParkingSpot>> getUserSpots() async {
    final user = _supabase.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    // Resolve the user's apartment_id first, then fetch spots for that apartment.
    final profileRow = await _supabase
        .from('profiles')
        .select('apartment_id')
        .eq('id', user.id)
        .single();
    final apartmentId = profileRow['apartment_id'] as String?;
    if (apartmentId == null) return [];

    final response = await _supabase
        .from('parking_spots')
        .select()
        .eq('apartment_id', apartmentId)
        .order('created_at', ascending: false);

    return (response as List).map((json) => ParkingSpot.fromJson(json)).toList();
  }

  // Add a new parking spot
  // [apartmentId] is the owning apartment; [buildingId] is retained for the
  // DB column that still exists during the transition period.
  Future<ParkingSpot> addSpot({
    required String apartmentId,
    required String buildingId,
    required String spotIdentifier,
  }) async {
    final user = _supabase.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    final response = await _supabase
        .from('parking_spots')
        .insert({
          'apartment_id': apartmentId,
          'building_id': buildingId,
          'spot_identifier': spotIdentifier,
          'is_active': true,
        })
        .select()
        .single();

    return ParkingSpot.fromJson(response);
  }

  // Update spot (toggle active/inactive or update identifier)
  Future<ParkingSpot> updateSpot({
    required String spotId,
    bool? isActive,
    String? spotIdentifier,
  }) async {
    final updates = <String, dynamic>{};
    if (isActive != null) {
      updates['is_active'] = isActive;
    }
    if (spotIdentifier != null) {
      updates['spot_identifier'] = spotIdentifier;
    }

    if (updates.isEmpty) {
      throw Exception('No updates provided');
    }

    final response = await _supabase
        .from('parking_spots')
        .update(updates)
        .eq('id', spotId)
        .select()
        .single();

    return ParkingSpot.fromJson(response);
  }

  // Delete parking spot
  Future<void> deleteSpot(String spotId) async {
    await _supabase
        .from('parking_spots')
        .delete()
        .eq('id', spotId);
  }

  // Get availability periods for a spot.
  // Expired one-time periods (end_time in the past) are excluded so they
  // disappear automatically from the management view.  Recurring periods are
  // always returned because they have future occurrences.
  Future<List<SpotAvailabilityPeriod>> getAvailabilityPeriods(String spotId) async {
    final nowUtc = DateTime.now().toUtc().toIso8601String();

    // Fetch non-recurring periods that haven't ended yet.
    final oneTimeResponse = await _supabase
        .from('spot_availability_periods')
        .select()
        .eq('spot_id', spotId)
        .eq('is_recurring', false)
        .gte('end_time', nowUtc)
        .order('start_time', ascending: true);

    // Fetch all recurring periods (they may have future occurrences regardless
    // of the anchor start/end time stored in the row).
    final recurringResponse = await _supabase
        .from('spot_availability_periods')
        .select()
        .eq('spot_id', spotId)
        .eq('is_recurring', true)
        .order('start_time', ascending: true);

    final all = [
      ...(oneTimeResponse as List),
      ...(recurringResponse as List),
    ];

    // Sort combined list by start_time ascending.
    all.sort((a, b) {
      final aTime = DateTime.parse(a['start_time'] as String);
      final bTime = DateTime.parse(b['start_time'] as String);
      return aTime.compareTo(bTime);
    });

    return all.map((json) => SpotAvailabilityPeriod.fromJson(json)).toList();
  }

  // Add availability period for a spot
  Future<SpotAvailabilityPeriod> addAvailabilityPeriod({
    required String spotId,
    required DateTime startTime,
    required DateTime endTime,
    bool isRecurring = false,
    String? recurringPattern,
  }) async {
    final user = _supabase.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    // Verify the spot belongs to the user's apartment.
    final profileRow = await _supabase
        .from('profiles')
        .select('apartment_id')
        .eq('id', user.id)
        .single();
    final userApartmentId = profileRow['apartment_id'] as String?;

    final spot = await _supabase
        .from('parking_spots')
        .select('apartment_id')
        .eq('id', spotId)
        .single();

    if (spot['apartment_id'] != userApartmentId) {
      throw Exception('You can only set availability for your own apartment\'s spots');
    }

    // CRITICAL FIX: Treat the input DateTime as a "naive" local time
    // and convert it to UTC explicitly. The DateTime created from date picker
    // is in local timezone, but we want to store it as if it were UTC
    // (or convert it properly to UTC).
    // 
    // The issue: DateTime(year, month, day, hour, minute) creates a LOCAL time.
    // When we call toIso8601String(), it converts to UTC, which can shift the date.
    // 
    // Solution: Extract the local date/time components and create a UTC DateTime
    // that represents the same "wall clock" time in UTC.
    final localStart = startTime.toLocal();
    final localEnd = endTime.toLocal();
    
    // Create UTC DateTime with the same date/time components
    // This ensures the date doesn't shift when stored
    final utcStart = DateTime.utc(
      localStart.year,
      localStart.month,
      localStart.day,
      localStart.hour,
      localStart.minute,
    );
    final utcEnd = DateTime.utc(
      localEnd.year,
      localEnd.month,
      localEnd.day,
      localEnd.hour,
      localEnd.minute,
    );

    // Debug: Print what we're storing
    debugPrint('💾 Storing availability period:');
    debugPrint('   Input (local): ${startTime.toLocal()} to ${endTime.toLocal()}');
    debugPrint('   Converting to UTC (same wall clock): $utcStart to $utcEnd');
    debugPrint('   ISO string: ${utcStart.toIso8601String()} to ${utcEnd.toIso8601String()}');
    
    final response = await _supabase
        .from('spot_availability_periods')
        .insert({
          'spot_id': spotId,
          'start_time': utcStart.toIso8601String(),
          'end_time': utcEnd.toIso8601String(),
          'is_recurring': isRecurring,
          if (recurringPattern != null) 'recurring_pattern': recurringPattern,
        })
        .select()
        .single();
    
    // Debug: Print what was stored
    debugPrint('✅ Stored period:');
    debugPrint('   From DB: ${response['start_time']} to ${response['end_time']}');
    final storedStart = DateTime.parse(response['start_time'] as String);
    final storedEnd = DateTime.parse(response['end_time'] as String);
    debugPrint('   Parsed (local): ${storedStart.toLocal()} to ${storedEnd.toLocal()}');
    debugPrint('   Parsed (UTC): ${storedStart.toUtc()} to ${storedEnd.toUtc()}');

    return SpotAvailabilityPeriod.fromJson(response);
  }

  // Delete availability period
  Future<void> deleteAvailabilityPeriod(String periodId) async {
    final user = _supabase.auth.currentUser;
    if (user == null) throw Exception('Not authenticated');

    // Note: RLS policy ensures only spot owners can delete their availability periods
    await _supabase
        .from('spot_availability_periods')
        .delete()
        .eq('id', periodId);
  }

  // Check if a spot is available during a time period
  Future<bool> isSpotAvailable({
    required String spotId,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    // CRITICAL FIX: Normalize input times the same way we store availability periods
    // Treat the input as "naive" local time and convert to UTC with same date/time components
    final localStart = startTime.toLocal();
    final localEnd = endTime.toLocal();
    
    final requestedStartUtc = DateTime.utc(
      localStart.year,
      localStart.month,
      localStart.day,
      localStart.hour,
      localStart.minute,
    );
    final requestedEndUtc = DateTime.utc(
      localEnd.year,
      localEnd.month,
      localEnd.day,
      localEnd.hour,
      localEnd.minute,
    );
    
    // Get all availability periods for this spot
    final periods = await getAvailabilityPeriods(spotId);

    if (periods.isEmpty) {
      // If no availability periods set, spot is always available (backward compatibility)
      debugPrint('🔍 Spot $spotId has no availability periods - treating as always available');
      return true;
    }

    // Debug: Print periods and requested time
    debugPrint('🔍 Checking availability for spot $spotId');
    debugPrint('📅 Requested (local): ${startTime.toIso8601String()} to ${endTime.toIso8601String()}');
    debugPrint('📅 Requested (UTC): ${requestedStartUtc.toIso8601String()} to ${requestedEndUtc.toIso8601String()}');
    debugPrint('📋 Found ${periods.length} availability periods');

    // Expand recurring periods into concrete instances within the requested
    // window (one day of slack on each side handles requests that straddle
    // midnight from a recurring period that started just before/after).
    final expansionStart = requestedStartUtc.subtract(const Duration(days: 1));
    final expansionEnd = requestedEndUtc.add(const Duration(days: 1));
    final instances = expandRecurringPeriods(periods, expansionStart, expansionEnd);

    debugPrint(
      '📋 Expanded into ${instances.length} concrete instances within ${expansionStart.toIso8601String()} – ${expansionEnd.toIso8601String()}',
    );

    // Check if requested time overlaps with any concrete instance
    for (final instance in instances) {
      final periodStartUtc = instance['start']!.toUtc();
      final periodEndUtc = instance['end']!.toUtc();

      final overlaps = requestedStartUtc.isBefore(periodEndUtc) &&
          requestedEndUtc.isAfter(periodStartUtc);

      if (overlaps) {
        debugPrint('  ✅ Period overlaps! Checking for approved bookings...');
        
        // Found an availability period that overlaps
        // Now check if there are any approved OR pending bookings that would block this time
        // Pending bookings also block to prevent double-booking
        final user = _supabase.auth.currentUser;
        if (user != null) {
          // Check for overlapping approved and pending bookings.
          // Narrow server-side to bookings that could possibly overlap the
          // requested window: end_time > requestedStart AND start_time < requestedEnd.
          final allBookings = await _supabase
              .from('booking_requests')
              .select('start_time, end_time, status')
              .eq('spot_id', spotId)
              .inFilter('status', ['approved', 'pending'])
              .gt('end_time', requestedStartUtc.toIso8601String())
              .lt('start_time', requestedEndUtc.toIso8601String());

          bool hasBlockingBooking = false;
          if (allBookings.isNotEmpty) {
            for (final booking in allBookings) {
              final bookingStart = DateTime.parse(booking['start_time'] as String);
              final bookingEnd = DateTime.parse(booking['end_time'] as String);
              final bookingStatus = booking['status'] as String;
              
              // Normalize booking times (same way we store them)
              final localStart = bookingStart.toLocal();
              final localEnd = bookingEnd.toLocal();
              
              final bookingStartUtc = DateTime.utc(
                localStart.year,
                localStart.month,
                localStart.day,
                localStart.hour,
                localStart.minute,
              );
              final bookingEndUtc = DateTime.utc(
                localEnd.year,
                localEnd.month,
                localEnd.day,
                localEnd.hour,
                localEnd.minute,
              );
              
              // Check if booking overlaps with requested time
              if (requestedStartUtc.isBefore(bookingEndUtc) && requestedEndUtc.isAfter(bookingStartUtc)) {
                debugPrint('  ❌ Blocked by $bookingStatus booking: ${bookingStart.toIso8601String()} to ${bookingEnd.toIso8601String()}');
                hasBlockingBooking = true;
                break;
              }
            }
          }

          if (hasBlockingBooking) {
            return false;
          }
        }
        
        // Availability period exists and no approved bookings block it
        debugPrint('  ✅ Spot is available!');
        return true;
      }
    }

    // No availability period overlaps with requested time
    debugPrint('  ❌ No availability period overlaps with requested time');
    return false;
  }

  // Get available time slots for a spot (availability periods minus approved bookings)
  // Returns a list of time ranges that are actually available for booking
  Future<List<Map<String, DateTime>>> getAvailableTimeSlots({
    required String spotId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    // Default to next 30 days if no date range specified
    final now = DateTime.now();
    final searchStart = startDate ?? now;
    final searchEnd = endDate ?? now.add(const Duration(days: 30));

    // Normalize search dates to UTC
    final searchStartUtc = DateTime.utc(
      searchStart.year,
      searchStart.month,
      searchStart.day,
      0,
      0,
    );
    final searchEndUtc = DateTime.utc(
      searchEnd.year,
      searchEnd.month,
      searchEnd.day,
      23,
      59,
    );

    // Get all availability periods for this spot
    final periods = await getAvailabilityPeriods(spotId);
    
    // Get approved AND pending bookings that could overlap the search window.
    // Pending bookings should also be considered to prevent double-booking.
    final allBookings = await _supabase
        .from('booking_requests')
        .select('start_time, end_time, status')
        .eq('spot_id', spotId)
        .inFilter('status', ['approved', 'pending'])
        .gt('end_time', searchStartUtc.toIso8601String())
        .lt('start_time', searchEndUtc.toIso8601String());
    
    // Filter to only bookings that overlap with search range
    final relevantBookings = (allBookings as List).where((booking) {
      final bookingStart = DateTime.parse(booking['start_time'] as String);
      final bookingEnd = DateTime.parse(booking['end_time'] as String);
      
      // Normalize booking times
      final localStart = bookingStart.toLocal();
      final localEnd = bookingEnd.toLocal();
      
      final bookingStartUtc = DateTime.utc(
        localStart.year,
        localStart.month,
        localStart.day,
        localStart.hour,
        localStart.minute,
      );
      final bookingEndUtc = DateTime.utc(
        localEnd.year,
        localEnd.month,
        localEnd.day,
        localEnd.hour,
        localEnd.minute,
      );
      
      // Check if booking overlaps with search range
      return bookingStartUtc.isBefore(searchEndUtc) && bookingEndUtc.isAfter(searchStartUtc);
    }).toList();

    // Normalize bookings to UTC (same way we store them)
    final bookings = <Map<String, DateTime>>[];
    for (final booking in relevantBookings) {
      final bookingStart = DateTime.parse(booking['start_time'] as String);
      final bookingEnd = DateTime.parse(booking['end_time'] as String);
      
      final localStart = bookingStart.toLocal();
      final localEnd = bookingEnd.toLocal();
      
      bookings.add({
        'start': DateTime.utc(
          localStart.year,
          localStart.month,
          localStart.day,
          localStart.hour,
          localStart.minute,
        ),
        'end': DateTime.utc(
          localEnd.year,
          localEnd.month,
          localEnd.day,
          localEnd.hour,
          localEnd.minute,
        ),
      });
    }

    // Calculate available slots by subtracting bookings from periods.
    // First expand recurring periods into concrete instances within the
    // search window, so `weekly` / `weekdays` / etc. are respected.
    final availableSlots = <Map<String, DateTime>>[];
    final instances = expandRecurringPeriods(periods, searchStartUtc, searchEndUtc);

    for (final instance in instances) {
      final periodStartUtc = instance['start']!.toUtc();
      final periodEndUtc = instance['end']!.toUtc();

      // Skip periods outside search range
      if (periodEndUtc.isBefore(searchStartUtc) || periodStartUtc.isAfter(searchEndUtc)) {
        continue;
      }
      
      // Find bookings that overlap with this period
      final overlappingBookings = bookings.where((booking) {
        final bookingStart = booking['start']!;
        final bookingEnd = booking['end']!;
        return bookingStart.isBefore(periodEndUtc) && bookingEnd.isAfter(periodStartUtc);
      }).toList();
      
      if (overlappingBookings.isEmpty) {
        // No bookings, entire period is available
        availableSlots.add({
          'start': periodStartUtc,
          'end': periodEndUtc,
        });
      } else {
        // Sort bookings by start time
        overlappingBookings.sort((a, b) => a['start']!.compareTo(b['start']!));
        
        // Calculate available slots between bookings
        DateTime currentStart = periodStartUtc;
        
        for (final booking in overlappingBookings) {
          final bookingStart = booking['start']!;
          final bookingEnd = booking['end']!;
          
          // If there's a gap before this booking, add it as available
          if (currentStart.isBefore(bookingStart)) {
            availableSlots.add({
              'start': currentStart,
              'end': bookingStart,
            });
          }
          
          // Move current start to after this booking
          currentStart = currentStart.isAfter(bookingEnd) ? currentStart : bookingEnd;
        }
        
        // Add remaining time after last booking
        if (currentStart.isBefore(periodEndUtc)) {
          availableSlots.add({
            'start': currentStart,
            'end': periodEndUtc,
          });
        }
      }
    }
    
    // Sort by start time
    availableSlots.sort((a, b) => a['start']!.compareTo(b['start']!));

    return availableSlots;
  }

  /// Expand a list of availability periods into concrete `{start, end}` instances
  /// falling within `[rangeStart, rangeEnd)`.
  ///
  /// Non-recurring periods are returned as-is if they overlap the range.
  /// Recurring periods are expanded according to `recurringPattern`:
  /// - keyword strings: `daily`, `weekly`, `weekdays`, `weekends`
  /// - JSON object: `{"type":"weekly","days":["MON","WED","FRI"],"until":"2026-12-31T00:00:00Z"}`
  ///   - `days` is optional; if absent, defaults to the original weekday
  ///   - `until` is optional; if absent, recurs indefinitely
  ///
  /// An instance is included if it overlaps `[rangeStart, rangeEnd)`.
  List<Map<String, DateTime>> expandRecurringPeriods(
    List<SpotAvailabilityPeriod> periods,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    const dayNameToWeekday = <String, int>{
      'MON': DateTime.monday,
      'TUE': DateTime.tuesday,
      'WED': DateTime.wednesday,
      'THU': DateTime.thursday,
      'FRI': DateTime.friday,
      'SAT': DateTime.saturday,
      'SUN': DateTime.sunday,
    };

    final result = <Map<String, DateTime>>[];

    bool overlapsRange(DateTime start, DateTime end) {
      return start.isBefore(rangeEnd) && end.isAfter(rangeStart);
    }

    for (final period in periods) {
      if (!period.isRecurring) {
        if (overlapsRange(period.startTime, period.endTime)) {
          result.add({'start': period.startTime, 'end': period.endTime});
        }
        continue;
      }

      final patternRaw = period.recurringPattern ?? 'weekly';
      final duration = period.endTime.difference(period.startTime);

      // Try to parse as JSON; fall back to legacy keyword string.
      String type = patternRaw;
      Set<int>? days;
      DateTime? until;

      final trimmed = patternRaw.trim();
      if (trimmed.startsWith('{')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            type = (decoded['type'] as String?) ?? 'weekly';
            final daysRaw = decoded['days'];
            if (daysRaw is List && daysRaw.isNotEmpty) {
              days = daysRaw
                  .map((d) => dayNameToWeekday[d.toString().toUpperCase()])
                  .whereType<int>()
                  .toSet();
            }
            final untilRaw = decoded['until'];
            if (untilRaw is String && untilRaw.isNotEmpty) {
              until = DateTime.tryParse(untilRaw);
            }
          }
        } catch (_) {
          // Malformed JSON — fall through with raw string as type.
        }
      }

      // Iterate day by day from the period's start date up to rangeEnd,
      // anchored to the period's original start time-of-day.
      var cursor = DateTime.utc(
        period.startTime.year,
        period.startTime.month,
        period.startTime.day,
        period.startTime.hour,
        period.startTime.minute,
        period.startTime.second,
      );

      final hardStop = until != null && until.isBefore(rangeEnd) ? until : rangeEnd;

      while (!cursor.isAfter(hardStop)) {
        final weekday = cursor.weekday;
        bool include = false;
        switch (type) {
          case 'daily':
            include = true;
            break;
          case 'weekly':
            include = days != null
                ? days.contains(weekday)
                : weekday == period.startTime.weekday;
            break;
          case 'weekdays':
            include = weekday >= DateTime.monday && weekday <= DateTime.friday;
            break;
          case 'weekends':
            include = weekday == DateTime.saturday || weekday == DateTime.sunday;
            break;
          default:
            include = weekday == period.startTime.weekday;
        }

        if (include) {
          final instanceStart = cursor;
          final instanceEnd = cursor.add(duration);
          if (overlapsRange(instanceStart, instanceEnd)) {
            result.add({'start': instanceStart, 'end': instanceEnd});
          }
        }

        cursor = cursor.add(const Duration(days: 1));
      }
    }

    return result;
  }

  /// Next occurrence start times for a spot, keyed by period id.
  ///
  /// Prefers `expand_availability_occurrences` (SQL, 90-day clamp). Falls
  /// back to [expandRecurringPeriods] if the RPC fails.
  Future<Map<String, List<DateTime>>> nextOccurrencesForSpot({
    required String spotId,
    required List<SpotAvailabilityPeriod> periods,
    DateTime? now,
    int limit = 4,
  }) async {
    final from = (now ?? DateTime.now()).toUtc();
    final to = from.add(const Duration(days: 90));
    try {
      final response = await _supabase.rpc(
        'expand_availability_occurrences',
        params: {
          'p_spot_id': spotId,
          'p_from': from.toIso8601String(),
          'p_to': to.toIso8601String(),
        },
      );
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      return groupNextOccurrenceStarts(rows, from: from, limit: limit);
    } catch (_) {
      return nextOccurrenceStartsFromDart(
        periods,
        from: from,
        to: to,
        limit: limit,
      );
    }
  }

  /// Dart-expander fallback used when the SQL RPC is unavailable.
  @visibleForTesting
  Map<String, List<DateTime>> nextOccurrenceStartsFromDart(
    List<SpotAvailabilityPeriod> periods, {
    required DateTime from,
    required DateTime to,
    int limit = 4,
  }) {
    final result = <String, List<DateTime>>{};
    for (final period in periods) {
      if (!period.isRecurring) continue;
      final instances = expandRecurringPeriods([period], from, to)
        ..sort((a, b) => a['start']!.compareTo(b['start']!));
      result[period.id] = instances
          .map((i) => i['start']!)
          .take(limit)
          .toList();
    }
    return result;
  }
}

/// Groups RPC rows from `expand_availability_occurrences` into the next
/// [limit] start times per `period_id`, starting at [from].
@visibleForTesting
Map<String, List<DateTime>> groupNextOccurrenceStarts(
  List<Map<String, dynamic>> rows, {
  required DateTime from,
  int limit = 4,
}) {
  final grouped = <String, List<DateTime>>{};
  for (final row in rows) {
    final id = row['period_id'] as String?;
    final startRaw = row['start_time'];
    if (id == null || startRaw == null) continue;
    final start = startRaw is DateTime
        ? startRaw
        : DateTime.parse(startRaw as String);
    grouped.putIfAbsent(id, () => []).add(start);
  }
  final result = <String, List<DateTime>>{};
  for (final entry in grouped.entries) {
    final starts = entry.value.where((s) => !s.isBefore(from)).toList()
      ..sort();
    result[entry.key] = starts.take(limit).toList();
  }
  return result;
}

