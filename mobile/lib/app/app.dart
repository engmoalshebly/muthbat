import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants/app_constants.dart';
import 'router/app_routes.dart';
import 'theme/app_theme.dart';

/// التطبيق الجذري لمنظومة «مُثبَت | MUTHBAT»
class MuthbatApp extends ConsumerWidget {
  const MuthbatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: '${AppConstants.appNameArabic} | ${AppConstants.appNameEnglish}',
      debugShowCheckedModeBanner: false,

      // إعدادات اللغة الافتراضية والاتجاه العربي من اليمين لليسار (RTL First)
      locale: const Locale('ar', 'SA'),
      supportedLocales: const [
        Locale('ar', 'SA'),
        Locale('en', 'US'),
      ],
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
    );
  }
}
