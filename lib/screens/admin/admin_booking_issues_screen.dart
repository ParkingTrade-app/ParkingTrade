import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../models/booking_issue.dart';
import '../../services/booking_issue_service.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/status_chip.dart';
import '../bookings/booking_detail_screen.dart';
import '../bookings/report_booking_issue_sheet.dart';
import 'resolve_booking_issue_dialog.dart';

enum _IssueFilter { open, upheld, dismissed, all }

/// Building-admin inbox for booking-trust reports.
///
/// Filter chips default to open issues. Resolve is primary here; tapping a
/// row opens [BookingDetailScreen] (usable after migration 049).
class AdminBookingIssuesScreen extends StatefulWidget {
  const AdminBookingIssuesScreen({super.key});

  @override
  State<AdminBookingIssuesScreen> createState() =>
      _AdminBookingIssuesScreenState();
}

class _AdminBookingIssuesScreenState extends State<AdminBookingIssuesScreen> {
  final _service = BookingIssueService();
  List<BookingIssue> _issues = const [];
  _IssueFilter _filter = _IssueFilter.open;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  BookingIssueStatus? get _statusForFilter {
    switch (_filter) {
      case _IssueFilter.open:
        return BookingIssueStatus.open;
      case _IssueFilter.upheld:
        return BookingIssueStatus.upheld;
      case _IssueFilter.dismissed:
        return BookingIssueStatus.dismissed;
      case _IssueFilter.all:
        return null;
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    try {
      final issues = await _service.listForBuilding(status: _statusForFilter);
      if (!mounted) return;
      setState(() {
        _issues = issues;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnack.error(context, 'admin.issues.load_error'.tr());
    }
  }

  void _setFilter(_IssueFilter filter) {
    if (filter == _filter) return;
    setState(() => _filter = filter);
    _load();
  }

  Future<void> _openBooking(BookingIssue issue) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookingDetailScreen(bookingId: issue.bookingId),
      ),
    );
    if (mounted) await _load(silent: true);
  }

  Future<void> _resolve(
    BookingIssue issue,
    BookingIssueStatus action,
  ) async {
    final ok = await showResolveBookingIssueDialog(
      context,
      issue: issue,
      action: action,
    );
    if (ok == true && mounted) {
      AppSnack.success(
        context,
        action == BookingIssueStatus.upheld
            ? 'admin.issues.success_upheld'.tr()
            : 'admin.issues.success_dismissed'.tr(),
      );
      await _load(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('admin.issues.title'.tr())),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _FilterChip(
                  label: 'admin.issues.filter_open'.tr(),
                  selected: _filter == _IssueFilter.open,
                  onSelected: () => _setFilter(_IssueFilter.open),
                ),
                _FilterChip(
                  label: 'admin.issues.filter_upheld'.tr(),
                  selected: _filter == _IssueFilter.upheld,
                  onSelected: () => _setFilter(_IssueFilter.upheld),
                ),
                _FilterChip(
                  label: 'admin.issues.filter_dismissed'.tr(),
                  selected: _filter == _IssueFilter.dismissed,
                  onSelected: () => _setFilter(_IssueFilter.dismissed),
                ),
                _FilterChip(
                  label: 'admin.issues.filter_all'.tr(),
                  selected: _filter == _IssueFilter.all,
                  onSelected: () => _setFilter(_IssueFilter.all),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const SkeletonList(count: 4);
    }

    if (_issues.isEmpty) {
      final isOpen = _filter == _IssueFilter.open;
      return RefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.1),
            EmptyState(
              icon: Icons.flag_outlined,
              title: (isOpen
                      ? 'admin.issues.empty_open_title'
                      : 'admin.issues.empty_title')
                  .tr(),
              message: (isOpen
                      ? 'admin.issues.empty_open_message'
                      : 'admin.issues.empty_message')
                  .tr(),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView.separated(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 32),
        itemCount: _issues.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final issue = _issues[index];
          return _AdminIssueCard(
            issue: issue,
            onOpen: () => _openBooking(issue),
            onUphold: issue.status == BookingIssueStatus.open
                ? () => _resolve(issue, BookingIssueStatus.upheld)
                : null,
            onDismiss: issue.status == BookingIssueStatus.open
                ? () => _resolve(issue, BookingIssueStatus.dismissed)
                : null,
          );
        },
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _AdminIssueCard extends StatelessWidget {
  final BookingIssue issue;
  final VoidCallback onOpen;
  final VoidCallback? onUphold;
  final VoidCallback? onDismiss;

  const _AdminIssueCard({
    required this.issue,
    required this.onOpen,
    this.onUphold,
    this.onDismiss,
  });

  ({String label, StatusTone tone, IconData icon}) _statusVisual() {
    switch (issue.status) {
      case BookingIssueStatus.open:
        return (
          label: 'bookings.issues.status_open'.tr(),
          tone: StatusTone.warning,
          icon: Icons.hourglass_top_rounded,
        );
      case BookingIssueStatus.upheld:
        return (
          label: 'bookings.issues.status_upheld'.tr(),
          tone: StatusTone.success,
          icon: Icons.check_circle_outline,
        );
      case BookingIssueStatus.dismissed:
        return (
          label: 'bookings.issues.status_dismissed'.tr(),
          tone: StatusTone.neutral,
          icon: Icons.block_rounded,
        );
    }
  }

  String _windowLabel() {
    final start = issue.bookingStart;
    final end = issue.bookingEnd;
    if (start == null || end == null) {
      return 'admin.issues.window_unknown'.tr();
    }
    final dateFmt = DateFormat('EEE MMM d');
    final timeFmt = DateFormat('h:mm a');
    return 'admin.issues.window'.tr(namedArgs: {
      'start': '${dateFmt.format(start.toLocal())} ${timeFmt.format(start.toLocal())}',
      'end': '${dateFmt.format(end.toLocal())} ${timeFmt.format(end.toLocal())}',
    });
  }

  String _reporterLabel() {
    final unit = issue.reporterApartmentIdentifier;
    final unitText = (unit != null && unit.isNotEmpty)
        ? unit
        : 'admin.issues.unit_unknown'.tr();
    if (issue.borrowerApartmentId != null &&
        issue.reporterApartmentId == issue.borrowerApartmentId) {
      return 'admin.issues.reporter_borrower'
          .tr(namedArgs: {'unit': unitText});
    }
    if (issue.lenderApartmentId != null &&
        issue.reporterApartmentId == issue.lenderApartmentId) {
      return 'admin.issues.reporter_lender'.tr(namedArgs: {'unit': unitText});
    }
    return 'admin.issues.reporter'.tr(namedArgs: {'unit': unitText});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vis = _statusVisual();
    final notes = issue.notes?.trim();
    final spot = issue.spotIdentifier;
    final createdFmt = DateFormat('MMM d, y • h:mm a');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          bookingIssueKindLabel(issue.kind),
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusChip(
                        label: vis.label,
                        tone: vis.tone,
                        icon: vis.icon,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    spot != null && spot.isNotEmpty
                        ? 'bookings.detail.spot_label'
                            .tr(namedArgs: {'id': spot})
                        : 'bookings.detail.parking_booking'.tr(),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _windowLabel(),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _reporterLabel(),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'admin.issues.created_at'.tr(namedArgs: {
                      'date': createdFmt.format(issue.createdAt.toLocal()),
                    }),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (notes != null && notes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      notes,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (onUphold != null && onDismiss != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onDismiss,
                      child: Text('admin.issues.dismiss'.tr()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: onUphold,
                      child: Text('admin.issues.uphold'.tr()),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
