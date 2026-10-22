import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../config/supabase_config.dart';
import '../database/app_database.dart';
import '../security/secure_auth_storage.dart';
import 'sync_engine.dart';
import '../../features/customer/data/customer_repository.dart';
import '../../features/customer/data/customer_disputes_repository.dart';
import '../../features/notifications/notification_repository.dart';

const backgroundSyncTask = 'com.muthbat.muthbat.periodic-sync';

@pragma('vm:entry-point')
void backgroundSyncDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != backgroundSyncTask) return true;
    final store = AppDatabase.instance;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await SupabaseConfig.init();
      await Supabase.initialize(
        url: SupabaseConfig.effectiveUrl,
        publishableKey: SupabaseConfig.effectiveAnonKey,
        authOptions: secureAuthOptions(SupabaseConfig.effectiveUrl),
      );
      var session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        return true;
      }
      if (session.isExpired) {
        await Supabase.instance.client.auth.refreshSession().timeout(
          const Duration(seconds: 15),
        );
        session = Supabase.instance.client.auth.currentSession;
        if (session == null || session.isExpired) return false;
      }
      // Background work must follow the authenticated identity, not whichever
      // local workspace preference was most recently remembered on-device.
      await store.bindAccount(session.user.id);
      if (await store.getProfile(session.user.id) == null) return true;
      if (Supabase.instance.client.auth.currentUser?.id != session.user.id) {
        return true;
      }
      final synced = await SyncEngine.instance.triggerSync();
      final owner = session.user.id;
      final customer = CustomerRepository();
      await Future.wait([
        NotificationRepository().sync(owner, Supabase.instance.client),
        () async {
          await customer.flushOutbox();
          if (store.accountId != owner) return;
          await CustomerDisputesRepository().sync(owner);
          final home = await customer.fetchHomeSnapshot();
          if (store.accountId == owner) await customer.syncLocalLedgers(home);
        }(),
      ]);
      return synced;
    } catch (_) {
      return false;
    } finally {
      if (store.accountId != null) {
        try {
          await store.lockAccount();
        } catch (_) {
          // The background isolate is short-lived; never mask sync outcome.
        }
      }
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
