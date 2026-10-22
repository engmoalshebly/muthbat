import '../../../../app/theme/app_typography.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../core/config/supabase_config.dart';
import '../../../local_ledger/local_ledger_store.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../widgets/splash_background.dart';
import '../widgets/splash_logo_badge.dart';
import '../../../auth/presentation/customer_entry_mode.dart';
import '../../../auth/presentation/workspace_preference.dart';

/// الشاشة الافتتاحية الفاخرة لمنصة «مُثبَت | MUTHBAT»
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _hasNavigated = false;

  Future<String?> _preferredRoute() async {
    final auth = ref.read(authControllerProvider);
    final preference = await WorkspacePreference.read(auth.userId);
    if (!mounted ||
        ref.read(authControllerProvider).userId != auth.userId ||
        preference == null) {
      return null;
    }
    if (preference['kind'] == 'local') {
      final id = preference['notebook_id'];
      if (id is String) {
        try {
          await LocalLedgerStore.instance.selectNotebook(id);
        } catch (_) {
          return null;
        }
      }
      return AppRoutes.localLedger;
    }
    if (!auth.hasLocalAccess) return null;
    if (preference['kind'] == 'customer') return AppRoutes.customerHome;
    if (preference['kind'] == 'merchant' &&
        auth.businessAccessChecked &&
        auth.activeBusinessId != null &&
        auth.businessRole != null) {
      return AppRoutes.merchantHome;
    }
    return null;
  }

  void _openCurrentAccount() async {
    if (!mounted || _hasNavigated) return;
    final preferred = await _preferredRoute();
    if (!mounted || _hasNavigated) return;
    if (preferred != null) {
      _hasNavigated = true;
      Navigator.pushReplacementNamed(context, preferred);
      return;
    }
    _hasNavigated = true;
    final account = ref.read(authControllerProvider);
    final customerMode =
        account.userId != null &&
        await CustomerEntryMode.selected(account.userId!);
    if (!mounted) return;
    final route = !account.hasLocalAccess
        ? AppRoutes.localLedger
        : account.userType == 'merchant' && account.requiresBusinessSetup
        ? AppRoutes.businessSetup
        : account.userType == 'customer' ||
              (customerMode &&
                  (account.businessRole == null ||
                      account.businessRole == 'owner'))
        ? AppRoutes.customerHome
        : AppRoutes.merchantHome;
    Navigator.pushReplacementNamed(context, route);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handleBootstrap();
    });
  }

  Future<void> _handleBootstrap() async {
    try {
      await _bootstrap().timeout(const Duration(seconds: 10));
    } on TimeoutException {
      if (!mounted || _hasNavigated) return;
      ref.read(authControllerProvider.notifier).reset();
      _openCurrentAccount();
    }
  }

  Future<void> _bootstrap() async {
    try {
      if (SupabaseConfig.cloudReady) {
        await ref.read(authControllerProvider.notifier).localReady;
        if (!mounted || _hasNavigated) return;
        if (ref.read(authControllerProvider).hasLocalAccess) {
          _openCurrentAccount();
          return;
        }
      }
    } catch (_) {
      /* Continue to first-use flow if no readable owner store. */
    }
    try {
      final notebook = await LocalLedgerStore.instance.current();
      if (!mounted || _hasNavigated) return;
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _hasNavigated) return;
      if (notebook == null &&
          !(prefs.getBool(WelcomeScreen.completedKey) ?? false)) {
        _hasNavigated = true;
        Navigator.pushReplacementNamed(context, AppRoutes.welcome);
        return;
      }
      if (!SupabaseConfig.cloudReady ||
          (notebook != null && notebook['transfer_state'] != 'complete')) {
        _hasNavigated = true;
        Navigator.pushReplacementNamed(context, AppRoutes.localLedger);
        return;
      }
    } catch (_) {
      if (!mounted || _hasNavigated) return;
      _hasNavigated = true;
      Navigator.pushReplacementNamed(context, AppRoutes.localLedger);
      return;
    }
    final controller = ref.read(authControllerProvider.notifier);
    await Future.wait<void>([
      controller.ready,
      // Keep the branded splash visible briefly without making auth timing
      // dependent on an arbitrary delay.
      Future<void>.delayed(const Duration(milliseconds: 700)),
    ]);
    if (!mounted || _hasNavigated) return;

    final authState = ref.read(authControllerProvider);
    final preferred = await _preferredRoute();
    if (!mounted || _hasNavigated) return;
    if (preferred != null) {
      _hasNavigated = true;
      Navigator.pushReplacementNamed(context, preferred);
      return;
    }
    final customerMode =
        authState.userId != null &&
        await CustomerEntryMode.selected(authState.userId!);
    if (!mounted || _hasNavigated) return;
    _hasNavigated = true;
    if (authState.hasLocalAccess) {
      if (authState.userType == 'merchant' && authState.requiresBusinessSetup) {
        Navigator.pushReplacementNamed(context, AppRoutes.businessSetup);
      } else if (authState.userType == 'customer' ||
          (customerMode &&
              (authState.businessRole == null ||
                  authState.businessRole == 'owner'))) {
        Navigator.pushReplacementNamed(context, AppRoutes.customerHome);
      } else {
        Navigator.pushReplacementNamed(context, AppRoutes.merchantHome);
      }
    } else {
      Navigator.pushReplacementNamed(context, AppRoutes.localLedger);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SplashBackground(
        child: SafeArea(
          child: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 40),

                // --- المركز: الأيقونة واسم العلامة والشعار التسويقي ---
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 1. الشارة الهندسية العائمة مع الوهج
                    const SplashLogoBadge(size: 116)
                        .animate()
                        .fadeIn(duration: 800.ms, curve: Curves.easeOutCubic)
                        .scale(
                          begin: const Offset(0.75, 0.75),
                          end: const Offset(1.0, 1.0),
                          duration: 900.ms,
                          curve: Curves.easeOutBack,
                        )
                        .shimmer(
                          delay: 1100.ms,
                          duration: 1400.ms,
                          color: AppColors.white.withValues(alpha: 0.25),
                        ),

                    const SizedBox(height: 28),

                    // 2. الاسم العربي الرئيسي «مُثبَت»
                    Text(
                          AppConstants.appNameArabic,
                          style: TextStyle(
                            fontFamily: AppTypography.fontFamily,
                            fontSize: 46,
                            fontWeight: FontWeight.w900,
                            color: AppColors.white,
                            letterSpacing: -0.5,
                            height: 1.1,
                          ),
                        )
                        .animate()
                        .fadeIn(delay: 400.ms, duration: 700.ms)
                        .slideY(
                          begin: 0.25,
                          end: 0,
                          delay: 400.ms,
                          duration: 700.ms,
                          curve: Curves.easeOutQuart,
                        ),

                    const SizedBox(height: 6),

                    // 3. الاسم الإنجليزي الثانوي «MUTHBAT» مع تباعد الأحرف الهندسي
                    Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 14,
                              height: 1.5,
                              color: AppColors.secondaryLight.withValues(
                                alpha: 0.6,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              AppConstants.appNameEnglish,
                              style: TextStyle(
                                fontFamily: AppTypography.fontFamily,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 6.0,
                                color: AppColors.secondaryLight,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Container(
                              width: 14,
                              height: 1.5,
                              color: AppColors.secondaryLight.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ],
                        )
                        .animate()
                        .fadeIn(delay: 650.ms, duration: 700.ms)
                        .slideY(
                          begin: 0.3,
                          end: 0,
                          delay: 650.ms,
                          duration: 700.ms,
                        ),

                    const SizedBox(height: 16),

                    // 4. الشعار التسويقي «كل حق.. مُثبَت.» مع النقطة الذهبية
                    Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: AppColors.white.withValues(alpha: 0.1),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: AppColors.accentGold,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                AppConstants.appTagline,
                                style: TextStyle(
                                  fontFamily: AppTypography.fontFamily,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textWhiteSecondary,
                                ),
                              ),
                            ],
                          ),
                        )
                        .animate()
                        .fadeIn(delay: 900.ms, duration: 800.ms)
                        .slideY(
                          begin: 0.35,
                          end: 0,
                          delay: 900.ms,
                          duration: 800.ms,
                        ),
                  ],
                ),

                // --- الأسفل: مؤشر التحميل وشارة الأمان والتوثيق ---
                Padding(
                  padding: const EdgeInsets.only(bottom: 24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // شريط نبض التحميل البصري الرفيع
                      SizedBox(
                        width: 120,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 2.5,
                            backgroundColor: AppColors.white.withValues(
                              alpha: 0.1,
                            ),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.accentGold,
                            ),
                          ),
                        ),
                      ).animate().fadeIn(delay: 1100.ms, duration: 600.ms),

                      const SizedBox(height: 18),

                      // شارة الأمان والتوثيق المالي
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            size: 14,
                            color: AppColors.textWhiteSecondary.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            AppConstants.securityBadgeText,
                            style: TextStyle(
                              fontFamily: AppTypography.fontFamily,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textWhiteSecondary.withValues(
                                alpha: 0.7,
                              ),
                            ),
                          ),
                        ],
                      ).animate().fadeIn(delay: 1300.ms, duration: 700.ms),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
