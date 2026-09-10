import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/features/local_ledger/local_ledger_store.dart';

void main() {
  late LocalLedgerStore store;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    store = LocalLedgerStore(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await store.create('', 'YER');
  });
  tearDown(() async => (await store.database).close());
  test(
    'category report separates types and excludes reversed entries',
    () async {
      final id = await store.record(
        customerName: 'تصنيفات',
        type: 'debt',
        amount: '100',
        description: 'شراء مواد',
        category: 'مشتريات',
      );
      await store.record(
        customerId: id,
        type: 'payment',
        amount: '20',
        description: 'سداد نقدي',
        category: 'مشتريات',
      );
      final payment = ((await store.current())!['entries'] as List).last;
      await store.reverse(payment['id'], 'تصحيح اختبار');
      final doc = (await store.current())!;
      expect(LocalLedgerStore.categoryTotals(doc)['مشتريات'], {
        'debt': 1000000,
        'payment': 0,
        'discount': 0,
      });
      final restored = LocalLedgerStore.decodeBackup(await store.backup());
      expect(
        LocalLedgerStore.categoryTotals(restored),
        LocalLedgerStore.categoryTotals(doc),
      );
    },
  );
  test('missing description cannot create a customer or entry', () async {
    await expectLater(
      store.record(
        customerName: 'اختبار',
        type: 'debt',
        amount: '10',
        description: '  ',
      ),
      throwsFormatException,
    );
    expect((await store.current())!['customers'], isEmpty);
    expect((await store.current())!['entries'], isEmpty);
  });
  test('same request is saved once and changed payload is rejected', () async {
    final id = await store.record(
      description: 'قيد اختبار',
      customerName: 'حساب اختبار',
      type: 'debt',
      amount: '10',
      requestId: 'request-1',
    );
    expect(
      await store.record(
        description: 'قيد اختبار',
        customerName: 'حساب اختبار',
        type: 'debt',
        amount: '10',
        requestId: 'request-1',
      ),
      id,
    );
    expect(((await store.current())!['entries'] as List).length, 1);
    await expectLater(
      store.record(
        description: 'قيد اختبار',
        customerName: 'حساب اختبار',
        type: 'debt',
        amount: '20',
        requestId: 'request-1',
      ),
      throwsStateError,
    );
  });
  test(
    'chronological display preserves insertion order on equal timestamps',
    () {
      final list = [
        {'occurred_at': '2026-09-10T12:00:00Z', 'id': 1},
        {'occurred_at': '2026-09-09T12:00:00Z', 'id': 2},
        {'occurred_at': '2026-09-09T12:00:00Z', 'id': 3},
      ];
      expect(LocalLedgerStore.chronological(list).map((e) => e['id']), [
        2,
        3,
        1,
      ]);
      expect(list.first['id'], 1);
    },
  );

  test(
    'closing and reopening preserves entries and backup restores on a new device',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'muthbat-notebook-test-',
      );
      final location = '${folder.path}/notebook.db';
      final persistent = LocalLedgerStore(
        factory: databaseFactoryFfi,
        databasePath: location,
      );
      await persistent.create('بقالتي', 'SAR');
      final id = await persistent.record(
        description: 'قيد اختبار',
        customerName: 'عميل',
        type: 'debt',
        amount: '123.4567',
      );
      await (await persistent.database).close();
      final reopened = LocalLedgerStore(
        factory: databaseFactoryFfi,
        databasePath: location,
      );
      expect(
        LocalLedgerStore.balance((await reopened.current())!, id),
        1234567,
      );
      final restored = LocalLedgerStore(
        factory: databaseFactoryFfi,
        databasePath: '${folder.path}/restored.db',
      );
      await restored.restore(await reopened.backup());
      expect(await restored.current(), await reopened.current());
      await (await reopened.database).close();
      await (await restored.database).close();
    },
  );

  test(
    'first use needs no user or network and saves customer plus debt atomically',
    () async {
      final id = await store.record(
        description: 'قيد اختبار',
        customerName: 'أحمد',
        type: 'debt',
        amount: '١٢٫٣٤٥٦',
      );
      final doc = (await store.current())!;
      expect(doc['name'], 'حساباتي');
      expect(doc['owner_id'], isNull);
      expect(LocalLedgerStore.balance(doc, id), 123456);
      expect((doc['customers'] as List).length, 1);
      expect((doc['entries'] as List).length, 1);
    },
  );
  test(
    'debt payment discount and reversal keep exact balance and forbid repeat reversal',
    () async {
      final id = await store.record(
        description: 'قيد اختبار',
        customerName: 'عميل',
        type: 'debt',
        amount: '100',
      );
      await store.record(
        description: 'قيد اختبار',
        customerId: id,
        type: 'payment',
        amount: '20',
      );
      final payment = ((await store.current())!['entries'] as List).last['id'];
      await store.record(
        description: 'قيد اختبار',
        customerId: id,
        type: 'discount',
        amount: '10',
      );
      await store.reverse(payment, 'تصحيح دفعة');
      expect(LocalLedgerStore.balance((await store.current())!, id), 900000);
      await expectLater(
        store.reverse(payment, 'مرة أخرى'),
        throwsFormatException,
      );
      expect(((await store.current())!['entries'] as List).length, 4);
    },
  );
  test('failed transaction does not leave an orphan customer', () async {
    await expectLater(
      store.record(
        description: 'قيد اختبار',
        customerName: 'عميل جديد',
        type: 'discount',
        amount: '5',
      ),
      throwsFormatException,
    );
    expect((await store.current())!['customers'], isEmpty);
    expect((await store.current())!['entries'], isEmpty);
  });
  test('concurrent writes are serialized with no lost entries', () async {
    final id = await store.record(
      description: 'قيد اختبار',
      customerName: 'عميل',
      type: 'debt',
      amount: '0.0001',
    );
    await Future.wait(
      List.generate(
        20,
        (_) => store.record(
          description: 'قيد اختبار',
          customerId: id,
          type: 'debt',
          amount: '0.0001',
        ),
      ),
    );
    expect(LocalLedgerStore.balance((await store.current())!, id), 21);
  });
  test(
    'discount cannot exceed balance and negative/invalid money is rejected',
    () async {
      final id = await store.record(
        description: 'قيد اختبار',
        customerName: 'عميل',
        type: 'debt',
        amount: '1',
      );
      for (final amount in ['-1', '0', '1.00001', 'Infinity']) {
        await expectLater(
          store.record(
            description: 'قيد اختبار',
            customerId: id,
            type: 'debt',
            amount: amount,
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        store.record(
          description: 'قيد اختبار',
          customerId: id,
          type: 'discount',
          amount: '2',
        ),
        throwsFormatException,
      );
      expect(LocalLedgerStore.balance((await store.current())!, id), 10000);
    },
  );
  test('backup validates checksum and every financial reference', () async {
    await store.record(
      description: 'قيد اختبار',
      customerName: 'عميل',
      type: 'debt',
      amount: '1',
    );
    final text = await store.backup();
    final restored = LocalLedgerStore.decodeBackup(text);
    expect(restored, await store.current());
    final envelope = jsonDecode(text) as JsonMap;
    envelope['sha256'] = 'broken';
    expect(
      () => LocalLedgerStore.decodeBackup(jsonEncode(envelope)),
      throwsFormatException,
    );
    final tampered = jsonDecode(envelope['payload']) as JsonMap;
    tampered['entries'][0]['customer_id'] =
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    envelope['payload'] = jsonEncode(tampered);
    envelope['sha256'] = sha256
        .convert(utf8.encode(envelope['payload']))
        .toString();
    expect(
      () => LocalLedgerStore.decodeBackup(jsonEncode(envelope)),
      throwsFormatException,
    );
  });
  test('restore never overwrites an existing notebook', () async {
    final text = await store.backup();
    await expectLater(store.restore(text), throwsStateError);
    expect((await store.current())!['name'], 'حساباتي');
  });
  test(
    'transfer reserves account durably, freezes edits, and permits same account retry',
    () async {
      const owner = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      const other = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
      final id = await store.record(
        description: 'قيد اختبار',
        customerName: 'عميل',
        type: 'debt',
        amount: '50',
      );
      final first = await store.reserveTransfer(owner);
      expect(await store.reserveTransfer(owner), first);
      await expectLater(store.reserveTransfer(other), throwsStateError);
      await expectLater(
        store.record(
          description: 'قيد اختبار',
          customerId: id,
          type: 'debt',
          amount: '10',
        ),
        throwsStateError,
      );
      await expectLater(store.completeTransfer(other, other), throwsStateError);
      await store.completeTransfer(owner, other);
      expect((await store.current())!['transfer_state'], 'complete');
      expect(LocalLedgerStore.balance((await store.current())!, id), 500000);
    },
  );
}
