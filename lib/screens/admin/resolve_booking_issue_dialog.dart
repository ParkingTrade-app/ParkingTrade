import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/booking_issue.dart';
import '../../services/booking_issue_service.dart';
import '../bookings/report_booking_issue_sheet.dart';

/// Maps `resolve_booking_issue` failures to `admin.issues.*` keys.
@visibleForTesting
String resolveBookingIssueErrorKey(Object error) {
  final msg = error.toString().toLowerCase();
  if (msg.contains('resolution notes must be at most 500') ||
      msg.contains('notes must be at most 500')) {
    return 'admin.issues.error_notes';
  }
  if (msg.contains('only building admins')) {
    return 'admin.issues.error_admin';
  }
  if (msg.contains('already')) {
    return 'admin.issues.error_already';
  }
  if (msg.contains('not in your building')) {
    return 'admin.issues.error_building';
  }
  return 'admin.issues.error_generic';
}

/// Building-admin uphold / dismiss dialog. Returns `true` on success.
Future<bool?> showResolveBookingIssueDialog(
  BuildContext context, {
  required BookingIssue issue,
  required BookingIssueStatus action,
}) {
  assert(
    action == BookingIssueStatus.upheld ||
        action == BookingIssueStatus.dismissed,
  );
  return showDialog<bool>(
    context: context,
    builder: (context) => ResolveBookingIssueDialog(
      issue: issue,
      action: action,
    ),
  );
}

class ResolveBookingIssueDialog extends StatefulWidget {
  final BookingIssue issue;
  final BookingIssueStatus action;

  const ResolveBookingIssueDialog({
    super.key,
    required this.issue,
    required this.action,
  });

  @override
  State<ResolveBookingIssueDialog> createState() =>
      _ResolveBookingIssueDialogState();
}

class _ResolveBookingIssueDialogState extends State<ResolveBookingIssueDialog> {
  final _service = BookingIssueService();
  final _notesController = TextEditingController();
  bool _submitting = false;
  String? _errorKey;

  bool get _isUphold => widget.action == BookingIssueStatus.upheld;

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
      await _service.resolve(
        issueId: widget.issue.id,
        action: widget.action,
        notes: _notesController.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorKey = resolveBookingIssueErrorKey(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = bookingIssueKindLabel(widget.issue.kind);

    return AlertDialog(
      title: Text(
        _isUphold
            ? 'admin.issues.resolve_uphold_title'.tr()
            : 'admin.issues.resolve_dismiss_title'.tr(),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'admin.issues.resolve_body'.tr(namedArgs: {'kind': kind}),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _notesController,
              enabled: !_submitting,
              maxLength: kBookingIssueNotesMaxLength,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              maxLines: 3,
              minLines: 2,
              decoration: InputDecoration(
                labelText: 'admin.issues.notes_label'.tr(),
                hintText: 'admin.issues.notes_hint'.tr(),
                alignLabelWithHint: true,
              ),
            ),
            if (_errorKey != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorKey!.tr(),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: Text('admin.issues.cancel'.tr()),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: _isUphold
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                ),
          child: _submitting
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onPrimary,
                  ),
                )
              : Text(
                  _isUphold
                      ? 'admin.issues.confirm_uphold'.tr()
                      : 'admin.issues.confirm_dismiss'.tr(),
                ),
        ),
      ],
    );
  }
}
