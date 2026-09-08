import 'env.dart';

/// إعدادات الاتصال بمنظومة Supabase — حقن وقت البناء فقط (--dart-define).
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │ الأسرار والقيم المطلوبة لكل بيئة (لا تُكتب هنا إطلاقاً):          │
/// │                                                                   │
/// │ العميل (موبايل) — عبر --dart-define من CI secrets:                │
/// │   SUPABASE_URL        عنوان مشروع Supabase للبيئة                 │
/// │   SUPABASE_ANON_KEY   مفتاح anon العام للبيئة                     │
/// │   APP_ENV             dev | staging | prod                        │
/// │                                                                   │
/// │ الخادم (Supabase project) — عبر `supabase secrets set` لكل مشروع: │
/// │   TWILIO_ACCOUNT_SID        حساب Twilio لمزود Phone Auth          │
/// │   TWILIO_AUTH_TOKEN         رمز Twilio                            │
/// │   TWILIO_VERIFY_SERVICE_SID خدمة Twilio Verify (قناة WhatsApp     │
/// │                             بقالب معتمد من Meta)                  │
/// │ وتُضبط في config.toml تحت [auth.sms] و[auth.sms.twilio_verify]    │
/// │ مع enable_signup = true و enable_confirmations = true.            │
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

  /// القيم المخصصة للبيئة المحلية (Local Stack)
  // Android Emulator reaches the host machine through 10.0.2.2.
  // 127.0.0.1 would point back to the emulator itself.
  static const String _defaultLocalDevUrl = 'http://10.0.2.2:55321';
  static const String _defaultLocalDevAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

  /// العنوان الفعال للاتصال (يستخدم العنوان المحلي تلقائياً في بيئة dev)
  static String get effectiveUrl => supabaseUrl.isNotEmpty
      ? supabaseUrl
      : (EnvConfig.isDev ? _defaultLocalDevUrl : '');

  /// المفتاح الفعال للاتصال (يستخدم المفتاح المحلي تلقائياً في بيئة dev)
  static String get effectiveAnonKey => supabaseAnonKey.isNotEmpty
      ? supabaseAnonKey
      : (EnvConfig.isDev ? _defaultLocalDevAnonKey : '');

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
