import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app/app.dart';
import 'app/theme/app_colors.dart';
import 'core/config/supabase_config.dart';
import 'core/telemetry/crash_reporting.dart';
import 'core/services/push_notification_service.dart';
import 'core/sync/sync_engine.dart';
import 'core/sync/background_sync.dart';
import 'core/security/secure_auth_storage.dart';
import 'features/local_ledger/local_ledger_store.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (CrashReporting.enabled) {
    await SentryFlutter.init(CrashReporting.configure, appRunner: _bootstrap);
  } else {
    await _bootstrap();
  }
}

Future<void> _bootstrap() async {
  // تهيئة Firebase دون تعطيل الدفتر المحلي في حال عدم توفره
  try {
    if (defaultTargetPlatform == TargetPlatform.android || kIsWeb) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    debugPrint('[Main] Firebase initialization failed: $e');
  }

  try {
    await LocalLedgerStore.instance.database;
  } catch (e, stackTrace) {
    debugPrint('[Main] Local storage bootstrap failed: $e\n$stackTrace');
    runApp(
      _BootstrapErrorApp(message: 'تعذر فتح التخزين المحلي. لم تُحذف بياناتك.'),
    );
    return;
  }

  try {
    // Cloud failure must not prevent opening the independent local notebook.
    await SupabaseConfig.init();

    // 2. تهيئة عميل Supabase
    await Supabase.initialize(
      url: SupabaseConfig.effectiveUrl,
      publishableKey: SupabaseConfig.effectiveAnonKey,
      authOptions: secureAuthOptions(SupabaseConfig.effectiveUrl),
    );
    SupabaseConfig.cloudReady = true;

    // 3. تهيئة خدمة إشعارات الدفع (FCM)
    await PushNotificationService.instance.init();
  } catch (e) {
    debugPrint('[Main] Bootstrap failed: $e');
  }

  // 3. تشغيل محرك المزامنة الخلفي
  if (SupabaseConfig.cloudReady) {
    SyncEngine.instance.init();
    try {
      await configureBackgroundSync();
    } catch (e) {
      debugPrint('[Main] Background sync scheduling unavailable: $e');
    }
  }

  // ضبط شريط الحالة الافتراضي للواجهة
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: AppColors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.backgroundLight,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(const ProviderScope(child: MuthbatApp()));
}

class _BootstrapErrorApp extends StatelessWidget {
  const _BootstrapErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: AppColors.primaryDark,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: AppColors.white,
                    size: 54,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'تعذر تشغيل التطبيق',
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: AppColors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'تعذر فتح التخزين المحلي. أعد فتح التطبيق، وإن استمرت المشكلة تواصل مع الدعم.',
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.white54,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
