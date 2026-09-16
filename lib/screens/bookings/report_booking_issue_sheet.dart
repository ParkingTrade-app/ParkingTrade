import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/booking_issue.dart';
import '../../services/booking_issue_service.dart';

const int kBookingIssueNotesMaxLength = 500;

/// Maps `report_booking_issue` / unique-index failures to `bookings.issues.*` keys.
@visibleForTesting
String reportBookingIssueErrorKey(Object error) {
  final msg = error.toString().toLowerCase();
  if (msg.contains('report window')) {
    return 'bookings.issues.error_window';
  }
  if (msg.contains('23505') ||
      msg.contains('uq_booking_issues_open_per_apartment') ||
      msg.contains('duplicate key')) {
    return 'bookings.issues.error_already_open';
  }
  if (msg.contains('only a booking party') ||
      msg.contains('only the borrower') ||
      msg.contains('only the lender')) {
    return 'bookings.issues.error_party';
  }
  if (msg.contains('notes must be at most 500')) {
    return 'bookings.issues.error_notes';
  }
  if (msg.contains('can only report on an approved')) {
    return 'bookings.issues.error_status';
  }
  return 'bookings.issues.error_generic';
}

String bookingIssueKindLabel(BookingIssueKind kind) {
  switch (kind) {
    case BookingIssueKind.lenderDidNotVacate:
      return 'bookings.issues.kind_lender_did_not_vacate'.tr();
    case BookingIssueKind.borrowerDidNotArrive:
      return 'bookings.issues.kind_borrower_did_not_arrive'.tr();
    case BookingIssueKind.borrowerOverstay:
      return 'bookings.issues.kind_borrower_overstay'.tr();
  }
}

/// Modal sheet for filing a party-gated booking issue.
///
/// Returns `true` if a report was submitted, `false`/`null` if dismissed.
Future<bool?> showReportBookingIssueSheet(
  BuildContext context, {
  required String bookingId,
  required bool isLender,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => ReportBookingIssueSheet(
      bookingId: bookingId,
      isLender: isLender,
    ),
  );
}

class ReportBookingIssueSheet extends StatefulWidget {
  final String bookingId;
  final bool isLender;

  const ReportBookingIssueSheet({
    super.key,
    required this.bookingId,
    required this.isLender,
  });

  @override
  State<ReportBookingIssueSheet> createState() =>
      _ReportBookingIssueSheetState();
}

class _ReportBookingIssueSheetState extends State<ReportBookingIssueSheet> {
  final _service = BookingIssueService();
  final _notesController = TextEditingController();
  late final List<BookingIssueKind> _kinds;
  late BookingIssueKind _kind;
  bool _submitting = false;
  String? _errorKey;

  @override
  void initState() {
    super.initState();
    _kinds = BookingIssue.kindsFor(isLender: widget.isLender);
    _kind = _kinds.first;
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _errorKey = null;
    });
    try {
      await _service.report(
        bookingId: widget.bookingId,
        kind: _kind,
        notes: _notesController.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorKey = reportBookingIssueErrorKey(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'bookings.issues.report_title'.tr(),
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'bookings.issues.report_subtitle'.tr(),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              RadioGroup<BookingIssueKind>(
                groupValue: _kind,
                onChanged: (value) {
                  if (_submitting || value == null) return;
                  setState(() => _kind = value);
                },
                child: Column(
                  children: [
                    for (final kind in _kinds)
                      RadioListTile<BookingIssueKind>(
                        value: kind,
                        enabled: !_submitting,
                        contentPadding: EdgeInsets.zero,
                        title: Text(bookingIssueKindLabel(kind)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notesController,
                enabled: !_submitting,
                maxLength: kBookingIssueNotesMaxLength,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  labelText: 'bookings.issues.notes_label'.tr(),
                  hintText: 'bookings.issues.notes_hint'.tr(),
                  alignLabelWithHint: true,
                ),
              ),
              if (_errorKey != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorKey!.tr(),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onPrimary,
                          ),
                        )
                      : Text('bookings.issues.submit'.tr()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
