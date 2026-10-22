import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'large directory groups currencies, isolates businesses and persists contact refresh',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp('customer-batch-');
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const owner = 'a1940000-0000-0000-0000-000000000001';
      await store.bindAccount(owner);
      final db = await store.database;
      await db.transaction((txn) async {
        for (var i = 0; i < 1201; i++) {
          await txn.insert('local_business_customers', {
            'id': 'customer-$i',
            'business_id': 'business-a',
            'local_display_name': 'Customer $i',
            'sync_status': 'synced',
            'updated_at': '2026-10-19T00:00:00Z',
          });
          for (final currency in ['YER', 'USD']) {
            await txn.insert('local_customer_currency_balances', {
              'id': 'balance-$i-$currency',
              'business_id': 'business-a',
              'business_customer_id': 'customer-$i',
              'currency_code': currency,
              'current_balance_minor': i * 10000,
              'current_balance': i,
            });
          }
        }
        await txn.insert('local_customer_currency_balances', {
          'id': 'other-balance',
          'business_id': 'business-b',
          'business_customer_id': 'other',
          'currency_code': 'SAR',
          'current_balance': 999,
        });
      });
      final customers = await MerchantRepository().getCustomers('business-a');
      expect(customers.length, 1201);
      final first = await MerchantRepository().getCustomers(
        'business-a',
        limit: 50,
      );
      final second = await MerchantRepository().getCustomers(
        'business-a',
        limit: 50,
        offset: 50,
      );
      expect(first.length, 50);
      expect(second.length, 50);
      expect(
        first
            .map((r) => r.id)
            .toSet()
            .intersection(second.map((r) => r.id).toSet()),
        isEmpty,
      );
      final totalsBefore = await store.getActiveCustomerTotals(
        'business-a',
        'YER',
      );
      final searched = await MerchantRepository().getCustomers(
        'business-a',
        searchQuery: 'Customer 1200',
        limit: 50,
      );
      expect(searched.single.id, 'customer-1200');
      expect(
        await store.getActiveCustomerTotals('business-a', 'YER'),
        totalsBefore,
      );
      expect(await store.countActiveCustomers('business-a'), 1201);
      final dashboard = await MerchantRepository().getDashboardCustomers(
        'business-a',
        'YER',
      );
      expect(dashboard.length, lessThanOrEqualTo(24));
      expect(dashboard.any((c) => c.id == 'customer-1200'), isTrue);
      expect(
        customers.singleWhere((c) => c.id == 'customer-1200').currencyBalances,
        {'YER': 1200, 'USD': 1200},
      );
      expect(
        (await store.getBusinessCurrencyBalances(
          'business-a',
        )).containsKey('other'),
        isFalse,
      );
      final pending = await store.getContactsNeedingRefresh('business-a');
      expect(pending.length, 1201);
      await store.cacheCustomerContacts('business-a', pending, {
        'customer-0': '+967777123456',
      });
      expect(await store.getContactsNeedingRefresh('business-a'), isEmpty);
      await store.lockAccount();
      await store.bindAccount(owner);
      expect(
        (await store.getCustomerById('customer-0'))!['phone'],
        '+967777123456',
      );
      expect(await store.getContactsNeedingRefresh('business-a'), isEmpty);
      await (await store.database).update(
        'local_business_customers',
        {'updated_at': '2026-10-20T00:00:00Z'},
        where: 'id=?',
        whereArgs: ['customer-0'],
      );
      expect(
        (await store.getContactsNeedingRefresh('business-a')).single['id'],
        'customer-0',
      );
      await store.lockAccount();
    },
  );
}
