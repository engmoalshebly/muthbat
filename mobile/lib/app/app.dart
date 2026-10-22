import 'package:flutter/material.dart';
import '../core/sync/account_sync_host.dart';
import '../features/notifications/push_open_handler.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/constants/app_constants.dart';
import '../features/app_lock/app_lock_overlay.dart';
import 'router/app_routes.dart';
import 'theme/app_theme.dart';
import 'router/session_navigation_frame.dart';
import '../core/config/supabase_config.dart';
import '../features/auth/presentation/controllers/auth_controller.dart';

/// التطبيق الجذري لمنظومة «مُثبَت | MUTHBAT»
class MuthbatApp extends ConsumerWidget {
  const MuthbatApp({super.key});

  static final _navigatorKey = GlobalKey<NavigatorState>();
  static final _notificationObserver = NotificationRouteObserver();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [_notificationObserver],
      title: '${AppConstants.appNameArabic} | ${AppConstants.appNameEnglish}',
      debugShowCheckedModeBanner: false,

      // إعدادات اللغة الافتراضية والاتجاه العربي من اليمين لليسار (RTL First)
      locale: const Locale('ar', 'SA'),
      supportedLocales: const [Locale('ar', 'SA'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // الثيمات
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.light,

      // التوجيه
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.onGenerateRoute,

      // قفل التطبيق يعلو كل الشاشات، لا يحتاج مساراً خاصاً به.
      builder: (context, child) => AccountSyncHost(
        child: PushOpenHandler(
          navigatorKey: _navigatorKey,
          observer: _notificationObserver,
          child: AppLockOverlay(
            child: Consumer(
              builder: (context, ref, _) {
                final localOnly =
                    SupabaseConfig.cloudReady &&
                    ref.watch(authControllerProvider).status ==
                        AuthStatus.localOnly;
                final recoverableSession =
                    SupabaseConfig.cloudReady &&
                    Supabase.instance.client.auth.currentSession != null;
                return SessionNavigationFrame(
                  showBanner: localOnly && !recoverableSession,
                  banner: Material(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                recoverableSession
                                    ? 'بياناتك محفوظة على الجهاز • ستُزامن تلقائيًا عند الاتصال'
                                    : 'بياناتك محفوظة محليًا • سجّل الدخول لتفعيل المزامنة',
                              ),
                            ),
                            if (!recoverableSession)
                              TextButton(
                                onPressed: () => _navigatorKey.currentState
                                    ?.pushNamed(AppRoutes.login),
                                child: const Text('تسجيل الدخول'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: child ?? const SizedBox.shrink(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
