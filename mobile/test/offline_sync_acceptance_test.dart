import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/core/sync/sync_policy.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pagination drains every page beyond the 500-row server limit',
    () async {
      final source = List<int>.generate(1201, (index) => index);
      final pages = <List<int>>[];
      final result = await collectAllPages<int>(
        fetchPage: (from, to) async {
          final page = source.sublist(from, (to + 1).clamp(0, source.length));
          pages.add(page);
          return page;
        },
      );
      expect(result, source);
      expect(pages.map((page) => page.length), [500, 500, 201]);
    },
  );

  test('changing account invalidates the active sync lease', () {
    expect(
      () => assertSyncAccount(expected: 'account-a', current: 'account-b'),
      throwsA(isA<SyncAccountChanged>()),
    );
    expect(
      () => assertSyncAccount(expected: 'account-a', current: 'account-a'),
      returnsNormally,
    );
  });

  test(
    'every offline workflow step is durably queued across restart',
    () async {
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp('offline-matrix-');
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const account = '56666666-6666-4666-8666-666666666666';
      const commands = [
        'create_business',
        'customer_directory',
        'create_ledger_entry', // debt
        'create_ledger_entry', // payment
        'apply_customer_discount',
        'reverse_ledger_entry',
        'upload_attachment',
        'generate_statement',
      ];
      await store.bindAccount(account);
      for (var i = 0; i < commands.length; i++) {
        await store.enqueueMutation(
          commandType: commands[i],
          clientRequestId:
              '57777777-7777-4777-8777-${i.toString().padLeft(12, '0')}',
          payload: {'step': i},
        );
      }
      await store.lockAccount();
      await store.bindAccount(account);
      expect(
        (await store.getPendingMutations())
            .map((row) => row['command_type'] as String)
            .toList(),
        commands,
      );
      await store.lockAccount();
      await folder.delete(recursive: true);
    },
  );

  test(
    '100 offline commands survive restart, remain account-isolated and are removed once',
    () async {
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp('sync-acceptance-');
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const first = '51111111-1111-4111-8111-111111111111';
      const second = '52222222-2222-4222-8222-222222222222';

      await store.bindAccount(first);
      final localDb = await store.database;
      await localDb.insert('local_businesses', {
        'id': 'business-local',
        'owner_user_id': first,
        'name': 'Offline Store',
      });
      await localDb.insert('local_business_customers', {
        'id': 'customer-local',
        'business_id': 'business-local',
        'local_display_name': 'Offline Customer',
      });
      await store.saveLedgerEntryOptimistic(
        entry: const {
          'id': 'entry-local',
          'business_id': 'business-local',
          'business_customer_id': 'customer-local',
          'entry_type': 'debt',
          'direction': 'debit',
          'amount': 1.25,
          'currency_code': 'YER',
          'description': 'offline debt with attachment',
          'occurred_at': '2026-09-13T12:00:00Z',
          'client_request_id': 'entry-request',
          'sync_status': 'pending_insert',
        },
        commandType: 'create_ledger_entry',
        payload: const {'p_business_customer_id': 'customer-local'},
        dependentMutation: const {
          'client_request_id': 'attachment-request',
          'command_type': 'upload_attachment',
          'local_ref_id': 'entry-local',
          'payload': {
            'entityId': 'entry-local',
            'localPath': '/tmp/receipt.jpg',
          },
        },
      );
      final atomicQueue = await store.getPendingMutations();
      expect(atomicQueue, hasLength(2));
      expect(atomicQueue.last['depends_on_client_request_id'], 'entry-request');
      await store.removeMutation('entry-request');
      await store.removeMutation('attachment-request');

      for (var i = 0; i < 100; i++) {
        await store.enqueueMutation(
          commandType: 'create_ledger_entry',
          clientRequestId:
              '53333333-3333-4333-8333-${i.toString().padLeft(12, '0')}',
          payload: {'sequence': i},
        );
      }
      expect(await store.getPendingMutationsCount(), 100);

      // Simulates process death while an item is in-flight.
      final firstRequest = (await store.getPendingMutations()).first;
      await store.markMutationSyncing(
        firstRequest['client_request_id'] as String,
      );
      await store.lockAccount();
      await store.bindAccount(second);
      expect(await store.getPendingMutationsCount(), 0);
      await store.lockAccount();
      await store.bindAccount(first);
      await store.recoverStuckSyncingMutations();
      expect(await store.getPendingMutationsCount(), 100);

      for (final row in await store.getPendingMutations()) {
        final request = row['client_request_id'] as String;
        await store.removeMutation(request);
        await store.removeMutation(
          request,
        ); // duplicate acknowledgement is harmless
      }
      expect(await store.getPendingMutationsCount(), 0);

      await store.enqueueMutation(
        commandType: 'create_ledger_entry',
        clientRequestId: '54444444-4444-4444-8444-444444444444',
        payload: const {},
      );
      await store.markMutationDeadLetter(
        '54444444-4444-4444-8444-444444444444',
        attemptCount: 1,
        error: 'ambiguous financial rejection',
      );
      await expectLater(
        store.discardDeadLetterMutation('54444444-4444-4444-8444-444444444444'),
        throwsStateError,
      );

      await store.enqueueMutation(
        commandType: 'generate_statement',
        clientRequestId: '55555555-5555-4555-8555-555555555555',
        payload: const {},
      );
      await store.markMutationDeadLetter(
        '55555555-5555-4555-8555-555555555555',
        attemptCount: 1,
        error: 'statement generation rejected',
      );
      await store.discardDeadLetterMutation(
        '55555555-5555-4555-8555-555555555555',
      );
      expect(
        await store.hasMutation('55555555-5555-4555-8555-555555555555'),
        isFalse,
      );

      await store.lockAccount();
      await folder.delete(recursive: true);
    },
  );
}
