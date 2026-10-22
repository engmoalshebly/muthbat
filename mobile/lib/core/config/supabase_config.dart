import 'env.dart';

/// إعدادات الاتصال بمنظومة Supabase، مع إمكانية تجاوزها وقت البناء.
/// قيم المشروع الافتراضية في dev عامة؛ لا تتضمن مفاتيح إدارية.
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │ الأسرار الإدارية لا توضع في العميل؛ قيم العميل العامة يمكن نشرها. │
/// │                                                                   │
/// │ العميل (موبايل) — عبر --dart-define من CI secrets:                │
/// │   SUPABASE_URL        عنوان مشروع Supabase للبيئة                 │
/// │   SUPABASE_ANON_KEY   مفتاح anon العام للبيئة                     │
/// │   APP_ENV             dev | staging | prod                        │
/// │                                                                   │
/// │ الخادم (Supabase project) — عبر `supabase secrets set` لكل مشروع: │
/// │   OPENWA_BASE_URL       عنوان بوابة OpenWA الخاصة                  │
/// │   OPENWA_SESSION_ID     جلسة WhatsApp الجاهزة                      │
/// │   OPENWA_API_KEY        مفتاح مشغل OpenWA                          │
/// │ تنشئ Edge Functions تحدي OTP وتستخدم OpenWA للتسليم فقط.           │
/// │                                                                   │
/// │ ممنوع: عناوين LAN/localhost في بناء staging/prod، تخزين بيانات    │
/// │ الاعتماد في SharedPreferences، أو تبديل الخادم من داخل التطبيق.    │
/// └─────────────────────────────────────────────────────────────────┘
class SupabaseConfig {
  SupabaseConfig._();
  static bool cloudReady = false;

  /// عنوان مشروع Supabase — يُحقن وقت البناء.
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');

  /// مفتاح anon العام — يُحقن وقت البناء.
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );

  /// المشروع السحابي الافتراضي للتطوير. المفتاح publishable مخصص للعميل.
  /// التشغيل المحلي أو مشروع آخر يمرر العنوان والمفتاح عبر dart-define.
  static const String _defaultDevUrl =
      'https://sgnbtrcbllnffcyzsjei.supabase.co';
  static const String _defaultDevPublishableKey =
      'sb_publishable_FCoMw-maX6ZjV123PIly5w_ZsfEwsUW';

  /// العنوان الفعال؛ staging/prod يتطلبان إعدادًا صريحًا وقت البناء.
  static String get effectiveUrl => supabaseUrl.isNotEmpty
      ? supabaseUrl
      : (EnvConfig.isDev ? _defaultDevUrl : '');

  /// الاسم القديم للمتغير يدعم أيضًا مفتاح Supabase publishable الجديد.
  static String get effectiveAnonKey => supabaseAnonKey.isNotEmpty
      ? supabaseAnonKey
      : (EnvConfig.isDev ? _defaultDevPublishableKey : '');

  /// تهيئة والتحقق من الإعداد قبل أي اتصال.
  static Future<void> init() async {
    EnvConfig.validate();

    final url = effectiveUrl;
    final key = effectiveAnonKey;

    if (url.isEmpty || key.isEmpty) {
      final message =
          '[SupabaseConfig] SUPABASE_URL / SUPABASE_ANON_KEY '
          'غير ممرّرة. ابنِ التطبيق مع '
          '--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... '
          '--dart-define=APP_ENV=dev|staging|prod';
      // في Release نفشل فوراً بوضوح بدل الاتصال بعنوان فارغ/محلي.
      if (EnvConfig.isProd || EnvConfig.isStaging) {
        throw StateError(message);
      }
      assert(url.isNotEmpty && key.isNotEmpty, message);
    }

    // تحصين إضافي: يُمنع اتصال بناء staging/prod بعنوان محلي/LAN.
    if (!EnvConfig.isDev && _isLocalAddress(url)) {
      throw StateError(
        '[SupabaseConfig] عنوان Supabase محلي ($url) في بيئة '
        '${EnvConfig.isProd ? "prod" : "staging"}. هذا ممنوع.',
      );
    }
  }

  static bool _isLocalAddress(String url) {
    final u = url.toLowerCase();
    return u.contains('127.0.0.1') ||
        u.contains('localhost') ||
        u.contains('10.0.2.2') ||
        u.contains('192.168.');
  }
}
