import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../widgets/splash_background.dart';
import '../widgets/splash_logo_badge.dart';

/// الشاشة الافتتاحية الفاخرة لمنصة «مُثبَت | MUTHBAT»
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();
    _handleBootstrap();
  }

  Future<void> _handleBootstrap() async {
    final controller = ref.read(authControllerProvider.notifier);
    await Future.wait<void>([
      controller.ready.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          // Never leave the user behind the splash when auth/network is stuck.
          controller.reset();
        },
      ),
      // Keep the branded splash visible briefly without making auth timing
      // dependent on an arbitrary delay.
      Future<void>.delayed(const Duration(milliseconds: 700)),
    ]);
    if (!mounted) return;
    if (_hasNavigated) return;
    _hasNavigated = true;

    final authState = ref.read(authControllerProvider);
    if (authState.status == AuthStatus.authenticated) {
      if (authState.userType == 'customer') {
        Navigator.pushReplacementNamed(context, AppRoutes.customerHome);
      } else if (authState.requiresBusinessSetup) {
        Navigator.pushReplacementNamed(context, AppRoutes.businessSetup);
      } else {
        Navigator.pushReplacementNamed(context, AppRoutes.merchantHome);
      }
    } else {
      Navigator.pushReplacementNamed(context, AppRoutes.login);
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
                          color: Colors.white.withValues(alpha: 0.25),
                        ),

                    const SizedBox(height: 28),

                    // 2. الاسم العربي الرئيسي «مُثبَت»
                    Text(
                          AppConstants.appNameArabic,
                          style: GoogleFonts.tajawal(
                            fontSize: 46,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
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
                              style: GoogleFonts.manrope(
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
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.1),
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
                                style: GoogleFonts.tajawal(
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
                            backgroundColor: Colors.white.withValues(
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
                            style: GoogleFonts.tajawal(
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
