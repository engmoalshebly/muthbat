import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline profile commands survive reopen and snapshot acceptance prevents double counting atomically',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'offline-profile-snapshot-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const owner = 'a1970000-0000-0000-0000-000000000001',
          customer = 'a1970000-0000-0000-0000-000000000002';
      await store.bindAccount(owner);
      await store.upsertBusinessCustomer({
        'id': customer,
        'business_id': 'business',
        'local_display_name': 'Original',
        'sync_status': 'synced',
      });
      final repo = MerchantRepository(requestSync: () {});
      await repo.updateCustomer(
        customerId: customer,
        displayName: 'Offline name',
        note: 'Offline note',
        creditLimit: 300,
      );
      var queue = await store.getPendingMutations();
      expect(queue.single['command_type'], 'mutate_customer_profile');
      final editRequest = queue.single['client_request_id'] as String;
      await store.saveLedgerEntryOptimistic(
        entry: {
          'id': 'pending-debt',
          'business_id': 'business',
          'business_customer_id': customer,
          'entry_type': 'debt',
          'direction': 'debit',
          'amount': 30,
          'currency_code': 'YER',
          'description': 'Debt',
          'occurred_at': '2026-10-19T00:00:00Z',
          'client_request_id': 'a1970000-0000-0000-0000-000000000003',
          'sync_status': 'pending_insert',
          'created_at': '2026-10-19T00:00:00Z',
        },
        commandType: 'create_ledger_entry',
        payload: {'p_business_customer_id': customer},
      );
      List<Map<String, dynamic>> snapshot({bool accepted = false}) => [
        if (accepted)
          {
            'kind': 'entry',
            'payload': {
              'id': 'server-debt',
              'business_id': 'business',
              'business_customer_id': customer,
              'entry_type': 'debt',
              'direction': 'debit',
              'amount': 30,
              'currency_code': 'YER',
              'description': 'Debt',
              'occurred_at': '2026-10-19T00:00:00Z',
              'client_request_id': 'a1970000-0000-0000-0000-000000000003',
              'created_at': '2026-10-19T00:00:00Z',
            },
          },
        {
          'kind': 'customer',
          'payload': {
            'id': customer,
            'business_id': 'business',
            'local_display_name': 'Remote old name',
            'current_balance': accepted ? 130 : 100,
            'is_archived': false,
          },
        },
        {
          'kind': 'balance',
          'payload': {
            'business_id': 'business',
            'business_customer_id': customer,
            'currency_code': 'YER',
            'current_balance': accepted ? 130 : 100,
            'total_debits': accepted ? 130 : 100,
          },
        },
      ];
      await store.applyMerchantSnapshot(
        'business',
        snapshot(),
        snapshotId: 'before',
      );
      expect(
        (await store.getCustomerById(customer))!['local_display_name'],
        'Offline name',
      );
      expect((await store.getCustomerCurrencyBalances(customer))['YER'], 130);
      final before = await store.getCustomerById(customer);
      await expectLater(
        store.applyMerchantSnapshot('business', [
          ...snapshot(accepted: true),
          {
            'kind': 'state',
            'payload': {'entry_id': 'server-debt'},
          },
        ], snapshotId: 'failed'),
        throwsStateError,
      );
      expect(await store.getCustomerById(customer), before);
      expect(await store.getSyncStateValue('snapshot:business'), 'before');
      expect(
        (await store.getLedgerEntries(customer)).single['id'],
        'pending-debt',
      );
      await store.applyMerchantSnapshot(
        'business',
        snapshot(accepted: true),
        snapshotId: 'accepted',
      );
      expect((await store.getCustomerCurrencyBalances(customer))['YER'], 130);
      expect((await store.getCustomerById(customer))!['current_balance'], 130);
      expect(
        (await store.getLedgerEntries(customer)).single['sync_status'],
        'synced',
      );
      await repo.archiveCustomer(customer);
      queue = await store.getPendingMutations();
      expect(jsonDecode(queue.last['payload_json'])['p_action'], 'archive');
      expect((await store.getBusinessCustomers('business')), isEmpty);
      expect(
        await store.hasEarlierCustomerWork(customer, queue.last['id'] as int),
        isTrue,
      );
      await store.applyMerchantSnapshot('business', snapshot(accepted: true));
      expect((await store.getCustomerById(customer))!['is_archived'], 1);
      await store.lockAccount();
      await store.bindAccount(owner);
      expect(
        (await store.getCustomerById(customer))!['local_display_name'],
        'Offline name',
      );
      expect((await store.getPendingMutations()).length, 3);
      await store.completeCustomerProfileMutation(editRequest, customer);
      expect(
        (await store.getCustomerById(customer))!['sync_status'],
        'pending_update',
      );
      await store.lockAccount();
    },
  );
}
