import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/dev_auth_config.dart';
import '../screens/admin/admin_dashboard_screen.dart';
import '../screens/admin/admin_booking_issues_screen.dart';
import '../screens/announcements/announcements_screen.dart';
import '../screens/auth/admin_login_screen.dart';
import '../screens/auth/auth_wrapper.dart';
import '../screens/auth/create_building_screen.dart';
import '../screens/auth/dev_auth_screen.dart';
import '../screens/auth/join_request_pending_screen.dart';
import '../screens/auth/join_request_screen.dart';
import '../screens/auth/not_registered_screen.dart';
import '../screens/auth/phone_auth_screen.dart';
import '../screens/building/pending_approval_screen.dart';
import '../screens/building/rejected_screen.dart';
import '../screens/spots/parking_spots_screen.dart';
import '../services/auth_service.dart';
import '../services/navigation_service.dart';

/// Route guard for admin-only screens. Uses the cached profile when available
/// (populated by [AuthService.getCurrentProfile] during the normal sign-in
/// flow) and falls back to a fetch for cold deep links straight to a guarded
/// route. Non-admins are bounced to `/home`; signed-out users to `/auth`.
Future<String?> _requireAdmin(BuildContext context, GoRouterState state) async {
  if (Supabase.instance.client.auth.currentSession == null) return '/auth';

  var profile = AuthService.cachedProfile;
  profile ??= await AuthService().getCurrentProfile();

  if (profile == null || !profile.isAdmin) return '/home';
  return null;
}

final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const AuthWrapper(),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) => DevAuthConfig.isEnabled
            ? const DevAuthScreen()
            : const PhoneAuthScreen(),
      ),
      GoRoute(
        path: '/admin-login',
        builder: (context, state) => const AdminLoginScreen(),
      ),
      GoRoute(
        path: '/not-registered',
        builder: (context, state) => const NotRegisteredScreen(),
      ),
      GoRoute(
        path: '/join-request',
        builder: (context, state) => const JoinRequestScreen(),
      ),
      GoRoute(
        path: '/join-request-pending',
        builder: (context, state) => const JoinRequestPendingScreen(),
      ),
      GoRoute(
        path: '/pending-approval',
        builder: (context, state) => const PendingApprovalScreen(),
      ),
      GoRoute(
        path: '/rejected',
        builder: (context, state) => const RejectedScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const ParkingSpotsScreen(),
      ),
      GoRoute(
        path: '/announcements',
        builder: (context, state) => const AnnouncementsScreen(),
      ),
      GoRoute(
        path: '/admin-dashboard',
        redirect: _requireAdmin,
        builder: (context, state) => const AdminDashboardScreen(),
      ),
      GoRoute(
        path: '/admin-issues',
        redirect: _requireAdmin,
        builder: (context, state) => const AdminBookingIssuesScreen(),
      ),
      GoRoute(
        path: '/setup',
        builder: (context, state) => CreateBuildingScreen(
          onCreated: () => context.go('/admin-dashboard'),
        ),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text(state.error?.toString() ?? 'Route not found'),
      ),
    ),
  );
});
