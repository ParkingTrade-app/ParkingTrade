import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../services/parking_spot_service.dart';
import '../../models/parking_spot.dart';
import '../../models/spot_availability_period.dart';
import '../../widgets/add_availability_duration_sheet.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/status_chip.dart';

class ManageAvailabilityScreen extends StatefulWidget {
  final ParkingSpot spot;

  const ManageAvailabilityScreen({
    super.key,
    required this.spot,
  });

  @override
  State<ManageAvailabilityScreen> createState() => _ManageAvailabilityScreenState();
}

class _ManageAvailabilityScreenState extends State<ManageAvailabilityScreen> {
  final _spotService = ParkingSpotService();
  List<SpotAvailabilityPeriod> _periods = [];
  Map<String, List<DateTime>> _nextByPeriod = const {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPeriods();
  }

  Future<void> _loadPeriods() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final now = DateTime.now();
      final periods = (await _spotService.getAvailabilityPeriods(widget.spot.id))
          // Hide expired one-shots and recurring templates whose `until` has
          // passed. Forever templates (no until) stay visible.
          .where((p) => !p.isExpired(now))
          .toList();
      Map<String, List<DateTime>> nextByPeriod = const {};
      try {
        nextByPeriod = await _spotService.nextOccurrencesForSpot(
          spotId: widget.spot.id,
          periods: periods,
          now: now,
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _periods = periods;
        _nextByPeriod = nextByPeriod;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      AppSnack.error(context, 'spots.availability.could_not_load'.tr(namedArgs: {'error': e.toString()}));
    }
  }

  Future<void> _addAvailabilityPeriod() async {
    // Use the new intuitive duration sheet (quick chips + custom time picker).
    final duration = await showAddAvailabilityDurationSheet(context);
    if (duration == null || !mounted) return;

    final startDateTime = duration.startTime;
    final endDateTime = duration.endTime;

    if (!endDateTime.isAfter(startDateTime)) {
      if (!mounted) return;
      AppSnack.error(context, 'spots.availability.end_before_start'.tr());
      return;
    }

    try {
      debugPrint('📅 Creating availability period (duration sheet):');
      debugPrint('   Local: ${startDateTime.toLocal()} → ${endDateTime.toLocal()}');

      await _spotService.addAvailabilityPeriod(
        spotId: widget.spot.id,
        startTime: startDateTime,
        endTime: endDateTime,
      );
      _loadPeriods();
      if (mounted) {
        AppSnack.success(context, 'spots.availability.availability_added'.tr());
      }
    } catch (e) {
      if (mounted) {
        AppSnack.error(context, 'spots.availability.could_not_add'.tr(namedArgs: {'error': e.toString()}));
      }
    }
  }

