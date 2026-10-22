import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/core/sync/background_sync.dart';
import 'package:workmanager/workmanager.dart';

class _Workmanager extends WorkmanagerPlatform {
  final cancelled = <String>[];

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelled.add(uniqueName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android retires only its legacy database worker', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final previous = WorkmanagerPlatform.instance;
    final platform = _Workmanager();
    WorkmanagerPlatform.instance = platform;
    addTearDown(() => WorkmanagerPlatform.instance = previous);

    await configureBackgroundSync();

    expect(platform.cancelled, [backgroundSyncTask]);
  });

  test(
    'persisted Android worker exits before opening account storage',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // No Supabase singleton or platform storage is initialized in this test.
      // Entering the old worker body would fail before it can complete safely.
      expect(AppDatabase.instance.accountId, isNull);
      expect(await runBackgroundSync(backgroundSyncTask, null), isTrue);
      expect(AppDatabase.instance.accountId, isNull);
    },
  );
}
