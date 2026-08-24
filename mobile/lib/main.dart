import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app/app.dart';
import 'app/theme/app_colors.dart';
import 'core/config/supabase_config.dart';
import 'core/database/app_database.dart';
import 'core/sync/sync_engine.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // 1. تهيئة الإعدادات وقاعدة البيانات المحلية
    await SupabaseConfig.init();
    await AppDatabase.instance.database;

    // 2. تهيئة عميل Supabase
    await Supabase.initialize(
      url: SupabaseConfig.effectiveUrl,
      anonKey: SupabaseConfig.effectiveAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  } catch (e) {
    debugPrint('[Main] Bootstrap failed: $e');
    runApp(_BootstrapErrorApp(message: e.toString()));
    return;
  }

  // 3. تشغيل محرك المزامنة الخلفي
  SyncEngine.instance.init();

  // ضبط شريط الحالة الافتراضي للواجهة
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
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
                    color: Colors.white,
                    size: 54,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'تعذر تشغيل التطبيق',
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'تحقق من إعدادات الاتصال ثم أعد فتح التطبيق.',
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
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
