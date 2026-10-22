import 'dart:io';
import 'package:muthbat/features/customer/data/customer_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test(
    'locking preserves pending data and switching accounts cannot read it',
    () async {
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'muthbat-account-test-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const first = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      const second = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
      await expectLater(store.database, throwsStateError);
      await store.bindAccount(first);
      final customerCache = CustomerCache();
      await customerCache.write(first, 'home', {'balance': 123});
      expect((await customerCache.read(first, 'home'))?['balance'], 123);
      final db = await store.database;
      // Model another engine opening the same file with sqflite's default
      // shared-instance option, then closing it when its task finishes.
      final worker = await databaseFactoryFfi.openDatabase(db.path);
      expect(identical(worker, db), isFalse);
      await worker.close();
      expect(db.isOpen, isTrue);
      expect(await db.query('local_profiles'), isEmpty);
      await db.insert('offline_mutations_queue', {
        'client_request_id': 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        'command_type': 'create_business',
        'payload_json': '{}',
        'status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      });
      // A background Flutter engine can close the native sqflite connection
      // while this isolate still holds the old Dart Database handle.
      await db.close();
      final reopened = await store.database;
      expect(reopened.isOpen, isTrue);
      expect(await store.getPendingMutationsCount(), 1);
      await store.lockAccount();
      await expectLater(store.database, throwsStateError);
      await store.bindAccount(second);
      expect(await customerCache.read(second, 'home'), isNull);
      expect(await customerCache.read(first, 'home'), isNull);
      await customerCache.write(first, 'home', {'balance': 999});
      expect(await store.getPendingMutationsCount(), 0);
      await store.lockAccount();
      await store.bindAccount(first);
      expect((await customerCache.read(first, 'home'))?['balance'], 123);
      expect(await store.getPendingMutationsCount(), 1);
      await store.saveBusiness({
        'id': 'dddddddd-dddd-dddd-dddd-dddddddddddd',
        'owner_user_id': first,
        'name': 'بقالتي',
        'is_active': 1,
      });
      await store.lockAccount();
      final restored = await store.restoreRememberedOwner();
      expect(restored?['name'], 'بقالتي');
      expect(store.accountId, first);
      expect(await store.getPendingMutationsCount(), 1);
      await store.forgetRememberedOwner();
      await store.lockAccount();
      expect(await store.restoreRememberedOwner(), isNull);
      await store.bindAccount(second);
      await store.saveProfile({
        'id': second,
        'display_name': 'زبون',
        'user_type': 'customer',
        'phone': '967700000001',
        'updated_at': DateTime.now().toIso8601String(),
      });
      await customerCache.write(second, 'home', {'balance': 44});
      await store.rememberCustomer();
      await store.lockAccount();
      expect((await store.restoreRememberedCustomer())?['id'], second);
      expect((await customerCache.read(second, 'home'))?['balance'], 44);
      expect(await customerCache.read(first, 'home'), isNull);
      await store.forgetRememberedOwner();
      await store.lockAccount();
      expect(await store.restoreRememberedCustomer(), isNull);
    },
  );

  test(
    'concurrent account transitions leave one isolated account active',
    () async {
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'muthbat-account-transition-test-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const first = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
      const second = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

      await Future.wait([store.bindAccount(first), store.bindAccount(second)]);
      expect(store.accountId, second);
      await store.saveProfile({
        'id': second,
        'display_name': 'Second account',
        'user_type': 'customer',
        'phone': '967700000002',
        'updated_at': DateTime.now().toIso8601String(),
      });

      await Future.wait([store.lockAccount(), store.bindAccount(first)]);
      expect(store.accountId, first);
      expect(await store.getProfile(second), isNull);
      await store.lockAccount();
      await store.bindAccount(second);
      expect(
        (await store.getProfile(second))?['display_name'],
        'Second account',
      );
      await store.lockAccount();
    },
  );
}
