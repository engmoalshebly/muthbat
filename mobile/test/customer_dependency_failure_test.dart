import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'rejected directory blocks descendants, survives restart, and retries original before debts',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'customer-dependencies-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const owner = 'a1930000-0000-0000-0000-000000000001';
      await store.bindAccount(owner);
      await store.upsertBusinessCustomer({
        'id': 'cust-test',
        'business_id': 'business-test',
        'local_display_name': 'Test customer',
        'sync_status': 'pending_directory',
      });
      final root = await store.enqueueMutation(
        commandType: 'customer_directory',
        payload: {},
        localRefId: 'cust-test',
      );
      Future<void> debt(String id) => store.saveLedgerEntryOptimistic(
        entry: {
          'id': 'entry-$id',
          'business_id': 'business-test',
          'business_customer_id': 'cust-test',
          'entry_type': 'debt',
          'direction': 'debit',
          'amount': 30,
          'currency_code': 'YER',
          'description': 'Local debt',
          'occurred_at': '2026-10-19T00:00:00Z',
          'client_request_id': id,
          'sync_status': 'pending_insert',
          'created_at': '2026-10-19T00:00:00Z',
        },
        commandType: 'create_ledger_entry',
        payload: {'p_business_customer_id': 'cust-test'},
      );
      await debt('debt-one');
      await store.enqueueMutation(
        commandType: 'upload_attachment',
        payload: {},
        clientRequestId: 'attachment',
        dependsOnClientRequestId: 'debt-one',
      );
      await store.markMutationFailed(
        root,
        attemptCount: 1,
        error: 'temporary',
        nextRetryAt: DateTime.now(),
      );
      expect(
        (await store.getCustomerById('cust-test'))!['sync_status'],
        'failed',
      );
      await store.markMutationDeadLetter(
        root,
        attemptCount: 2,
        error: 'Rejected phone',
        errorCode: '422',
      );
      await debt('debt-after-failure');
      // Reproduce the old v9 state: parent rejected, children silently pending.
      final legacy = await store.database;
      await legacy.update('local_business_customers', {
        'sync_status': 'pending_directory',
      });
      await legacy.update('offline_mutations_queue', {
        'status': 'pending',
        'last_error_code': null,
      }, where: "last_error_code='dependency_failed'");
      await legacy.update('local_ledger_entries', {
        'sync_status': 'pending_insert',
      });
      await legacy.execute('PRAGMA user_version=9');
      await store.lockAccount();
      await store.bindAccount(owner);
      final rejected = await store.getDeadLetterMutations();
      expect(rejected.length, 4);
      expect(rejected.first['customer_name'], 'Test customer');
      expect(rejected.first['dependent_count'], 2);
      expect(
        (await store.getLedgerEntries(
          'cust-test',
        )).every((r) => r['sync_status'] == 'blocked'),
        isTrue,
      );
      expect((await store.getDueMutations(DateTime.now())), isEmpty);
      expect((await store.getCustomerCurrencyBalances('cust-test'))['YER'], 60);
      await store.retryDeadLetterMutation('attachment');
      expect(
        (await store.getCustomerById('cust-test'))!['sync_status'],
        'pending_directory',
      );
      final due = await store.getDueMutations(DateTime.now());
      expect(due.length, 4);
      expect(
        due.singleWhere(
          (r) => r['client_request_id'] == 'debt-one',
        )['depends_on_client_request_id'],
        root,
      );
      expect(
        (await store.getLedgerEntries(
          'cust-test',
        )).every((r) => r['sync_status'] == 'pending_insert'),
        isTrue,
      );
      await store.queueCustomerProfileChange('cust-test',{'local_display_name':'Edited while local'},
        {'p_business_customer_id':'cust-test','p_action':'update','p_profile':{'display_name':'Edited while local'}});
      final atomicDb = await store.database;
      await atomicDb.execute(
        "CREATE TRIGGER fail_rewrite BEFORE UPDATE OF payload_json ON offline_mutations_queue BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END",
      );
      await expectLater(
        store.reconcileCustomerId(
          localId: 'cust-test',
          serverId: 'a1930000-0000-0000-0000-000000000002',
        ),
        throwsA(isA<Exception>()),
      );
      expect(await store.getServerId('cust-test'), isNull);
      expect(await store.getCustomerById('cust-test'), isNotNull);
      expect((await store.getLedgerEntries('cust-test')).length, 2);
      await atomicDb.execute('DROP TRIGGER fail_rewrite');
      await store.reconcileCustomerId(
        localId: 'cust-test',
        serverId: 'a1930000-0000-0000-0000-000000000002',
      );
      await store.removeMutation(root);
      final profile=(await store.getPendingMutations()).singleWhere((r)=>r['command_type']=='mutate_customer_profile');
      expect(profile['local_ref_id'],'a1930000-0000-0000-0000-000000000002');
      expect(await store.hasMutation(root), isFalse);
      expect(
        (await store.getLedgerEntries(
          'a1930000-0000-0000-0000-000000000002',
        )).length,
        2,
      );
      await store.lockAccount();
    },
  );
}
