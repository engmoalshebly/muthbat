import 'package:flutter/foundation.dart';

/// بيئات تشغيل التطبيق المدعومة.
///
/// تُحقن البيئة وقت البناء عبر:
///   flutter build/run --dart-define=APP_ENV=dev|staging|prod
///
/// - dev:     مشروع Supabase محلي عبر `supabase start` (CLI).
/// - staging: مشروع سحابي مستقل muthbat-staging (أسراره من CI).
/// - prod:    مشروع سحابي muthbat-prod (أسراره من CI، بلا أي قيم افتراضية).
enum AppEnv { dev, staging, prod }

/// إعداد البيئة الحالي، مقروء مرة واحدة وقت البناء.
class EnvConfig {
  EnvConfig._();

  static const String _rawEnv = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'dev',
  );
  static const bool _allowLocalRelease = bool.fromEnvironment(
    'ALLOW_LOCAL_RELEASE',
    defaultValue: false,
  );

  /// البيئة الفعلية المحسوبة من APP_ENV.
  static AppEnv get env {
    switch (_rawEnv) {
      case 'staging':
        return AppEnv.staging;
      case 'prod':
        return AppEnv.prod;
      default:
        return AppEnv.dev;
    }
  }

  static bool get isDev => env == AppEnv.dev;
  static bool get isStaging => env == AppEnv.staging;
  static bool get isProd => env == AppEnv.prod;

  /// يمنع شحن بناء إنتاجي موسوم بيئة تطوير.
  /// يُستدعى من [SupabaseConfig.init] قبل أي اتصال شبكي.
  static void validate() {
    if (kReleaseMode && env == AppEnv.dev && !_allowLocalRelease) {
      throw StateError(
        '[EnvConfig] بناء Release موسوم APP_ENV=dev. '
        'مرّر APP_ENV=staging أو prod، أو ALLOW_LOCAL_RELEASE=true '
        'لبناء اختبار LAN مقصود.',
      );
    }
  }
}
