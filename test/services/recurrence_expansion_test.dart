import 'package:flutter_test/flutter_test.dart';
import 'package:parking_trade/models/spot_availability_period.dart';
import 'package:parking_trade/services/parking_spot_service.dart';

void main() {
  late ParkingSpotService service;

  setUp(() {
    service = ParkingSpotService();
  });

  SpotAvailabilityPeriod makePeriod({
    String id = 'test',
    required DateTime start,
    required DateTime end,
    bool recurring = false,
    String? pattern,
  }) {
    return SpotAvailabilityPeriod(
      id: id,
      spotId: 'spot-1',
      startTime: start,
      endTime: end,
      isRecurring: recurring,
      recurringPattern: pattern,
      createdAt: DateTime.utc(2025, 1, 1),
    );
  }

  group('expandRecurringPeriods', () {
    test('non-recurring period returned as-is', () {
      final period = makePeriod(
        start: DateTime.utc(2025, 6, 1, 10),
        end: DateTime.utc(2025, 6, 1, 12),
      );

      final result = service.expandRecurringPeriods(
        [period],
        DateTime.utc(2025, 6, 1),
        DateTime.utc(2025, 6, 2),
      );

      expect(result.length, 1);
      expect(result[0]['start'], period.startTime);
      expect(result[0]['end'], period.endTime);
    });

    test('weekly recurrence generates correct instances', () {
      final period = makePeriod(
        start: DateTime.utc(2025, 6, 1, 10), // Sunday
        end: DateTime.utc(2025, 6, 1, 12),
        recurring: true,
        pattern: 'weekly',
      );

      final result = service.expandRecurringPeriods(
        [period],
        DateTime.utc(2025, 6, 1),
        DateTime.utc(2025, 6, 22), // 3 weeks
      );

      expect(result.length, 3);
      expect(result[1]['start'], DateTime.utc(2025, 6, 8, 10));
      expect(result[2]['start'], DateTime.utc(2025, 6, 15, 10));
    });

    test('daily recurrence generates correct instances', () {
      final period = makePeriod(
        start: DateTime.utc(2025, 6, 1, 9),
        end: DateTime.utc(2025, 6, 1, 10),
        recurring: true,
        pattern: 'daily',
      );

      final result = service.expandRecurringPeriods(
        [period],
        DateTime.utc(2025, 6, 1),
        DateTime.utc(2025, 6, 4),
      );

      expect(result.length, 3);
    });

    test('weekdays pattern skips weekends', () {
      // 2025-06-02 is Monday
      final period = makePeriod(
        start: DateTime.utc(2025, 6, 2, 9),
        end: DateTime.utc(2025, 6, 2, 17),
        recurring: true,
        pattern: 'weekdays',
      );

      final result = service.expandRecurringPeriods(
        [period],
        DateTime.utc(2025, 6, 2),
        DateTime.utc(2025, 6, 9), // one full week
      );

      // Mon-Fri = 5 instances
      expect(result.length, 5);
      for (final r in result) {
        final day = r['start']!.weekday;
        expect(day, isNot(DateTime.saturday));
        expect(day, isNot(DateTime.sunday));
      }
    });

    test('weekends pattern only includes Sat/Sun', () {
      // 2025-06-07 is Saturday
      final period = makePeriod(
        start: DateTime.utc(2025, 6, 7, 9),
        end: DateTime.utc(2025, 6, 7, 17),
        recurring: true,
        pattern: 'weekends',
      );

      final result = service.expandRecurringPeriods(
        [period],
        DateTime.utc(2025, 6, 7),
        DateTime.utc(2025, 6, 22),
      );

      for (final r in result) {
        final day = r['start']!.weekday;
        expect(
          day == DateTime.saturday || day == DateTime.sunday,
          true,
        );
      }
    });

    test('periods outside search range are excluded', () {
      final period = makePeriod(
        start: DateTime.utc(2025, 6, 1, 10),
        end: DateTime.utc(2025, 6, 1, 12),
        recurring: true,
        pattern: 'weekly',
      );

      final result = service.expandRecurringPeriods(
        [period],
        DateTime.utc(2025, 7, 1),
        DateTime.utc(2025, 7, 8),
      );

      for (final r in result) {
        expect(r['end']!.isAfter(DateTime.utc(2025, 7, 1)), true);
      }
    });
  });

  group('SpotAvailabilityPeriod.isExpired', () {
    test('one-shot is expired at end_time', () {
      final period = makePeriod(
        start: DateTime.utc(2025, 6, 1, 10),
        end: DateTime.utc(2025, 6, 1, 12),
      );
      expect(period.isExpired(DateTime.utc(2025, 6, 1, 11, 59)), isFalse);
      expect(period.isExpired(DateTime.utc(2025, 6, 1, 12)), isTrue);
    });

    test('recurring without until never expires', () {
      final period = makePeriod(
        start: DateTime.utc(2025, 1, 1, 10),
        end: DateTime.utc(2025, 1, 1, 12),
        recurring: true,
        pattern: '{"type":"weekly","days":["MON"]}',
      );
      expect(period.isExpired(DateTime.utc(2026, 9, 1)), isFalse);
    });

    test('recurring with until hides after that instant', () {
      final period = makePeriod(
        start: DateTime.utc(2025, 1, 1, 10),
        end: DateTime.utc(2025, 1, 1, 12),
        recurring: true,
        pattern:
            '{"type":"weekly","days":["MON"],"until":"2025-06-01T23:59:00.000Z"}',
      );
      expect(period.isExpired(DateTime.utc(2025, 6, 1, 23, 58)), isFalse);
      expect(period.isExpired(DateTime.utc(2025, 6, 1, 23, 59)), isTrue);
    });
  });

  group('nextOccurrenceStartsFromDart', () {
    test('returns at most four upcoming starts', () {
      final period = makePeriod(
        id: 'weekly-1',
        start: DateTime.utc(2025, 6, 2, 10), // Monday
        end: DateTime.utc(2025, 6, 2, 12),
        recurring: true,
        pattern: '{"type":"weekly","days":["MON"]}',
      );

      final result = service.nextOccurrenceStartsFromDart(
        [period],
        from: DateTime.utc(2025, 6, 2),
        to: DateTime.utc(2025, 8, 1),
        limit: 4,
      );

      expect(result['weekly-1'], hasLength(4));
      expect(result['weekly-1']!.first, DateTime.utc(2025, 6, 2, 10));
      expect(result['weekly-1']![1], DateTime.utc(2025, 6, 9, 10));
    });
  });

  group('groupNextOccurrenceStarts', () {
    test('keeps the next four starts on or after from', () {
      final grouped = groupNextOccurrenceStarts(
        [
          {
            'period_id': 'p1',
            'start_time': '2025-06-01T10:00:00Z',
          },
          {
            'period_id': 'p1',
            'start_time': '2025-06-08T10:00:00Z',
          },
          {
            'period_id': 'p1',
            'start_time': '2025-06-15T10:00:00Z',
          },
          {
            'period_id': 'p1',
            'start_time': '2025-06-22T10:00:00Z',
          },
          {
            'period_id': 'p1',
            'start_time': '2025-06-29T10:00:00Z',
          },
        ],
        from: DateTime.utc(2025, 6, 8),
        limit: 4,
      );

      expect(grouped['p1'], [
        DateTime.utc(2025, 6, 8, 10),
        DateTime.utc(2025, 6, 15, 10),
        DateTime.utc(2025, 6, 22, 10),
        DateTime.utc(2025, 6, 29, 10),
      ]);
    });
  });
}
