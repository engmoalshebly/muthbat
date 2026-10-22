import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'public customer refresh preserves private phone across repeated sync and restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'customer-phone-sync-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const owner = 'a0000000-0000-0000-0000-000000000001';
      await store.bindAccount(owner);
      await store.upsertBusinessCustomer({
        'id': 'customer-1',
        'business_id': 'business-1',
        'local_display_name': 'أحمد',
        'phone': '+967777123456',
        'sync_status': 'synced',
      });
      for (var i = 0; i < 2; i++) {
        await store.upsertBusinessCustomer({
          'id': 'customer-1',
          'business_id': 'business-1',
          'local_display_name': 'أحمد',
          'current_balance': 100,
          'sync_status': 'synced',
        }, fromServer: true);
      }
      await store.lockAccount();
      await store.bindAccount(owner);
      final rows = await (await store.database).query(
        'local_business_customers',
        where: 'id=?',
        whereArgs: ['customer-1'],
      );
      expect(rows.single['phone'], '+967777123456');
      final db = await store.database;
      await db.insert('local_ledger_entries', {
        'id': 'pending-entry',
        'business_id': 'business-1',
        'business_customer_id': 'customer-1',
        'entry_type': 'debt',
        'direction': 'debit',
        'amount': 30,
        'amount_minor': 300000,
        'currency_code': 'YER',
        'description': 'Pending debt',
        'occurred_at': '2026-10-19T00:00:00Z',
        'client_request_id': 'debt-request',
        'sync_status': 'pending_insert',
        'created_at': '2026-10-19T00:00:00Z',
      });
      Future<void> pull(num server) async {
        await store.upsertBusinessCustomer({
          'id': 'customer-1',
          'business_id': 'business-1',
          'local_display_name': 'أحمد',
          'current_balance': server,
          'sync_status': 'synced',
        }, fromServer: true);
        await store.upsertCurrencyBalancesFromServer('business-1', [
          {
            'business_customer_id': 'customer-1',
            'currency_code': 'YER',
            'current_balance': server,
            'total_debits': server,
            'total_credits': 0,
            'entry_count': 1,
          },
        ]);
      }

      await pull(120);
      var displayed = await db.query(
        'local_business_customers',
        where: 'id=?',
        whereArgs: ['customer-1'],
      );
      expect(displayed.single['current_balance'], 150);
      expect(
        (await store.getCustomerCurrencyBalances('customer-1'))['YER'],
        150,
      );
      await store.upsertLedgerEntryFromServer({
        'id': 'server-entry',
        'business_id': 'business-1',
        'business_customer_id': 'customer-1',
        'entry_type': 'debt',
        'direction': 'debit',
        'amount': 30,
        'currency_code': 'YER',
        'description': 'Pending debt',
        'occurred_at': '2026-10-19T00:00:00Z',
        'client_request_id': 'debt-request',
        'created_at': '2026-10-19T00:00:00Z',
      });
      await pull(150);
      displayed = await db.query(
        'local_business_customers',
        where: 'id=?',
        whereArgs: ['customer-1'],
      );
      expect(displayed.single['current_balance'], 150);
      expect(
        (await store.getCustomerCurrencyBalances('customer-1'))['YER'],
        150,
      );
      await db.update(
        'local_business_customers',
        {
          'sync_status': 'pending_update',
          'local_display_name': 'Locally edited name',
        },
        where: 'id=?',
        whereArgs: ['customer-1'],
      );
      await db.insert('local_ledger_entries', {
        'id': 'pending-payment',
        'business_id': 'business-1',
        'business_customer_id': 'customer-1',
        'entry_type': 'payment',
        'direction': 'credit',
        'amount': 20,
        'amount_minor': 200000,
        'currency_code': 'YER',
        'description': 'Pending payment',
        'occurred_at': '2026-10-19T00:00:00Z',
        'client_request_id': 'payment-request',
        'sync_status': 'pending_insert',
        'created_at': '2026-10-19T00:00:00Z',
      });
      await pull(150);
      final edited = (await db.query(
        'local_business_customers',
        where: 'id=?',
        whereArgs: ['customer-1'],
      )).single;
      expect(edited['current_balance'], 130);
      expect(edited['local_display_name'], 'Locally edited name');
      expect(edited['sync_status'], 'pending_update');
      expect(
        (await store.getCustomerCurrencyBalances('customer-1'))['YER'],
        130,
      );
      await store.lockAccount();
    },
  );
}
