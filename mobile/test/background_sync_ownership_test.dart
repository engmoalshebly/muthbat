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
    // Workmanager() is a lazily-constructed singleton whose constructor
    // runs _ensurePlatformImplementation() exactly once per process: the
    // first time anything calls Workmanager(), it installs a *real*
    // platform backend (WorkmanagerLinux() on Linux, nothing on Windows)
    // unless WorkmanagerPlatform.instance already looks like a real
    // Android/Apple implementation. That single construction happened to
    // occur above inside configureBackgroundSync() -> Workmanager() ->
    // cancelByUniqueName(), i.e. *after* the mock below was installed,
    // which silently replaced the mock with WorkmanagerLinux() on CI's
    // Linux runners (never reproduced on Windows, where no platform
    // branch matches). Force that one-time auto-registration to happen
    // now, before installing the mock, so it can never run again.
    Workmanager();
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
