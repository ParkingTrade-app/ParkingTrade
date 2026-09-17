import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../services/admin_service.dart';
import '../../services/building_service.dart';
import '../../services/announcement_service.dart';
import '../../services/auth_service.dart';
import '../../services/booking_issue_service.dart';
import '../../models/admin_parking_spot.dart';
import '../../models/authorized_apartment.dart';
import '../../models/building.dart';
import '../../models/building_announcement.dart';
import '../../models/building_join_request.dart';
import '../../models/profile.dart';
import '../../widgets/address_autocomplete_field.dart';
import '../../theme/app_theme.dart';
import '../../theme/gradient_app_bar.dart';
import '../../widgets/app_snack.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/status_chip.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  final _adminService = AdminService();
  final _issueService = BookingIssueService();
  late TabController _tabController;
  List<Profile> _pendingMembers = [];
  List<Profile> _allMembers = [];
  List<BuildingJoinRequest> _joinRequests = [];
  int _openIssueCount = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // Length stays 8 — booking issues are a dedicated screen, not a 9th tab.
    _tabController = TabController(length: 8, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _adminService.getPendingMembers(),
        _adminService.getBuildingMembers(),
        _adminService.getJoinRequests(),
        _issueService.countOpen().onError((_, __) => 0),
      ]);
      if (!mounted) return;
      setState(() {
        _pendingMembers = results[0] as List<Profile>;
        _allMembers = results[1] as List<Profile>;
        _joinRequests = results[2] as List<BuildingJoinRequest>;
        _openIssueCount = results[3] as int;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnack.error(
          context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _openIssues() async {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      await router.push('/admin-issues');
    } else {
      await Navigator.of(context).pushNamed('/admin-issues');
    }
    if (!mounted) return;
    try {
      final n = await _issueService.countOpen();
      if (mounted) setState(() => _openIssueCount = n);
    } catch (_) {}
  }

  Future<void> _handleAction(Profile member, String action) async {
    final isDestructive = action != 'approve';
    final name = member.displayName ?? tr('admin.members.unnamed');

    String dialogTitle;
    String dialogBody;
    String confirmLabel;
    String successMsg;

    switch (action) {
      case 'approve':
        dialogTitle = tr('admin.dialog.approve_title');
        dialogBody = tr('admin.dialog.approve_body', namedArgs: {'name': name});
        confirmLabel = tr('admin.dialog.confirm_approve');
        successMsg = tr('admin.dialog.approved_success');
        break;
      case 'reject':
        dialogTitle = tr('admin.dialog.reject_title');
        dialogBody = tr('admin.dialog.reject_body', namedArgs: {'name': name});
        confirmLabel = tr('admin.dialog.confirm_reject');
        successMsg = tr('admin.dialog.rejected_success');
        break;
      default: // revoke
        dialogTitle = tr('admin.dialog.revoke_title');
        dialogBody = tr('admin.dialog.revoke_body', namedArgs: {'name': name});
        confirmLabel = tr('admin.dialog.confirm_revoke');
        successMsg = tr('admin.dialog.revoked_success');
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(dialogTitle),
        content: Text(dialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('admin.dialog.cancel'.tr()),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: isDestructive
                ? FilledButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await _adminService.manageMember(
        memberId: member.id,
        action: action,
      );
      if (!mounted) return;
      AppSnack.success(context, successMsg);
      _loadData();
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(
          context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  Widget _buildPendingList() {
    if (_isLoading) return const SkeletonList(count: 3);

    if (_pendingMembers.isEmpty) {
      return EmptyState(
        icon: Icons.inbox_rounded,
        title: 'admin.pending.empty_title'.tr(),
        message: 'admin.pending.empty_message'.tr(),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        padding: const EdgeInsetsDirectional.fromSTEB(32, 28, 32, 32),
        itemCount: _pendingMembers.length,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          final member = _pendingMembers[index];
          return _PendingMemberCard(
            member: member,
            onApprove: () => _handleAction(member, 'approve'),
            onReject: () => _handleAction(member, 'reject'),
          );
        },
      ),
    );
  }

  Future<void> _handleJoinReview(
      BuildingJoinRequest request, String action) async {
    final name = request.displayName?.trim().isNotEmpty == true
        ? request.displayName!.trim()
        : request.phone;

    String? reason;
    if (action == 'reject') {
      final reasonController = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('admin.join_requests.reject_title'.tr()),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('admin.join_requests.reject_body',
                  namedArgs: {'name': name})),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'admin.join_requests.reason_label'.tr(),
                  hintText: 'admin.join_requests.reason_hint'.tr(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('admin.dialog.cancel'.tr()),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text('admin.join_requests.confirm_reject'.tr()),
            ),
          ],
        ),
      );
      reason = reasonController.text.trim();
      reasonController.dispose();
      if (confirmed != true || !mounted) return;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('admin.join_requests.approve_title'.tr()),
          content: Text(tr('admin.join_requests.approve_body', namedArgs: {
            'name': name,
            'unit': request.apartmentIdentifier,
          })),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('admin.dialog.cancel'.tr()),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('admin.join_requests.confirm_approve'.tr()),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    try {
      await _adminService.reviewJoinRequest(
        requestId: request.id,
        action: action,
        reason: reason,
      );
      if (!mounted) return;
      AppSnack.success(
        context,
        action == 'approve'
            ? 'admin.join_requests.approved_success'.tr()
            : 'admin.join_requests.rejected_success'.tr(),
      );
      _loadData();
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  Widget _buildJoinRequestsList() {
    if (_isLoading) return const SkeletonList(count: 3);

    if (_joinRequests.isEmpty) {
      return EmptyState(
        icon: Icons.how_to_reg_outlined,
        title: 'admin.join_requests.empty_title'.tr(),
        message: 'admin.join_requests.empty_message'.tr(),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        padding: const EdgeInsetsDirectional.fromSTEB(32, 28, 32, 32),
        itemCount: _joinRequests.length,
        separatorBuilder: (_, __) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          final request = _joinRequests[index];
          return _JoinRequestCard(
            request: request,
            onApprove: () => _handleJoinReview(request, 'approve'),
            onReject: () => _handleJoinReview(request, 'reject'),
          );
        },
      ),
    );
  }

  Widget _buildAllMembersList() {
    if (_isLoading) return const SkeletonList(count: 4);

    if (_allMembers.isEmpty) {
      return EmptyState(
        icon: Icons.people_outline_rounded,
        title: 'admin.members.empty_title'.tr(),
        message: 'admin.members.empty_message'.tr(),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        padding: const EdgeInsetsDirectional.fromSTEB(32, 28, 32, 32),
        itemCount: _allMembers.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final member = _allMembers[index];
          return _MemberCard(
            member: member,
            onRevoke: member.status == ProfileStatus.approved && !member.isAdmin
                ? () => _handleAction(member, 'revoke')
                : null,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: AppTheme.brandGradient,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.brandIndigo.withValues(alpha: 0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(
                Icons.local_parking_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Text('admin.title'.tr()),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'admin.issues.tooltip'.tr(),
            onPressed: _openIssues,
            icon: Badge.count(
              count: _openIssueCount,
              isLabelVisible: _openIssueCount > 0,
              child: const Icon(Icons.flag_outlined),
            ),
          ),
          IconButton(
            tooltip: 'language_toggle'.tr(),
            icon: const Icon(Icons.translate_rounded),
            onPressed: () {
              final current = context.locale;
              context.setLocale(
                current.languageCode == 'he'
                    ? const Locale('en')
                    : const Locale('he'),
              );
            },
          ),
          IconButton(
            tooltip: 'admin.sign_out'.tr(),
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async {
              await AuthService().signOut();
              if (context.mounted) {
                context.go('/auth');
              }
            },
          ),
          const SizedBox(width: 16),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Column(
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      splashBorderRadius:
                          BorderRadius.circular(AppTheme.radiusSm),
                      tabs: [
                        Tab(
                          text: _pendingMembers.isEmpty
                              ? 'admin.tab_pending'.tr()
                              : tr('admin.tab_pending_count',
                                  namedArgs: {
                                      'count': '${_pendingMembers.length}'
                                    }),
                        ),
                        Tab(
                          text: _joinRequests.isEmpty
                              ? 'admin.tab_join_requests'.tr()
                              : tr('admin.tab_join_requests_count', namedArgs: {
                                  'count': '${_joinRequests.length}'
                                }),
                        ),
                        Tab(
                          text: tr('admin.tab_members',
                              namedArgs: {'count': '${_allMembers.length}'}),
                        ),
                        Tab(text: 'admin.tab_apartments'.tr()),
                        Tab(text: 'admin.tab_spots'.tr()),
                        Tab(text: 'admin.tab_bulk_import'.tr()),
                        Tab(text: 'admin.tab_settings'.tr()),
                        Tab(text: 'admin.tab_announcements'.tr()),
                      ],
                    ),
                  ),
                ),
              ),
              const BrandAccentBar(),
            ],
          ),
        ),
      ),
      body: Container(
        // Soft top gradient wash to add depth without distracting from content.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.brandIndigo.withValues(alpha: 0.025),
              scheme.surface,
            ],
            stops: const [0.0, 0.35],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildPendingList(),
                _buildJoinRequestsList(),
                _buildAllMembersList(),
                _ManageApartmentsTab(adminService: _adminService),
                _SpotManagementTab(
                  adminService: _adminService,
                  onOpenBulkImport: () => _tabController.animateTo(5),
                ),
                _BulkImportTab(adminService: _adminService),
                _BuildingSettingsTab(adminService: _adminService),
                const _AnnouncementsTab(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingMemberCard extends StatelessWidget {
  final Profile member;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _PendingMemberCard({
    required this.member,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dateFmt = DateFormat('MMM d, y');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Avatar(name: member.displayName),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.displayName ?? 'admin.pending.unnamed'.tr(),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tr('admin.pending.requested_on',
                        namedArgs: {'date': dateFmt.format(member.createdAt.toLocal())}),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            StatusChip(
              label: 'admin.pending.pending_chip'.tr(),
              tone: StatusTone.warning,
              icon: Icons.hourglass_top_rounded,
            ),
            const SizedBox(width: 16),
            OutlinedButton.icon(
              onPressed: onReject,
              icon: Icon(Icons.close_rounded, color: scheme.error, size: 18),
              label: Text('admin.pending.decline'.tr(),
                  style: TextStyle(color: scheme.error)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: scheme.error),
                minimumSize: const Size(0, 40),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: onApprove,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text('admin.pending.approve'.tr()),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinRequestCard extends StatelessWidget {
  final BuildingJoinRequest request;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _JoinRequestCard({
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dateFmt = DateFormat('MMM d, y');
    final name = request.displayName?.trim().isNotEmpty == true
        ? request.displayName!.trim()
        : 'admin.join_requests.unnamed'.tr();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Avatar(name: request.displayName),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 3),
                      Text(
                        '${request.phone}  ·  ${tr('admin.join_requests.unit', namedArgs: {
                              'unit': request.apartmentIdentifier
                            })}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        tr('admin.join_requests.requested_on', namedArgs: {
                          'date': dateFmt.format(request.createdAt.toLocal())
                        }),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StatusChip(
                  label: 'admin.join_requests.pending_chip'.tr(),
                  tone: StatusTone.warning,
                  icon: Icons.hourglass_top_rounded,
                ),
              ],
            ),
            if (request.note?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(request.note!.trim(),
                    style: theme.textTheme.bodySmall),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: onReject,
                  icon: Icon(Icons.close_rounded, color: scheme.error, size: 18),
                  label: Text('admin.join_requests.decline'.tr(),
                      style: TextStyle(color: scheme.error)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: scheme.error),
                    minimumSize: const Size(0, 40),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text('admin.join_requests.approve'.tr()),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  final Profile member;
  final VoidCallback? onRevoke;

  const _MemberCard({
    required this.member,
    required this.onRevoke,
  });

  StatusTone _tone(ProfileStatus s) {
    switch (s) {
      case ProfileStatus.approved:
        return StatusTone.success;
      case ProfileStatus.pending:
        return StatusTone.warning;
      case ProfileStatus.rejected:
        return StatusTone.danger;
    }
  }

  String _statusLabel(ProfileStatus s) {
    switch (s) {
      case ProfileStatus.approved:
        return 'admin.members.status_approved'.tr();
      case ProfileStatus.pending:
        return 'admin.members.status_pending'.tr();
      case ProfileStatus.rejected:
        return 'admin.members.status_rejected'.tr();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            _Avatar(name: member.displayName),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          member.displayName ?? 'admin.members.unnamed'.tr(),
                          style: theme.textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (member.isAdmin) ...[
                        const SizedBox(width: 8),
                        StatusChip(
                          label: 'admin.members.admin_chip'.tr(),
                          tone: StatusTone.info,
                          icon: Icons.shield_outlined,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  StatusChip(
                    label: _statusLabel(member.status),
                    tone: _tone(member.status),
                  ),
                ],
              ),
            ),
            if (onRevoke != null)
              IconButton(
                tooltip: 'admin.members.revoke_tooltip'.tr(),
                icon: Icon(Icons.person_remove_outlined, color: scheme.error),
                onPressed: onRevoke,
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Manage Apartments Tab ────────────────────────────────────────────────────

class _ManageApartmentsTab extends StatefulWidget {
  final AdminService adminService;
  const _ManageApartmentsTab({required this.adminService});

  @override
  State<_ManageApartmentsTab> createState() => _ManageApartmentsTabState();
}

class _ManageApartmentsTabState extends State<_ManageApartmentsTab> {
  final _formKey = GlobalKey<FormState>();
  final _unitController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  final _spotController = TextEditingController();
  final _spotFocusNode = FocusNode();

  /// Residents currently staged inside the "Add apartment" form (before submission).
  final List<Resident> _stagedResidents = [];

  /// Parking spot identifiers currently staged inside the "Add apartment" form.
  final List<String> _stagedSpots = [];

  List<AuthorizedApartment> _apartments = [];
  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _isGeneratingMock = false;

  @override
  void initState() {
    super.initState();
    _loadApartments();
  }

  @override
  void dispose() {
    _unitController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    _spotController.dispose();
    _spotFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadApartments() async {
    setState(() => _isLoading = true);
    try {
      final data = await widget.adminService.getAuthorizedApartments();
      if (!mounted) return;
      setState(() {
        _apartments = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Validates name + phone fields and, if valid, appends a [Resident] chip.
  /// Returns true if a resident was staged.
  bool _stageResidentFromFields() {
    final rawPhone = _phoneController.text.trim();
    if (rawPhone.isEmpty) return false;

    final normalised = AuthService.normalisePhone(rawPhone);
    if (!RegExp(r'^\+\d{7,15}$').hasMatch(normalised)) {
      AppSnack.error(context, 'admin.apartments.phone_invalid'.tr());
      return false;
    }
    if (_stagedResidents.any((r) => r.phone == normalised)) {
      AppSnack.error(context, 'admin.apartments.phone_already_added'.tr());
      return false;
    }

    final name = _nameController.text.trim();
    setState(() {
      _stagedResidents.add(Resident(name: name, phone: normalised));
      _nameController.clear();
      _phoneController.clear();
    });
    // Refocus the phone field so the admin can keep typing the next number.
    _phoneFocusNode.requestFocus();
    return true;
  }

  void _removeStagedResident(Resident resident) {
    setState(() => _stagedResidents.remove(resident));
  }

  /// Validates the spot field and, if valid, appends a spot chip.
  bool _stageSpotFromField() {
    final raw = _spotController.text.trim();
    if (raw.isEmpty) return false;
    if (_stagedSpots.contains(raw)) {
      AppSnack.error(context, 'admin.apartments.spot_already_added'.tr());
      return false;
    }
    setState(() {
      _stagedSpots.add(raw);
      _spotController.clear();
    });
    _spotFocusNode.requestFocus();
    return true;
  }

  void _removeStagedSpot(String spot) {
    setState(() => _stagedSpots.remove(spot));
  }

  Future<void> _addApartment() async {
    // If the admin typed a phone (and optionally a name) without pressing the
    // inline Add button, fold that entry in now.
    if (_phoneController.text.trim().isNotEmpty) {
      if (!_stageResidentFromFields()) return;
    }

    // Same for any partially-typed spot identifier.
    if (_spotController.text.trim().isNotEmpty) {
      if (!_stageSpotFromField()) return;
    }

    if (!_formKey.currentState!.validate()) return;

    if (_stagedResidents.isEmpty) {
      AppSnack.error(context, 'admin.apartments.at_least_one_phone'.tr());
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await widget.adminService.addAuthorizedApartment(
        unitNumber: _unitController.text.trim(),
        residents: List<Resident>.from(_stagedResidents),
        parkingSpotIdentifiers: List<String>.from(_stagedSpots),
      );
      if (!mounted) return;
      AppSnack.success(context, 'admin.apartments.added_success'.tr());
      setState(() {
        _unitController.clear();
        _nameController.clear();
        _phoneController.clear();
        _spotController.clear();
        _stagedResidents.clear();
        _stagedSpots.clear();
      });
      _loadApartments();
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _editApartment(AuthorizedApartment apt) async {
    final result = await showDialog<({List<Resident> residents, List<String> spots})>(
      context: context,
      builder: (context) => _EditApartmentDialog(apartment: apt),
    );

    if (result == null || !mounted) return;

    try {
      await widget.adminService.updateAuthorizedApartmentResidents(
        id: apt.id,
        residents: result.residents,
        parkingSpotIdentifiers: result.spots,
      );
      if (!mounted) return;
      AppSnack.success(context, 'admin.apartments.saved_success'.tr());
      _loadApartments();
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _deleteApartment(String id, String unit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('admin.apartments.remove_dialog_title'.tr()),
        content: Text(
          tr('admin.apartments.remove_dialog_body', namedArgs: {'unit': unit}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('admin.dialog.cancel'.tr()),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text('admin.apartments.remove_button'.tr()),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await widget.adminService.deleteAuthorizedApartment(id);
      if (!mounted) return;
      AppSnack.success(context, 'admin.apartments.removed_success'.tr());
      _loadApartments();
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Injects 20 fake apartments (units 101–120) with dummy Israeli phone numbers.
  /// Only callable in debug mode — the button that triggers this is itself
  /// wrapped in [kDebugMode], so this is purely a belt-and-suspenders guard.
  Future<void> _generateMockData() async {
    assert(kDebugMode, '_generateMockData must only be called in debug mode');
    setState(() => _isGeneratingMock = true);
    try {
      for (int i = 1; i <= 20; i++) {
        final unit = '${100 + i}';           // "101" … "120"
        final base = 100 + i;                // 101 … 120
        // Give even-numbered units 2 residents, odd ones 1.
        final residents = <Resident>[
          Resident(name: 'Resident A', phone: '+972500000$base'),
        ];
        if (i.isEven) {
          residents.add(Resident(name: 'Resident B', phone: '+972500001$base'));
        }

        await widget.adminService.addAuthorizedApartment(
          unitNumber: unit,
          residents: residents,
        );
      }
      if (!mounted) return;
      await _loadApartments();
      if (!mounted) return;
      AppSnack.success(context, 'Mock data injected successfully');
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isGeneratingMock = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return CustomScrollView(
      slivers: [
        // ── Add Apartment Form Card ──────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(32, 32, 32, 0),
            child: Card(
              color: scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.add_home_rounded,
                              size: 20, color: scheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            'admin.apartments.add_title'.tr(),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Unit number
                          SizedBox(
                            width: 130,
                            child: TextFormField(
                              controller: _unitController,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: 'admin.apartments.unit_label'.tr(),
                                hintText: 'admin.apartments.unit_hint'.tr(),
                                prefixIcon: const Icon(Icons.door_front_door_outlined),
                              ),
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty)
                                      ? 'admin.apartments.unit_required'.tr()
                                      : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Right-hand column: residents field + spots field stacked
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Chips-based residents input — name + phone per entry.
                                _ResidentChipsField(
                                  residents: _stagedResidents,
                                  nameController: _nameController,
                                  phoneController: _phoneController,
                                  phoneFocusNode: _phoneFocusNode,
                                  onAddResident: _stageResidentFromFields,
                                  onRemoveResident: _removeStagedResident,
                                ),
                                const SizedBox(height: 12),
                                // Chips-based parking spots input.
                                _SpotChipsField(
                                  spots: _stagedSpots,
                                  spotController: _spotController,
                                  spotFocusNode: _spotFocusNode,
                                  onAddSpot: _stageSpotFromField,
                                  onRemoveSpot: _removeStagedSpot,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Add button — aligned to the input height
                          SizedBox(
                            height: 52,
                            child: FilledButton.icon(
                              onPressed: _isSubmitting ? null : _addApartment,
                              icon: _isSubmitting
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: scheme.onPrimary,
                                      ),
                                    )
                                  : const Icon(Icons.add_rounded),
                              label: Text(
                                  _isSubmitting
                                      ? 'admin.apartments.adding'.tr()
                                      : 'admin.apartments.add_button'.tr()),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // ── Section header ───────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(32, 32, 32, 12),
            child: Row(
              children: [
                Text(
                  'admin.apartments.section_title'.tr(),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0.5,
                  ),
                ),
                if (!_isLoading && _apartments.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${_apartments.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                // ── DEBUG ONLY: Generate Mock Data ──────────────────────────
                if (kDebugMode)
                  OutlinedButton.icon(
                    onPressed: (_isGeneratingMock || _isSubmitting)
                        ? null
                        : _generateMockData,
                    icon: _isGeneratingMock
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.primary,
                            ),
                          )
                        : const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label: Text(
                      _isGeneratingMock ? 'Generating…' : 'Generate Mock Data',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.tertiary,
                      side: BorderSide(
                          color: scheme.tertiary.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ),
        ),

        // ── Apartment List ───────────────────────────────────────────────────
        if (_isLoading)
          const SliverFillRemaining(
            child: SkeletonList(count: 5),
          )
        else if (_apartments.isEmpty)
          SliverFillRemaining(
            child: EmptyState(
              icon: Icons.door_front_door_outlined,
              title: 'admin.apartments.empty_title'.tr(),
              message: 'admin.apartments.empty_message'.tr(),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsetsDirectional.fromSTEB(32, 0, 32, 32),
            sliver: SliverList.separated(
              itemCount: _apartments.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final apt = _apartments[index];
                return _ApartmentCard(
                  apartment: apt,
                  onEdit: () => _editApartment(apt),
                  onDelete: () =>
                      _deleteApartment(apt.id, apt.unitNumber),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ─── Resident chips field ────────────────────────────────────────────────────
//
// Shows staged [Resident] objects as deletable chips above a two-field row:
//   [ Name ] [ Phone ] [ + ]
// Tapping + (or pressing Enter in the Phone field) calls [onAddResident],
// which validates the inputs and appends a new Resident chip. Tapping the ×
// on a chip calls [onRemoveResident]. Used in both the "Add apartment" form
// and [_EditApartmentDialog].

class _ResidentChipsField extends StatelessWidget {
  final List<Resident> residents;
  final TextEditingController nameController;
  final TextEditingController phoneController;
  final FocusNode? phoneFocusNode;

  /// Called when the inline + button is tapped or Enter is pressed in the
  /// phone field. Should validate, create a [Resident], push it into
  /// [residents], and clear the controllers on success.
  final VoidCallback onAddResident;

  /// Called when the × on a chip is tapped.
  final void Function(Resident resident) onRemoveResident;

  const _ResidentChipsField({
    required this.residents,
    required this.nameController,
    required this.phoneController,
    required this.onAddResident,
    required this.onRemoveResident,
    this.phoneFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Staged resident chips shown above the input row.
        if (residents.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in residents)
                InputChip(
                  label: Text(r.displayLabel),
                  avatar: Icon(
                    Icons.person_outline_rounded,
                    size: 16,
                    color: scheme.onSecondaryContainer,
                  ),
                  onDeleted: () => onRemoveResident(r),
                  deleteIconColor: scheme.onSecondaryContainer,
                  backgroundColor: scheme.secondaryContainer,
                  labelStyle: TextStyle(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        // Name + Phone entry row.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Name field (optional)
            Expanded(
              flex: 2,
              child: TextField(
                controller: nameController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'admin.apartments.name_label'.tr(),
                  hintText: 'admin.apartments.name_hint'.tr(),
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Phone field (required)
            Expanded(
              flex: 3,
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      (event.logicalKey == LogicalKeyboardKey.enter ||
                          event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
                    onAddResident();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: phoneController,
                  focusNode: phoneFocusNode,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onAddResident(),
                  decoration: InputDecoration(
                    labelText: 'admin.apartments.phones_label'.tr(),
                    hintText: 'admin.apartments.phones_hint'.tr(),
                    helperText: residents.isEmpty
                        ? 'admin.apartments.phones_helper'.tr()
                        : null,
                    prefixIcon: const Icon(Icons.phone_outlined),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Inline add button
            IconButton.filledTonal(
              tooltip: 'admin.apartments.add_phone_tooltip'.tr(),
              icon: const Icon(Icons.person_add_outlined),
              onPressed: onAddResident,
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Parking spot chips field ────────────────────────────────────────────────
//
// Shows staged parking spot identifiers as deletable chips above a single
// text input:
//   [ Spot identifier ] [ + ]
// Tapping + (or pressing Enter) calls [onAddSpot] which validates and appends
// a new spot chip. Tapping × removes the chip via [onRemoveSpot].
// Used in both the "Add apartment" form and [_EditApartmentDialog].

class _SpotChipsField extends StatelessWidget {
  final List<String> spots;
  final TextEditingController spotController;
  final FocusNode? spotFocusNode;
  final VoidCallback onAddSpot;
  final void Function(String spot) onRemoveSpot;

  const _SpotChipsField({
    required this.spots,
    required this.spotController,
    required this.onAddSpot,
    required this.onRemoveSpot,
    this.spotFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Staged spot chips shown above the input row.
        if (spots.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in spots)
                InputChip(
                  label: Text(s),
                  avatar: Icon(
                    Icons.local_parking_rounded,
                    size: 16,
                    color: scheme.onTertiaryContainer,
                  ),
                  onDeleted: () => onRemoveSpot(s),
                  deleteIconColor: scheme.onTertiaryContainer,
                  backgroundColor: scheme.tertiaryContainer,
                  labelStyle: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        // Spot identifier entry row.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      (event.logicalKey == LogicalKeyboardKey.enter ||
                          event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
                    onAddSpot();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: spotController,
                  focusNode: spotFocusNode,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onAddSpot(),
                  decoration: InputDecoration(
                    labelText: 'admin.apartments.spots_label'.tr(),
                    hintText: 'admin.apartments.spots_hint'.tr(),
                    helperText: spots.isEmpty
                        ? 'admin.apartments.spots_helper'.tr()
                        : null,
                    prefixIcon: const Icon(Icons.local_parking_rounded),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'admin.apartments.add_spot_tooltip'.tr(),
              icon: const Icon(Icons.add_road_rounded),
              onPressed: onAddSpot,
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Apartment card (list view, multiple phones) ────────────────────────────

class _ApartmentCard extends StatelessWidget {
  final AuthorizedApartment apartment;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ApartmentCard({
    required this.apartment,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unit = apartment.unitNumber;
    final residents = apartment.residents;
    final spots = apartment.parkingSpotIdentifiers;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Text(
                unit.length <= 3 ? unit : unit.substring(0, 3),
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 6),
                    child: Text(
                      tr('admin.apartments.unit_display',
                          namedArgs: {'unit': unit}),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  // ── Residents row ──────────────────────────────────────────
                  if (residents.isEmpty)
                    Text(
                      'admin.apartments.phones_empty'.tr(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final r in residents)
                          Chip(
                            label: Text(r.displayLabel),
                            avatar: Icon(
                              Icons.person_outline_rounded,
                              size: 14,
                              color: scheme.onSurfaceVariant,
                            ),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: scheme.surfaceContainerHighest,
                            labelStyle: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                  // ── Parking spots row ──────────────────────────────────────
                  const SizedBox(height: 6),
                  if (spots.isEmpty)
                    Text(
                      'admin.apartments.spots_empty'.tr(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in spots)
                          Chip(
                            label: Text(s),
                            avatar: Icon(
                              Icons.local_parking_rounded,
                              size: 14,
                              color: scheme.onTertiaryContainer,
                            ),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: scheme.tertiaryContainer
                                .withValues(alpha: 0.7),
                            labelStyle: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onTertiaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'admin.apartments.edit_tooltip'.tr(),
              icon: Icon(Icons.edit_outlined, color: scheme.primary),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'admin.apartments.remove_tooltip'.tr(),
              icon: Icon(
                Icons.delete_outline_rounded,
                color: scheme.error,
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Edit apartment dialog ──────────────────────────────────────────────────
//
// Reuses [_ResidentChipsField] to keep the editing UX identical to the create
// flow. Returns the updated List<Resident> via Navigator.pop, or null if
// the admin cancelled.

class _EditApartmentDialog extends StatefulWidget {
  final AuthorizedApartment apartment;
  const _EditApartmentDialog({required this.apartment});

  @override
  State<_EditApartmentDialog> createState() => _EditApartmentDialogState();
}

class _EditApartmentDialogState extends State<_EditApartmentDialog> {
  late final List<Resident> _residents;
  late final List<String> _spots;
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  final _spotController = TextEditingController();
  final _spotFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _residents = List<Resident>.from(widget.apartment.residents);
    _spots = List<String>.from(widget.apartment.parkingSpotIdentifiers);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    _spotController.dispose();
    _spotFocusNode.dispose();
    super.dispose();
  }

  void _stageResident() {
    final rawPhone = _phoneController.text.trim();
    if (rawPhone.isEmpty) return;

    final normalised = AuthService.normalisePhone(rawPhone);
    if (!RegExp(r'^\+\d{7,15}$').hasMatch(normalised)) {
      AppSnack.error(context, 'admin.apartments.phone_invalid'.tr());
      return;
    }
    if (_residents.any((r) => r.phone == normalised)) {
      AppSnack.error(context, 'admin.apartments.phone_already_added'.tr());
      return;
    }
    final name = _nameController.text.trim();
    setState(() {
      _residents.add(Resident(name: name, phone: normalised));
      _nameController.clear();
      _phoneController.clear();
    });
    _phoneFocusNode.requestFocus();
  }

  void _removeResident(Resident r) {
    setState(() => _residents.remove(r));
  }

  void _stageSpot() {
    final raw = _spotController.text.trim();
    if (raw.isEmpty) return;
    if (_spots.contains(raw)) {
      AppSnack.error(context, 'admin.apartments.spot_already_added'.tr());
      return;
    }
    setState(() {
      _spots.add(raw);
      _spotController.clear();
    });
    _spotFocusNode.requestFocus();
  }

  void _removeSpot(String s) {
    setState(() => _spots.remove(s));
  }

  void _save() {
    // Fold in any un-staged phone entry.
    if (_phoneController.text.trim().isNotEmpty) {
      _stageResident();
      if (_phoneController.text.trim().isNotEmpty) return;
    }
    // Fold in any un-staged spot entry.
    if (_spotController.text.trim().isNotEmpty) {
      _stageSpot();
      if (_spotController.text.trim().isNotEmpty) return;
    }
    if (_residents.isEmpty) {
      AppSnack.error(context, 'admin.apartments.at_least_one_phone'.tr());
      return;
    }
    Navigator.of(context).pop((
      residents: List<Resident>.from(_residents),
      spots: List<String>.from(_spots),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('admin.apartments.edit_dialog_title')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  tr('admin.apartments.unit_display',
                      namedArgs: {'unit': widget.apartment.unitNumber}),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _ResidentChipsField(
                residents: _residents,
                nameController: _nameController,
                phoneController: _phoneController,
                phoneFocusNode: _phoneFocusNode,
                onAddResident: _stageResident,
                onRemoveResident: _removeResident,
              ),
              const SizedBox(height: 16),
              _SpotChipsField(
                spots: _spots,
                spotController: _spotController,
                spotFocusNode: _spotFocusNode,
                onAddSpot: _stageSpot,
                onRemoveSpot: _removeSpot,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('admin.dialog.cancel'.tr()),
        ),
        FilledButton(
          onPressed: _save,
          child: Text('admin.apartments.save_button'.tr()),
        ),
      ],
    );
  }
}

// ─── Spot Management Tab ─────────────────────────────────────────────────────
//
// Admin view of the operational `parking_spots` table (via the
// admin_list_building_spots RPC). Surfaces orphaned rows — spots with no
// apartment, or whose identifier has fallen out of the apartment's
// authorized_apartments snapshot — and lets the admin force-delete any spot.
// Re-importing is delegated to the existing Bulk Import tab.

class _SpotManagementTab extends StatefulWidget {
  final AdminService adminService;
  final VoidCallback onOpenBulkImport;

  const _SpotManagementTab({
    required this.adminService,
    required this.onOpenBulkImport,
  });

  @override
  State<_SpotManagementTab> createState() => _SpotManagementTabState();
}

class _SpotManagementTabState extends State<_SpotManagementTab> {
  List<AdminParkingSpot> _spots = [];
  bool _isLoading = true;
  final Set<String> _deleting = {};

  @override
  void initState() {
    super.initState();
    _loadSpots();
  }

  Future<void> _loadSpots() async {
    setState(() => _isLoading = true);
    try {
      final data = await widget.adminService.getBuildingSpots();
      if (!mounted) return;
      setState(() {
        _spots = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<bool> _confirmDelete({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('admin.dialog.cancel'.tr()),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _deleteSpot(AdminParkingSpot spot) async {
    final body = spot.hasActiveBookings
        ? tr('admin.spots.delete_dialog_body_with_bookings', namedArgs: {
            'spot': spot.spotIdentifier,
            'count': '${spot.activeBookingsCount}',
          })
        : tr('admin.spots.delete_dialog_body',
            namedArgs: {'spot': spot.spotIdentifier});

    if (!await _confirmDelete(
      title: 'admin.spots.delete_dialog_title'.tr(),
      body: body,
      confirmLabel: 'admin.spots.delete_button'.tr(),
    )) {
      return;
    }
    if (!mounted) return;

    setState(() => _deleting.add(spot.id));
    try {
      await widget.adminService.deleteBuildingSpot(spot.id);
      if (!mounted) return;
      AppSnack.success(context, 'admin.spots.deleted_success'.tr());
      await _loadSpots();
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _deleting.remove(spot.id));
    }
  }

  Future<void> _deleteAllOrphans(List<AdminParkingSpot> orphans) async {
    if (!await _confirmDelete(
      title: 'admin.spots.delete_all_orphans_confirm_title'.tr(),
      body: tr('admin.spots.delete_all_orphans_confirm_body',
          namedArgs: {'count': '${orphans.length}'}),
      confirmLabel: 'admin.spots.delete_all_orphans_button'.tr(),
    )) {
      return;
    }
    if (!mounted) return;

    setState(() => _deleting.addAll(orphans.map((s) => s.id)));
    var failures = 0;
    for (final spot in orphans) {
      try {
        await widget.adminService.deleteBuildingSpot(spot.id);
      } catch (_) {
        failures++;
      }
    }
    if (!mounted) return;
    setState(() => _deleting.clear());
    if (failures == 0) {
      AppSnack.success(
        context,
        tr('admin.spots.deleted_many_success',
            namedArgs: {'count': '${orphans.length}'}),
      );
    } else {
      AppSnack.error(
        context,
        tr('admin.spots.deleted_many_partial',
            namedArgs: {'count': '${orphans.length - failures}', 'errors': '$failures'}),
      );
    }
    await _loadSpots();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (_isLoading) return const SkeletonList(count: 5);

    if (_spots.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadSpots,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.12),
            EmptyState(
              icon: Icons.local_parking_outlined,
              title: 'admin.spots.empty_title'.tr(),
              message: 'admin.spots.empty_message'.tr(),
            ),
          ],
        ),
      );
    }

    final orphans = _spots.where((s) => s.isOrphan).toList();
    final assigned = _spots.where((s) => !s.isOrphan).toList();
    final activeCount = _spots.where((s) => s.isActive).length;

    return RefreshIndicator(
      onRefresh: _loadSpots,
      child: ListView(
        padding: const EdgeInsetsDirectional.fromSTEB(32, 28, 32, 32),
        children: [
          // ── Summary banner ─────────────────────────────────────────────
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.local_parking_rounded,
                      size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr('admin.spots.summary_banner', namedArgs: {
                        'total': '${_spots.length}',
                        'active': '$activeCount',
                        'orphaned': '${orphans.length}',
                      }),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: widget.onOpenBulkImport,
                    icon: const Icon(Icons.upload_file_rounded, size: 18),
                    label: Text('admin.spots.reimport_button'.tr()),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'admin.spots.reimport_hint'.tr(),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),

          // ── Orphaned section ───────────────────────────────────────────
          if (orphans.isNotEmpty) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr('admin.spots.orphan_section_title',
                        namedArgs: {'count': '${orphans.length}'}),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _deleting.isNotEmpty
                      ? null
                      : () => _deleteAllOrphans(orphans),
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: Text('admin.spots.delete_all_orphans_button'.tr()),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'admin.spots.orphan_section_desc'.tr(),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final spot in orphans)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SpotCard(
                  spot: spot,
                  isDeleting: _deleting.contains(spot.id),
                  onDelete: () => _deleteSpot(spot),
                ),
              ),
          ],

          // ── Assigned spots section ─────────────────────────────────────
          if (assigned.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'admin.spots.assigned_section_title'.tr(),
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 12),
            for (final spot in assigned)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SpotCard(
                  spot: spot,
                  isDeleting: _deleting.contains(spot.id),
                  onDelete: () => _deleteSpot(spot),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _SpotCard extends StatelessWidget {
  final AdminParkingSpot spot;
  final bool isDeleting;
  final VoidCallback onDelete;

  const _SpotCard({
    required this.spot,
    required this.isDeleting,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: spot.isOrphan
                    ? scheme.errorContainer.withValues(alpha: 0.5)
                    : scheme.tertiaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.local_parking_rounded,
                size: 20,
                color: spot.isOrphan
                    ? scheme.onErrorContainer
                    : scheme.onTertiaryContainer,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          spot.spotIdentifier,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (!spot.isActive)
                        StatusChip(
                          label: 'admin.spots.inactive_chip'.tr(),
                          tone: StatusTone.warning,
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    spot.apartmentIdentifier != null
                        ? tr('admin.spots.unit_line',
                            namedArgs: {'unit': spot.apartmentIdentifier!})
                        : 'admin.spots.unassigned_line'.tr(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: spot.isOrphan
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                      fontWeight:
                          spot.isOrphan ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (spot.isOrphan && spot.apartmentIdentifier != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'admin.spots.not_in_snapshot'.tr(),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    tr('admin.spots.counts_line', namedArgs: {
                      'periods': '${spot.availabilityPeriodsCount}',
                      'bookings': '${spot.activeBookingsCount}',
                    }),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isDeleting)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'admin.spots.delete_tooltip'.tr(),
                icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Bulk Import Tab ─────────────────────────────────────────────────────────

class _BulkImportTab extends StatefulWidget {
  final AdminService adminService;
  const _BulkImportTab({required this.adminService});

  @override
  State<_BulkImportTab> createState() => _BulkImportTabState();
}

class _BulkImportTabState extends State<_BulkImportTab> {
  final _jsonController = TextEditingController();
  bool _isImporting = false;

  static const _placeholder = '''[
  {
    "apartment_identifier": "101",
    "phones": ["+972501234567"],
    "parking_spots": ["A1"]
  }
]''';

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  Future<void> _runImport() async {
    final raw = _jsonController.text.trim();
    if (raw.isEmpty) {
      AppSnack.error(context, 'admin.bulk_import.paste_required'.tr());
      return;
    }

    List<Map<String, dynamic>> data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('Root must be a JSON array');
      data = decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      AppSnack.error(context,
          tr('admin.bulk_import.invalid_json', namedArgs: {'error': e.toString()}));
      return;
    }

    setState(() => _isImporting = true);
    try {
      final result = await widget.adminService.bulkImport(data);
      if (!mounted) return;

      final imported = (result['imported'] as List?)?.length ?? 0;
      final errs = result['errors'] as List?;

      if (errs != null && errs.isNotEmpty) {
        AppSnack.error(
          context,
          tr('admin.bulk_import.partial_error',
              namedArgs: {'count': '$imported', 'errors': '${errs.length}'}),
        );
      } else {
        AppSnack.success(
          context,
          tr('admin.bulk_import.success', namedArgs: {'count': '$imported'}),
        );
        _jsonController.clear();
      }
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header card ──────────────────────────────────────────────────
          Card(
            color: scheme.secondaryContainer.withValues(alpha: 0.35),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.upload_file_rounded,
                            color: scheme.secondary, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'admin.bulk_import.title'.tr(),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'admin.bulk_import.description'.tr(),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── JSON input ───────────────────────────────────────────────────
          Text('admin.bulk_import.json_label'.tr(), style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          TextField(
            controller: _jsonController,
            maxLines: 14,
            decoration: InputDecoration(
              hintText: _placeholder,
              hintStyle: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                fontFamily: 'monospace',
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              alignLabelWithHint: true,
            ),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            keyboardType: TextInputType.multiline,
          ),
          const SizedBox(height: 16),

          // ── Import button ────────────────────────────────────────────────
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _isImporting ? null : _runImport,
              icon: _isImporting
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onPrimary,
                      ),
                    )
                  : const Icon(Icons.cloud_upload_rounded),
              label: Text(_isImporting
                  ? 'admin.bulk_import.importing'.tr()
                  : 'admin.bulk_import.run_button'.tr()),
            ),
          ),
          const SizedBox(height: 28),

          // ── Format reference ─────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text('admin.bulk_import.format_title'.tr(), style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            padding: const EdgeInsets.all(16),
            child: Text(
              _placeholder,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ─── Building Settings Tab ────────────────────────────────────────────────────

class _BuildingSettingsTab extends StatefulWidget {
  final AdminService adminService;
  const _BuildingSettingsTab({required this.adminService});

  @override
  State<_BuildingSettingsTab> createState() => _BuildingSettingsTabState();
}

class _BuildingSettingsTabState extends State<_BuildingSettingsTab> {
  Building? _building;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBuilding();
  }

  Future<void> _loadBuilding() async {
    setState(() => _isLoading = true);
    try {
      final building = await widget.adminService.getAdminBuilding();
      if (!mounted) return;
      setState(() {
        _building = building;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _openEditDialog() async {
    if (_building == null) return;

    final updated = await showDialog<Building>(
      context: context,
      builder: (context) =>
          _EditBuildingDialog(building: _building!),
    );

    if (updated != null && mounted) {
      setState(() => _building = updated);
      AppSnack.success(context, 'admin.settings.saved_success'.tr());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (_isLoading) {
      return const SkeletonList(count: 4);
    }

    if (_building == null) {
      return EmptyState(
        icon: Icons.apartment_rounded,
        title: 'admin.settings.not_found_title'.tr(),
        message: 'admin.settings.not_found_message'.tr(),
        action: TextButton.icon(
          onPressed: _loadBuilding,
          icon: const Icon(Icons.refresh_rounded),
          label: Text('admin.settings.retry'.tr()),
        ),
      );
    }

    final b = _building!;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header card ──────────────────────────────────────────────────
          Card(
            color: scheme.primaryContainer.withValues(alpha: 0.25),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.apartment_rounded,
                        color: scheme.primary, size: 26),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.name,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (b.address != null && b.address!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            b.address!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _openEditDialog,
                    icon: const Icon(Icons.edit_rounded, size: 18),
                    label: Text('admin.settings.edit_button'.tr()),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Details grid ─────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('admin.settings.details_section'.tr(),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0.4,
                      )),
                  const SizedBox(height: 16),
                  _DetailRow(
                    icon: Icons.vpn_key_outlined,
                    label: 'admin.settings.invite_code'.tr(),
                    value: b.inviteCode,
                    monospace: true,
                  ),
                  const Divider(height: 24),
                  _DetailRow(
                    icon: Icons.local_parking_rounded,
                    label: 'admin.settings.total_spots'.tr(),
                    value: b.totalParkingSpots != null
                        ? '${b.totalParkingSpots}'
                        : 'admin.settings.spots_not_set'.tr(),
                  ),
                  const Divider(height: 24),
                  _DetailRow(
                    icon: Icons.approval_rounded,
                    label: 'admin.settings.approval_required'.tr(),
                    value: b.approvalRequired
                        ? 'admin.settings.yes'.tr()
                        : 'admin.settings.no'.tr(),
                  ),
                  if (b.latitude != null && b.longitude != null) ...[
                    const Divider(height: 24),
                    _DetailRow(
                      icon: Icons.location_on_outlined,
                      label: 'admin.settings.coordinates'.tr(),
                      value:
                          '${b.latitude!.toStringAsFixed(5)}, ${b.longitude!.toStringAsFixed(5)}',
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Create New Building ───────────────────────────────────────────
          Card(
            color: scheme.errorContainer.withValues(alpha: 0.12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _confirmCreateNewBuilding(context),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.add_business_rounded,
                        color: scheme.onErrorContainer,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'admin.settings.create_new_building'.tr(),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onErrorContainer,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'admin.settings.create_new_building_subtitle'.tr(),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onErrorContainer
                                  .withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 16,
                      color: scheme.onErrorContainer.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCreateNewBuilding(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('admin.settings.create_new_building_confirm_title'.tr()),
        content: Text('admin.settings.create_new_building_confirm_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('admin.settings.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('admin.settings.create_new_building_confirm'.tr()),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      context.go('/setup');
    }
  }
}

// ─── Edit Building Dialog ─────────────────────────────────────────────────────

class _EditBuildingDialog extends StatefulWidget {
  final Building building;
  const _EditBuildingDialog({required this.building});

  @override
  State<_EditBuildingDialog> createState() => _EditBuildingDialogState();
}

class _EditBuildingDialogState extends State<_EditBuildingDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _spotsController;

  String _address = '';
  double? _latitude;
  double? _longitude;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final b = widget.building;
    _nameController = TextEditingController(text: b.name);
    _spotsController = TextEditingController(
        text: b.totalParkingSpots != null ? '${b.totalParkingSpots}' : '');
    _address = b.address ?? '';
    _latitude = b.latitude;
    _longitude = b.longitude;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _spotsController.dispose();
    super.dispose();
  }

  void _onAddressSelected(AddressResult result) {
    setState(() {
      _address = result.address;
      _latitude = result.latitude;
      _longitude = result.longitude;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);
    try {
      final spotsText = _spotsController.text.trim();
      final totalSpots =
          spotsText.isNotEmpty ? int.tryParse(spotsText) : null;

      final updated = await BuildingService().updateBuilding(
        buildingId: widget.building.id,
        name: _nameController.text.trim(),
        address: _address.isNotEmpty ? _address : null,
        latitude: _latitude,
        longitude: _longitude,
        totalParkingSpots: totalSpots,
      );

      if (!mounted) return;
      Navigator.of(context).pop(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      AppSnack.error(
          context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text('admin.settings.edit_dialog_title'.tr()),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Building name
                TextFormField(
                  controller: _nameController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'admin.settings.building_name_label'.tr(),
                    prefixIcon: const Icon(Icons.business_rounded),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'admin.settings.building_name_required'.tr()
                      : null,
                ),
                const SizedBox(height: 16),

                // Address autocomplete
                AddressAutocompleteField(
                  labelText: 'setup.building_address_label'.tr(),
                  hintText: 'setup.building_address_hint'.tr(),
                  initialValue: _address.isEmpty ? null : _address,
                  onAddressSelected: _onAddressSelected,
                  onChanged: (value) {
                    if (value != _address) {
                      setState(() {
                        _address = value;
                        _latitude = null;
                        _longitude = null;
                      });
                    }
                  },
                ),
                if (_latitude != null && _longitude != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.check_circle_outline_rounded,
                          size: 14,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        tr('setup.location_confirmed', namedArgs: {
                          'lat': _latitude!.toStringAsFixed(4),
                          'lng': _longitude!.toStringAsFixed(4),
                        }),
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),

                // Total parking spots
                TextFormField(
                  controller: _spotsController,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'admin.settings.spots_label'.tr(),
                    prefixIcon: const Icon(Icons.local_parking_rounded),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final n = int.tryParse(v.trim());
                    if (n == null || n < 1) {
                      return 'admin.settings.spots_invalid'.tr();
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: Text('admin.settings.cancel'.tr()),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('admin.settings.save'.tr()),
        ),
      ],
    );
  }
}

// ─── Announcements Tab (Roadmap Phase 4) ─────────────────────────────────────
//
// Compose card (title + body, validated, confirm-before-send) over a live
// history list — the same `building_announcements` rows residents see, so the
// admin previews exactly what landed. Sending calls the
// `create_building_announcement` RPC via AnnouncementService; the outbox +
// notify-building-announcement handle the push fan-out.

class _AnnouncementsTab extends StatefulWidget {
  const _AnnouncementsTab();

  @override
  State<_AnnouncementsTab> createState() => _AnnouncementsTabState();
}

class _AnnouncementsTabState extends State<_AnnouncementsTab> {
  static const int _maxTitle = 120;
  static const int _maxBody = 2000;

  final _service = AnnouncementService();
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();

  List<BuildingAnnouncement> _announcements = [];
  bool _isLoading = true;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final data = await _service.getBuildingAnnouncements();
      if (!mounted) return;
      setState(() {
        _announcements = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('admin.announcements.send_confirm_title'.tr()),
        content: Text('admin.announcements.send_confirm_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('admin.dialog.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('admin.announcements.send_button'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isSending = true);
    try {
      await _service.sendAnnouncement(
        title: _titleController.text.trim(),
        body: _bodyController.text.trim(),
      );
      if (!mounted) return;
      AppSnack.success(context, 'admin.announcements.sent_success'.tr());
      _titleController.clear();
      _bodyController.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dateFmt = DateFormat('MMM d, y • h:mm a');

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsetsDirectional.fromSTEB(32, 28, 32, 32),
        children: [
          // ── Compose card ───────────────────────────────────────────────
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.campaign_rounded,
                            size: 20, color: scheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          'admin.announcements.compose_title'.tr(),
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _titleController,
                      maxLength: _maxTitle,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'admin.announcements.title_label'.tr(),
                        hintText: 'admin.announcements.title_hint'.tr(),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'admin.announcements.title_required'.tr()
                          : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _bodyController,
                      maxLength: _maxBody,
                      maxLines: 5,
                      minLines: 3,
                      decoration: InputDecoration(
                        labelText: 'admin.announcements.body_label'.tr(),
                        hintText: 'admin.announcements.body_hint'.tr(),
                        alignLabelWithHint: true,
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'admin.announcements.body_required'.tr()
                          : null,
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FilledButton.icon(
                        onPressed: _isSending ? null : _send,
                        icon: _isSending
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimary,
                                ),
                              )
                            : const Icon(Icons.send_rounded, size: 18),
                        label: Text(_isSending
                            ? 'admin.announcements.sending'.tr()
                            : 'admin.announcements.send_button'.tr()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── History ────────────────────────────────────────────────────
          Text(
            'admin.announcements.history_section'.tr(),
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 12),
          if (_isLoading)
            const SkeletonList(count: 3)
          else if (_announcements.isEmpty)
            EmptyState(
              icon: Icons.campaign_outlined,
              title: 'admin.announcements.empty_title'.tr(),
              message: 'admin.announcements.empty_message'.tr(),
            )
          else
            for (final a in _announcements)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.title,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(a.body, style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 8),
                        Text(
                          dateFmt.format(a.createdAt.toLocal()),
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

// ─── Detail row helper ────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool monospace;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: (monospace
                        ? theme.textTheme.bodyMedium
                            ?.copyWith(fontFamily: 'monospace')
                        : theme.textTheme.bodyMedium)
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Avatar helper ────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String? name;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = (name != null && name!.trim().isNotEmpty)
        ? name!.trim()[0].toUpperCase()
        : '?';
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        shape: BoxShape.circle,
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w800,
          fontSize: 16,
        ),
      ),
    );
  }
}
