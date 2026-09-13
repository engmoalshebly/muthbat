import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../config/supabase_config.dart';
import '../database/app_database.dart';
import 'sync_engine.dart';

const backgroundSyncTask = 'com.muthbat.muthbat.periodic-sync';

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != backgroundSyncTask) return true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await SupabaseConfig.init();
      await Supabase.initialize(
        url: SupabaseConfig.effectiveUrl,
        publishableKey: SupabaseConfig.effectiveAnonKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
      final store = AppDatabase.instance;
      final cached =
          await store.restoreRememberedOwner() ??
          await store.restoreRememberedCustomer();
      if (cached == null ||
          Supabase.instance.client.auth.currentSession == null) {
        return true;
      }
      await SyncEngine.instance.triggerSync();
      await store.lockAccount();
      return true;
    } catch (_) {
      return false;
    }
  });
}

/// Background scheduling is best-effort on both platforms. The operating
/// system decides when (or whether) a task runs; foreground/resume sync remains
/// the correctness path.
Future<void> configureBackgroundSync() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  await Workmanager().initialize(backgroundSyncDispatcher);
  await Workmanager().registerPeriodicTask(
    backgroundSyncTask,
    backgroundSyncTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}
