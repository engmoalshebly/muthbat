import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';

class _GatedFactory implements DatabaseFactory {
  final entered = Completer<void>();
  final release = Completer<void>();
  int opens = 0;
  bool failOnce = false;

  @override
  Future<String> getDatabasesPath() => databaseFactoryFfi.getDatabasesPath();

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    opens++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (failOnce) {
      failOnce = false;
      throw StateError('simulated open failure');
    }
    return databaseFactoryFfi.openDatabase(path, options: options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  final store = AppDatabase.instance;
  late _GatedFactory factory;

  setUp(() async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'database-startup-',
    );
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    factory = _GatedFactory();
    AppDatabase.debugDatabaseFactory = factory;
  });

  tearDown(() async {
    if (!factory.release.isCompleted) factory.release.complete();
    await store.lockAccount();
    AppDatabase.debugDatabaseFactory = null;
  });

  test(
    'startup readers share the initial account open and completed schema',
    () async {
      final bind = store.bindAccount(owner);
      await factory.entered.future.timeout(const Duration(seconds: 5));
      final readers = List.generate(8, (_) => store.database);
      await Future<void>.delayed(Duration.zero);
      final openCount = factory.opens;
      factory.release.complete();
      await bind.timeout(const Duration(seconds: 5));
      final databases = await Future.wait(
        readers,
      ).timeout(const Duration(seconds: 5));
      expect(openCount, 1);
      expect(factory.opens, 1);
      expect(databases.every((db) => identical(db, databases.first)), isTrue);
      expect(await databases.first.query('local_profiles'), isEmpty);
      expect(await store.getPendingMutationsCount(), 0);
    },
  );

  test(
    'locking waits for startup to finish and closes its only connection',
    () async {
      final bind = store.bindAccount(owner);
      await factory.entered.future.timeout(const Duration(seconds: 5));
      final reader = store.database;
      final locking = store.lockAccount();
      factory.release.complete();
      await bind;
      final database = await reader;
      await locking.timeout(const Duration(seconds: 5));
      expect(database.isOpen, isFalse);
      expect(factory.opens, 1);
      expect(store.accountId, isNull);
    },
  );

  test('a failed startup open can be retried', () async {
    factory.failOnce = true;
    factory.release.complete();
    await expectLater(store.bindAccount(owner), throwsStateError);
    final database = await store.database.timeout(const Duration(seconds: 5));
    expect(database.isOpen, isTrue);
    expect(factory.opens, 2);
  });
}
