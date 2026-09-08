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

  test('closing and reopening preserves entries and backup restores on a new device', () async {
    final folder = await Directory.systemTemp.createTemp('muthbat-notebook-test-');
    final location = '${folder.path}/notebook.db';
    final persistent = LocalLedgerStore(factory: databaseFactoryFfi, databasePath: location);
    await persistent.create('بقالتي', 'SAR');
    final id = await persistent.record(customerName: 'عميل', type: 'debt', amount: '123.4567');
    await (await persistent.database).close();
    final reopened = LocalLedgerStore(factory: databaseFactoryFfi, databasePath: location);
    expect(LocalLedgerStore.balance((await reopened.current())!, id), 1234567);
    final restored = LocalLedgerStore(factory: databaseFactoryFfi, databasePath: '${folder.path}/restored.db');
    await restored.restore(await reopened.backup());
    expect(await restored.current(), await reopened.current());
    await (await reopened.database).close();
    await (await restored.database).close();
  });

  test(
    'first use needs no user or network and saves customer plus debt atomically',
    () async {
      final id = await store.record(
        customerName: 'أحمد',
        type: 'debt',
        amount: '١٢٫٣٤٥٦',
      );
      final doc = (await store.current())!;
      expect(doc['name'], 'بقالتي');
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
        customerName: 'عميل',
        type: 'debt',
        amount: '100',
      );
      await store.record(customerId: id, type: 'payment', amount: '20');
      final payment = ((await store.current())!['entries'] as List).last['id'];
      await store.record(customerId: id, type: 'discount', amount: '10');
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
      store.record(customerName: 'عميل جديد', type: 'discount', amount: '5'),
      throwsFormatException,
    );
    expect((await store.current())!['customers'], isEmpty);
    expect((await store.current())!['entries'], isEmpty);
  });
  test('concurrent writes are serialized with no lost entries', () async {
    final id = await store.record(
      customerName: 'عميل',
      type: 'debt',
      amount: '0.0001',
    );
    await Future.wait(
      List.generate(
        20,
        (_) => store.record(customerId: id, type: 'debt', amount: '0.0001'),
      ),
    );
    expect(LocalLedgerStore.balance((await store.current())!, id), 21);
  });
  test(
    'discount cannot exceed balance and negative/invalid money is rejected',
    () async {
      final id = await store.record(
        customerName: 'عميل',
        type: 'debt',
        amount: '1',
      );
      for (final amount in ['-1', '0', '1.00001', 'Infinity']) {
        await expectLater(
          store.record(customerId: id, type: 'debt', amount: amount),
          throwsFormatException,
        );
      }
      await expectLater(
        store.record(customerId: id, type: 'discount', amount: '2'),
        throwsFormatException,
      );
      expect(LocalLedgerStore.balance((await store.current())!, id), 10000);
    },
  );
  test('backup validates checksum and every financial reference', () async {
    await store.record(customerName: 'عميل', type: 'debt', amount: '1');
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
    expect((await store.current())!['name'], 'بقالتي');
  });
  test(
    'transfer reserves account durably, freezes edits, and permits same account retry',
    () async {
      const owner = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      const other = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
      final id = await store.record(
        customerName: 'عميل',
        type: 'debt',
        amount: '50',
      );
      final first = await store.reserveTransfer(owner);
      expect(await store.reserveTransfer(owner), first);
      await expectLater(store.reserveTransfer(other), throwsStateError);
      await expectLater(
        store.record(customerId: id, type: 'debt', amount: '10'),
        throwsStateError,
      );
      await expectLater(store.completeTransfer(other, other), throwsStateError);
      await store.completeTransfer(owner, other);
      expect((await store.current())!['transfer_state'], 'complete');
      expect(LocalLedgerStore.balance((await store.current())!, id), 500000);
    },
  );
}