  Future<void> _showAddSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.event_rounded),
                  title: Text('spots.availability.one_time'.tr()),
                  subtitle: Text('spots.availability.one_time_subtitle'.tr()),
                  onTap: () => Navigator.of(context).pop('once'),
                ),
                ListTile(
                  leading: const Icon(Icons.event_repeat_rounded),
                  title: Text('spots.availability.weekly'.tr()),
                  subtitle: Text('spots.availability.weekly_subtitle'.tr()),
                  onTap: () => Navigator.of(context).pop('weekly'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || choice == null) return;
    if (choice == 'once') {
      await _addAvailabilityPeriod();
    } else if (choice == 'weekly') {
      await _addRecurringPeriod();
    }
  }

  Future<void> _addRecurringPeriod() async {
    final now = DateTime.now();
    final startDate = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (startDate == null || !mounted) return;

    final startTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (startTime == null || !mounted) return;

    final endTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: (startTime.hour + 1) % 24,
        minute: startTime.minute,
      ),
    );
    if (endTime == null || !mounted) return;

    final days = await _pickWeekdays(startDate.weekday);
    if (!mounted || days == null || days.isEmpty) return;

    final untilResult = await _pickRepeatUntil(startDate);
    if (!mounted || untilResult.isCancelled) return;

    final anchor = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
      startTime.hour,
      startTime.minute,
    );
    var endAnchor = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
      endTime.hour,
      endTime.minute,
    );
    if (!endAnchor.isAfter(anchor)) {
      endAnchor = endAnchor.add(const Duration(days: 1));
    }

    final untilDate = untilResult.date;
    final pattern = jsonEncode({
      'type': 'weekly',
      'days': days.toList()..sort(),
      if (untilDate != null)
        'until': DateTime.utc(
          untilDate.year,
          untilDate.month,
          untilDate.day,
          23,
          59,
        ).toIso8601String(),
    });

    try {
      await _spotService.addAvailabilityPeriod(
        spotId: widget.spot.id,
        startTime: anchor,
        endTime: endAnchor,
        isRecurring: true,
        recurringPattern: pattern,
      );
      _loadPeriods();
      if (mounted) {
        AppSnack.success(context, 'spots.availability.recurring_added'.tr());
      }
    } catch (e) {
      if (mounted) {
        AppSnack.error(context, 'spots.availability.could_not_add'.tr(namedArgs: {'error': e.toString()}));
      }
    }
  }

  Future<Set<String>?> _pickWeekdays(int defaultWeekday) async {
    // Day codes → localization keys
    final dayKeys = <String, String>{
      'MON': 'spots.availability.mon',
      'TUE': 'spots.availability.tue',
      'WED': 'spots.availability.wed',
      'THU': 'spots.availability.thu',
      'FRI': 'spots.availability.fri',
      'SAT': 'spots.availability.sat',
      'SUN': 'spots.availability.sun',
    };
    const weekdayToCode = <int, String>{
      DateTime.monday: 'MON',
      DateTime.tuesday: 'TUE',
      DateTime.wednesday: 'WED',
      DateTime.thursday: 'THU',
      DateTime.friday: 'FRI',
      DateTime.saturday: 'SAT',
      DateTime.sunday: 'SUN',
    };

    final selected = <String>{weekdayToCode[defaultWeekday] ?? 'MON'};

    return showDialog<Set<String>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) => AlertDialog(
            title: Text('spots.availability.repeat_on'.tr()),
            content: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: dayKeys.entries.map((entry) {
                final isSelected = selected.contains(entry.key);
                return FilterChip(
                  label: Text(entry.value.tr()),
                  selected: isSelected,
                  onSelected: (v) {
                    setStateDialog(() {
                      if (v) {
                        selected.add(entry.key);
                      } else {
                        selected.remove(entry.key);
                      }
                    });
                  },
                );
              }).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: Text('spots.availability.cancel'.tr()),
              ),
              TextButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(selected),
                child: Text('spots.availability.ok'.tr()),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<_UntilResult> _pickRepeatUntil(DateTime anchor) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'spots.availability.repeat_until'.tr(),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.all_inclusive_rounded),
                  title: Text('spots.availability.forever'.tr()),
                  subtitle: Text('spots.availability.forever_subtitle'.tr()),
                  onTap: () => Navigator.of(context).pop('forever'),
                ),
                ListTile(
                  leading: const Icon(Icons.event_busy_rounded),
                  title: Text('spots.availability.pick_end_date'.tr()),
                  subtitle: Text('spots.availability.pick_end_date_subtitle'.tr()),
                  onTap: () => Navigator.of(context).pop('date'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (choice == null) return const _UntilResult.cancelled();
    if (choice == 'forever') return const _UntilResult.forever();

    if (!mounted) return const _UntilResult.cancelled();
    final picked = await showDatePicker(
      context: context,
      initialDate: anchor.add(const Duration(days: 30)),
      firstDate: anchor,
      lastDate: anchor.add(const Duration(days: 365 * 2)),
      helpText: 'spots.availability.repeat_until'.tr(),
    );
    if (picked == null) return const _UntilResult.cancelled();
    return _UntilResult.date(picked);
  }

  String _describeRecurrence(SpotAvailabilityPeriod period) {
    if (!period.isRecurring) return '';
    final raw = period.recurringPattern ?? '';
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final type = decoded['type']?.toString() ?? 'weekly';

          String untilSuffix = '';
          final untilRaw = decoded['until'];
          if (untilRaw is String && untilRaw.isNotEmpty) {
            final untilDate = DateTime.tryParse(untilRaw)?.toLocal();
            if (untilDate != null) {
              untilSuffix = 'spots.availability.until_suffix'.tr(
                namedArgs: {'date': DateFormat('MMM d').format(untilDate)},
              );
            }
          }

          if (type == 'weekly') {
            final daysRaw = decoded['days'];
            if (daysRaw is List && daysRaw.isNotEmpty) {
              // Map day codes to localized labels
              final dayKeyMap = <String, String>{
                'MON': 'spots.availability.mon',
                'TUE': 'spots.availability.tue',
                'WED': 'spots.availability.wed',
                'THU': 'spots.availability.thu',
                'FRI': 'spots.availability.fri',
                'SAT': 'spots.availability.sat',
                'SUN': 'spots.availability.sun',
              };
              final days = daysRaw
                  .map((d) {
                    final key = dayKeyMap[d.toString().toUpperCase()];
                    return key != null ? key.tr() : d.toString();
                  })
                  .join(', ');
              return 'spots.availability.weekly_label'.tr(
                namedArgs: {'days': days + untilSuffix},
              );
            }
            return 'spots.availability.weekly_label_plain'.tr() + untilSuffix;
          }
          return 'spots.availability.repeats_label'.tr(namedArgs: {'type': type}) + untilSuffix;
        }
      } catch (_) {
        // Fall through to raw pattern.
      }
    }
    return 'spots.availability.repeats_label'.tr(namedArgs: {'type': raw});
  }

  String _nextOccurrencesLabel(String periodId) {
    final times = _nextByPeriod[periodId];
    if (times == null || times.isEmpty) return '';
    final fmt = DateFormat('EEE MMM d · HH:mm');
    final joined = times.map((t) => fmt.format(t.toLocal())).join(' · ');
    return 'spots.availability.next_occurrences'.tr(namedArgs: {'times': joined});
  }

  Future<void> _deletePeriod(SpotAvailabilityPeriod period) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('spots.availability.remove_dialog_title'.tr()),
        content: Text('spots.availability.remove_dialog_message'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('spots.availability.keep_it'.tr()),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text('spots.availability.remove'.tr()),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _spotService.deleteAvailabilityPeriod(period.id);
      _loadPeriods();
      if (mounted) {
        AppSnack.success(context, 'spots.availability.window_removed'.tr());
      }
    } catch (e) {
      if (mounted) {
        AppSnack.error(context, 'spots.availability.could_not_remove'.tr(namedArgs: {'error': e.toString()}));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('spots.availability.title'.tr(namedArgs: {'id': widget.spot.spotIdentifier})),
      ),
      body: _isLoading
          ? const SkeletonList(count: 4)
          : RefreshIndicator(
              onRefresh: _loadPeriods,
              child: ListView(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 96),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'spots.availability.when_free_heading'.tr(),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _periods.isEmpty
                              ? 'spots.availability.no_windows_hint'.tr()
                              : 'spots.availability.has_windows_hint'.tr(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_periods.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: EmptyState(
                        icon: Icons.event_available_rounded,
                        title: 'spots.availability.no_windows_title'.tr(),
                        message: 'spots.availability.no_windows_message'.tr(),
                      ),
                    )
                  else
                    ..._periods.map((period) {
                      final now = DateTime.now();
                      final isActive = !period.isRecurring &&
                          period.startTime.isBefore(now) &&
                          period.endTime.isAfter(now);

                      final title = period.isRecurring
                          ? '${DateFormat('HH:mm').format(period.startTime)} – ${DateFormat('HH:mm').format(period.endTime)}'
                          : isActive
                              ? 'spots.availability.available_until'.tr(
                                  namedArgs: {
                                    'time': DateFormat('HH:mm').format(period.endTime)
                                  },
                                )
                              : '${DateFormat('MMM d, y · HH:mm').format(period.startTime)}  →  ${DateFormat('MMM d, y · HH:mm').format(period.endTime)}';
                      final recurrence = _describeRecurrence(period);
                      final nextLabel = period.isRecurring
                          ? _nextOccurrencesLabel(period.id)
                          : '';
                      final durationLabel =
                          _formatDuration(period.startTime, period.endTime);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 6, 12),
                            child: Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: scheme.primaryContainer
                                        .withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    period.isRecurring
                                        ? Icons.event_repeat_rounded
                                        : Icons.schedule_rounded,
                                    color: scheme.primary,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(title,
                                          style: theme.textTheme.titleMedium),
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          if (isActive)
                                            StatusChip(
                                              label: 'spots.availability.available_until'.tr(
                                                namedArgs: {
                                                  'time': DateFormat('HH:mm').format(period.endTime),
                                                },
                                              ),
                                              tone: StatusTone.success,
                                              icon: Icons.check_circle_outline_rounded,
                                            )
                                          else if (recurrence.isNotEmpty)
                                            StatusChip(
                                              label: recurrence,
                                              tone: StatusTone.info,
                                              icon: Icons.event_repeat_rounded,
                                            )
                                          else
                                            StatusChip(
                                              label: 'spots.availability.one_time_chip'.tr(),
                                              tone: StatusTone.neutral,
                                              icon: Icons.event_rounded,
                                            ),
                                          StatusChip(
                                            label: durationLabel,
                                            tone: StatusTone.neutral,
                                            icon: Icons.timelapse_rounded,
                                          ),
                                        ],
                                      ),
                                      if (nextLabel.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          nextLabel,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'spots.availability.remove_tooltip'.tr(),
                                  icon: Icon(Icons.delete_outline_rounded,
                                      color: scheme.error),
                                  onPressed: () => _deletePeriod(period),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSheet,
        icon: const Icon(Icons.add_rounded),
        label: Text('spots.availability.add_window'.tr()),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  String _formatDuration(DateTime start, DateTime end) {
    final duration = end.difference(start);
    if (duration.inDays > 0) {
      return '${duration.inDays}d';
    } else if (duration.inHours > 0) {
      return '${duration.inHours}h';
    } else {
      return '${duration.inMinutes}m';
    }
  }
}

/// Tri-state return from the "repeat until" picker.
class _UntilResult {
  final bool isCancelled;
  final bool isForever;
  final DateTime? date;

  const _UntilResult._(
      {required this.isCancelled,
      required this.isForever,
      required this.date});

  const _UntilResult.cancelled()
      : this._(isCancelled: true, isForever: false, date: null);
  const _UntilResult.forever()
      : this._(isCancelled: false, isForever: true, date: null);
  const _UntilResult.date(DateTime d)
      : this._(isCancelled: false, isForever: false, date: d);
}
