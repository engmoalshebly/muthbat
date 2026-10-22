import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';
import 'package:muthbat/features/auth/data/business_access_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline onboarding persists one request and reconciles routing atomically',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'merchant-onboarding-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const owner = 'a1940000-0000-0000-0000-000000000001';
      await store.bindAccount(owner);
      var syncRequests = 0;
      final repository = MerchantRepository(requestSync: () => syncRequests++);
      final business = await repository.createBusiness(
        name: 'متجر الاختبار',
        businessType: 'retail',
        currencyCode: 'YER',
        contactPhoneDisplay: '777123456',
      );
      expect(syncRequests, 1);
      final db = await store.database;
      final queue = await db.query('offline_mutations_queue');
      expect(queue.length, 1);
      expect(
        jsonDecode(
          queue.single['payload_json'] as String,
        )['p_profile']['contact_phone'],
        '+967777123456',
      );
      await expectLater(
        repository.createBusiness(
          name: 'متجر آخر',
          businessType: 'retail',
          currencyCode: 'YER',
        ),
        throwsStateError,
      );
      expect((await db.query('local_businesses')).length, 1);
      final customer = await repository.addCustomer(
        businessId: business['id'] as String,
        localDisplayName: 'عميل الاختبار',
      );
      final dependent = (await db.query(
        'offline_mutations_queue',
        where: 'local_ref_id = ?',
        whereArgs: [customer.id],
      )).single;
      expect(
        dependent['depends_on_client_request_id'],
        queue.single['client_request_id'],
      );
      const serverId = 'a1940000-0000-0000-0000-000000000002';
      await store.reconcileBusinessId(
        localId: business['id'] as String,
        serverId: serverId,
      );
      expect(
        (await BusinessAccessRepository().cached(owner))?.businessId,
        serverId,
      );
      expect(
        (await db.query(
          'offline_mutations_queue',
          where: "command_type='create_business'",
        )).single['local_ref_id'],
        serverId,
      );
      expect(
        (await db.query('local_business_customers')).single['business_id'],
        serverId,
      );
      final rewritten = (await db.query(
        'offline_mutations_queue',
        where: 'local_ref_id = ?',
        whereArgs: [customer.id],
      )).single;
      expect(
        jsonDecode(rewritten['payload_json'] as String)['businessId'],
        serverId,
      );
      await db.close();
    },
  );
}
