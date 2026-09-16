import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../services/booking_service.dart';
import '../../services/auth_service.dart';
import '../../services/booking_issue_service.dart';
import '../../services/chat_service.dart';
import '../../models/booking_issue.dart';
import '../../models/booking_request.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/status_chip.dart';
import '../chat/chat_screen.dart';
import 'report_booking_issue_sheet.dart';

class BookingDetailScreen extends StatefulWidget {
  final String bookingId;

  const BookingDetailScreen({super.key, required this.bookingId});

  @override
  State<BookingDetailScreen> createState() => _BookingDetailScreenState();
}

class _BookingDetailScreenState extends State<BookingDetailScreen> {
  final _bookingService = BookingService();
  final _authService = AuthService();
  final _chatService = ChatService();
  final _issueService = BookingIssueService();
  BookingDetails? _details;
  String? _currentApartmentId;
  List<BookingIssue> _issues = const [];
  int _unread = 0;
  bool _isLoading = true;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _loadBooking();
  }

  Future<void> _loadBooking({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _bookingService.getBookingDetails(widget.bookingId),
        _authService.getCurrentProfile(),
        _issueService
            .listForBooking(widget.bookingId)
            .onError((_, __) => <BookingIssue>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _details = results[0] as BookingDetails?;
        _currentApartmentId =
            (results[1] as dynamic)?.apartmentId as String?;
        _issues = results[2] as List<BookingIssue>;
        _isLoading = false;
      });
      // Unread badge on the chat button — best-effort, never blocks the screen.
      try {
        final counts = await _chatService.getUnreadCounts();
        if (mounted) {
          setState(() => _unread = counts[widget.bookingId] ?? 0);
        }
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnack.error(context, 'bookings.detail.could_not_load'.tr(namedArgs: {'error': e.toString()}));
    }
  }

  Future<void> _approveBooking(bool approve) async {
    if (_details == null) return;
    setState(() => _isProcessing = true);
    try {
      await _bookingService.approveBooking(
        bookingId: _details!.booking.id,
        approve: approve,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) AppSnack.error(context, 'bookings.detail.could_not_load'.tr(namedArgs: {'error': e.toString()}));
    }
  }

  Future<void> _cancelBooking() async {
    if (_details == null) return;
    final isLender = _isLender();
    final counterparty = _details!.counterpartyNameFor(
          _currentApartmentId ?? '',
        ) ??
        (isLender
            ? 'bookings.detail.the_borrower'.tr()
            : 'bookings.detail.the_lender'.tr());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('bookings.cancel_dialog_title'.tr()),
        content: Text('bookings.cancel_dialog_message'.tr(namedArgs: {'counterparty': counterparty})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('bookings.keep_it'.tr()),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text('bookings.cancel_booking'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _bookingService.cancelBooking(_details!.booking.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) AppSnack.error(context, 'bookings.detail.could_not_load'.tr(namedArgs: {'error': e.toString()}));
    }
  }

  bool _isLender() {
    final d = _details;
    if (d == null || _currentApartmentId == null) return false;
    return _currentApartmentId == d.booking.lenderApartmentId;
  }

  bool _isParty() {
    final d = _details;
    if (d == null || _currentApartmentId == null) return false;
    return _currentApartmentId == d.booking.lenderApartmentId ||
        _currentApartmentId == d.booking.borrowerApartmentId;
  }

  bool _canReport() {
    final d = _details;
    final apt = _currentApartmentId;
    if (d == null || apt == null || !_isParty()) return false;
    if (!BookingIssue.isReportWindowOpen(d.booking, DateTime.now())) {
      return false;
    }
    return !_issues.any((issue) =>
        issue.reporterApartmentId == apt &&
        issue.status == BookingIssueStatus.open);
  }

  Future<void> _openReportSheet() async {
    final submitted = await showReportBookingIssueSheet(
      context,
      bookingId: widget.bookingId,
      isLender: _isLender(),
    );
    if (submitted == true && mounted) {
      AppSnack.success(context, 'bookings.issues.success'.tr());
      await _loadBooking(silent: true);
    }
  }

  ({String label, StatusTone tone, IconData icon}) _statusVisual(
      BookingStatus s) {
    switch (s) {
      case BookingStatus.pending:
        return (
          label: 'bookings.detail.status_pending'.tr(),
          tone: StatusTone.warning,
          icon: Icons.hourglass_top_rounded,
        );
      case BookingStatus.approved:
        return (
          label: 'bookings.detail.status_approved'.tr(),
          tone: StatusTone.success,
          icon: Icons.check_circle_outline,
        );
      case BookingStatus.rejected:
        return (
          label: 'bookings.detail.status_declined'.tr(),
          tone: StatusTone.danger,
          icon: Icons.cancel_outlined,
        );
      case BookingStatus.cancelled:
        return (
          label: 'bookings.detail.status_cancelled'.tr(),
          tone: StatusTone.neutral,
          icon: Icons.block_rounded,
        );
      case BookingStatus.completed:
        return (
          label: 'bookings.detail.status_completed'.tr(),
          tone: StatusTone.info,
          icon: Icons.done_all_rounded,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text('bookings.detail.title'.tr())),
        body: const SkeletonList(count: 3),
      );
    }

    if (_details == null) {
      return Scaffold(
        appBar: AppBar(title: Text('bookings.detail.title'.tr())),
        body: Center(child: Text('bookings.detail.not_found'.tr())),
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = _details!;
    final b = d.booking;
    final isLender = _isLender();
    final vis = _statusVisual(b.status);
    final dateFmt = DateFormat('EEE MMM d, y');
    final timeFmt = DateFormat('h:mm a');

    final spotLabel = d.spotIdentifier != null
        ? 'bookings.detail.spot_label'.tr(namedArgs: {'id': d.spotIdentifier!})
        : 'bookings.detail.parking_booking'.tr();
    final counterpartyLabel = isLender
        ? (d.borrowerDisplayName ?? 'bookings.detail.borrower_label'.tr())
        : (d.lenderDisplayName ?? 'bookings.detail.lender_label'.tr());
    final counterpartyRole = isLender
        ? 'bookings.detail.borrower_label'.tr()
        : 'bookings.detail.lender_label'.tr();

    return Scaffold(
      appBar: AppBar(title: Text('bookings.detail.title'.tr())),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 16),
              children: [
                _HeaderCard(
                  spotLabel: spotLabel,
                  counterpartyLabel: counterpartyLabel,
                  counterpartyRole: counterpartyRole,
                  status: vis,
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'bookings.detail.when_label'.tr(),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _TimeRow(
                          label: 'bookings.detail.starts'.tr(),
                          date: dateFmt.format(b.startTime.toLocal()),
                          time: timeFmt.format(b.startTime.toLocal()),
                        ),
                        const SizedBox(height: 12),
                        Divider(color: scheme.outlineVariant),
                        const SizedBox(height: 12),
                        _TimeRow(
                          label: 'bookings.detail.ends'.tr(),
                          date: dateFmt.format(b.endTime.toLocal()),
                          time: timeFmt.format(b.endTime.toLocal()),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (b.status == BookingStatus.pending && isLender)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : () => _approveBooking(false),
                          icon: Icon(Icons.close_rounded, color: scheme.error),
                          label: Text('bookings.detail.decline'.tr(),
                              style: TextStyle(color: scheme.error)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: scheme.error),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : () => _approveBooking(true),
                          icon: const Icon(Icons.check_rounded),
                          label: Text('bookings.detail.approve'.tr()),
                        ),
                      ),
                    ],
                  )
                else if (b.status == BookingStatus.pending ||
                    b.status == BookingStatus.approved)
                  OutlinedButton.icon(
                    onPressed: _cancelBooking,
                    icon: Icon(Icons.close_rounded, color: scheme.error),
                    label: Text('bookings.cancel_booking'.tr(),
                        style: TextStyle(color: scheme.error)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: scheme.error),
                    ),
                  ),
                if (_issues.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'bookings.issues.section_title'.tr(),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  for (final issue in _issues) ...[
                    _IssueCard(issue: issue),
                    const SizedBox(height: 8),
                  ],
                ],
                if (_canReport()) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _openReportSheet,
                    icon: const Icon(Icons.flag_outlined),
                    label: Text('bookings.issues.report'.tr()),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 16),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(bookingId: b.id),
                    ),
                  );
                  // Opening the thread marks it read — clear the badge.
                  if (mounted) setState(() => _unread = 0);
                },
                icon: Badge.count(
                  count: _unread,
                  isLabelVisible: _unread > 0,
                  child: const Icon(Icons.chat_bubble_outline_rounded),
                ),
                label: Text('bookings.detail.open_chat'.tr()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final String spotLabel;
  final String counterpartyLabel;
  final String counterpartyRole;
  final ({String label, StatusTone tone, IconData icon}) status;

  const _HeaderCard({
    required this.spotLabel,
    required this.counterpartyLabel,
    required this.counterpartyRole,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.local_parking_rounded,
                      color: scheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(spotLabel, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 2),
                      Text(
                        '$counterpartyRole · $counterpartyLabel',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: StatusChip(
                label: status.label,
                tone: status.tone,
                icon: status.icon,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IssueCard extends StatelessWidget {
  final BookingIssue issue;

  const _IssueCard({required this.issue});

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vis = _statusVisual();
    final notes = issue.notes?.trim();

    return Card(
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
    );
  }
}

class _TimeRow extends StatelessWidget {
  final String label;
  final String date;
  final String time;
  const _TimeRow({
    required this.label,
    required this.date,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(date, style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                time,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
