// integration_test/helpers/fake_parking_spot.dart
//
// In-memory factory helpers that produce deterministic ParkingSpot /
// SpotAvailabilityPeriod objects for use in widget-level integration tests
// that do NOT hit the real Supabase backend.
//
// Usage:
//   final spot   = FakeData.spot();
//   final period = FakeData.activePeriod(spotId: spot.id);

import 'package:parking_trade/models/parking_spot.dart';
import 'package:parking_trade/models/spot_availability_period.dart';

abstract class FakeData {
  FakeData._();

  // ── Parking spots ──────────────────────────────────────────────────────────

  /// A minimal, fully-populated [ParkingSpot] suitable for rendering
  /// [_HeroToggleCard] in an unshared (occupied) state.
  static ParkingSpot spot({
    String id = 'fake-spot-001',
    String spotIdentifier = '42',
    String apartmentId = 'fake-apt-001',
    bool isActive = true,
  }) {
    return ParkingSpot(
      id: id,
      spotIdentifier: spotIdentifier,
      apartmentId: apartmentId,
      buildingId: 'fake-building-001',
      isActive: isActive,
      createdAt: DateTime(2024, 1, 1),
    );
  }

  // ── Availability periods ───────────────────────────────────────────────────

  /// A *currently active* (non-recurring) availability period for [spotId].
  /// By default it runs from 1 hour ago to 8 hours from now.
  static SpotAvailabilityPeriod activePeriod({
    String spotId = 'fake-spot-001',
    String id = 'fake-period-001',
  }) {
    final now = DateTime.now();
    return SpotAvailabilityPeriod(
      id: id,
      spotId: spotId,
      startTime: now.subtract(const Duration(hours: 1)),
      endTime: now.add(const Duration(hours: 8)),
      isRecurring: false,
      createdAt: now.subtract(const Duration(hours: 2)),
    );
  }

  /// A future (upcoming) availability period starting in 2 hours.
  static SpotAvailabilityPeriod futurePeriod({
    String spotId = 'fake-spot-001',
    String id = 'fake-period-002',
  }) {
    final now = DateTime.now();
    return SpotAvailabilityPeriod(
      id: id,
      spotId: spotId,
      startTime: now.add(const Duration(hours: 2)),
      endTime: now.add(const Duration(hours: 10)),
      isRecurring: false,
      createdAt: now,
    );
  }
}
