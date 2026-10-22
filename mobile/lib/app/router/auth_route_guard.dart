import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import '../../core/config/supabase_config.dart';
import '../../features/auth/presentation/controllers/auth_controller.dart';
import '../../features/merchant/data/models/business_customer_model.dart';
import '../../features/merchant/data/models/dispute_model.dart';
import 'app_routes.dart';

/// Reactive UI gate. It supplements repository checks and server RLS.
class AuthRouteGuard extends ConsumerStatefulWidget {
  const AuthRouteGuard({
    super.key,
    required this.settings,
    required this.builder,
  });
  final RouteSettings settings;
  final WidgetBuilder builder;

  @override
  ConsumerState<AuthRouteGuard> createState() => _AuthRouteGuardState();
}

class _AuthRouteGuardState extends ConsumerState<AuthRouteGuard> {
  String? _account;
  String? _business;
  bool _redirecting = false;
  bool _invalidated = false;
  String? _role;

  static const publicRoutes = {
    AppRoutes.splash,
    AppRoutes.welcome,
    AppRoutes.localLedger,
    AppRoutes.workspaces,
    AppRoutes.login,
    AppRoutes.register,
    AppRoutes.appLockSettings,
  };
  static const businessRoutes = {
    AppRoutes.merchantHome,
    AppRoutes.customerLedger,
    AppRoutes.disputesList,
    AppRoutes.disputeDetail,
    AppRoutes.statementPreview,
    AppRoutes.merchantProfile,
    AppRoutes.currencySettings,
    AppRoutes.businessProfileEdit,
    AppRoutes.rejectedOperations,
  };
  static const ownerRoutes = {
    AppRoutes.currencySettings,
    AppRoutes.businessProfileEdit,
    AppRoutes.rejectedOperations,
  };
  static const accountRoutes = {
    AppRoutes.notifications,
    AppRoutes.customerHome,
    AppRoutes.daraiChat,
    AppRoutes.businessSetup,
    '/account-screen',
  };

  Widget _blocked(String message, {bool login = false, bool setup = false}) =>
      Scaffold(
        appBar: AppBar(title: const Text('الوصول للحساب')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.pushNamedAndRemoveUntil(
                    context,
                    login
                        ? AppRoutes.login
                        : setup
                        ? AppRoutes.businessSetup
                        : AppRoutes.localLedger,
                    (_) => false,
                  ),
                  child: Text(
                    login
                        ? 'تسجيل الدخول'
                        : setup
                        ? 'إكمال النشاط'
                        : 'دفتر الجهاز',
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final route = widget.settings.name;
    if (publicRoutes.contains(route)) return widget.builder(context);
    if (!accountRoutes.contains(route) &&
        !businessRoutes.contains(route) &&
        !{
          AppRoutes.recovery,
          AppRoutes.otp,
          AppRoutes.resetPassword,
        }.contains(route)) {
      return _blocked('المسار المطلوب غير متاح.');
    }
    if (!SupabaseConfig.cloudReady) {
      return _blocked('الحساب السحابي غير متاح. يمكنك فتح دفتر الجهاز.');
    }
    final auth = ref.watch(authControllerProvider);
    if (route == AppRoutes.recovery ||
        route == AppRoutes.otp ||
        route == AppRoutes.resetPassword) {
      if (!EnvConfig.phoneVerificationEnabled) {
        return _blocked(
          'التحقق واسترداد الحساب غير متاحين حاليًا.',
          login: true,
        );
      }
      if ((route == AppRoutes.otp &&
              (auth.status != AuthStatus.otpSent ||
                  auth.challengeId == null ||
                  auth.pendingAction == null)) ||
          (route == AppRoutes.resetPassword &&
              (auth.pendingAction != AuthPendingAction.recovery ||
                  auth.recoveryOtpCode == null ||
                  auth.recoveryOtpCode!.isEmpty))) {
        return _blocked('ابدأ طلب التحقق أولًا.', login: true);
      }
      return widget.builder(context);
    }
    if (auth.status == AuthStatus.initial ||
        auth.status == AuthStatus.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!auth.hasLocalAccess || auth.userId == null) {
      if (_account != null) _invalidated = true;
      return _blocked('سجّل الدخول لفتح حسابك.', login: true);
    }
    if (_invalidated) {
      return _blocked(
        'انتهى الوصول إلى هذه الشاشة. افتحها من حسابك مجددًا.',
        login: true,
      );
    }
    _account ??= auth.userId;
    if (_account != auth.userId) {
      _invalidated = true;
      return _blocked('تغير الحساب. افتح الشاشة من حسابك الحالي.', login: true);
    }
    if (route == AppRoutes.businessSetup) {
      if (auth.activeBusinessId != null && !auth.requiresBusinessSetup) {
        if (!_redirecting) {
          _redirecting = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.pushReplacementNamed(context, AppRoutes.merchantHome);
            }
          });
        }
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (auth.status != AuthStatus.authenticated) {
        return _blocked('سجّل الدخول لإكمال إعداد النشاط.', login: true);
      }
      if (!auth.businessAccessChecked ||
          auth.userType != 'merchant' ||
          !auth.requiresBusinessSetup ||
          auth.activeBusinessId != null) {
        return _blocked('إعداد نشاط جديد غير متاح من هذا المسار.');
      }
    }
    if (businessRoutes.contains(route)) {
      if (auth.requiresBusinessSetup) {
        return _blocked('أكمل إعداد نشاطك أولًا.', setup: true);
      }
      if (!auth.businessAccessChecked ||
          auth.activeBusinessId == null ||
          auth.businessRole == null) {
        if (_business != null) _invalidated = true;
        return _blocked(
          'تعذر تأكيد عضوية نشاط نشط. أعد الدخول لتحديث الوصول.',
          login: true,
        );
      }
      _business ??= auth.activeBusinessId;
      if (_business != auth.activeBusinessId) {
        _invalidated = true;
        return _blocked('تغير النشاط. أعد فتح الشاشة.');
      }
      if (auth.businessRole != 'owner' &&
          auth.status != AuthStatus.authenticated) {
        return _blocked('يلزم الدخول للتحقق من عضوية النشاط.', login: true);
      }
      _role ??= auth.businessRole;
      if (_role != auth.businessRole) {
        _invalidated = true;
        return _blocked(
          'تغير دورك في النشاط. أعد فتح الشاشة لتحديث الصلاحيات.',
        );
      }
      if (ownerRoutes.contains(route) && auth.businessRole != 'owner') {
        return _blocked('هذه الشاشة متاحة لمالك النشاط فقط.');
      }
      if (ownerRoutes.contains(route) &&
          auth.status != AuthStatus.authenticated) {
        return _blocked('سجّل الدخول لإدارة النشاط.', login: true);
      }
      final args = widget.settings.arguments;
      final customer = args is BusinessCustomerModel
          ? args
          : args is Map
          ? args['customer']
          : null;
      if ((customer is BusinessCustomerModel &&
              customer.businessId != _business) ||
          (args is DisputeModel && args.businessId != _business)) {
        return _blocked('هذه البيانات لا تخص النشاط المفتوح.');
      }
    }
    return widget.builder(context);
  }
}
