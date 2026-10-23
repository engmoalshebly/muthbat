@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/features/local_ledger/local_ledger_store.dart';
import 'package:muthbat/features/local_ledger/local_transfer_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const owner = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  test(
    'backup failure leaves notebook editable and a stale review cannot freeze it',
    () async {
      final store = LocalLedgerStore(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(() async => (await store.database).close());
      await store.create('دفتر اختبار', 'YER');
      final snapshot = (await store.current())!;
      final folder = await Directory.systemTemp.createTemp('transfer-failure-');
      final blocker = File('${folder.path}/blocked');
      await blocker.writeAsString('not a directory');
      await expectLater(
        ensureLocalTransferBackup(
          snapshot: snapshot,
          directory: Directory(blocker.path),
          password: 'secret',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.current())!['transfer_state'], 'local');
      await store.record(
        customerName: 'عميل',
        description: 'عملية جديدة',
        type: 'debt',
        amount: '10',
      );
      await expectLater(
        store.reserveTransfer(owner, expectedSnapshot: snapshot),
        throwsStateError,
      );
      expect((await store.current())!['transfer_state'], 'local');
    },
  );
  test(
    'verified backup survives retry and a corrupt file is replaced before reservation',
    () async {
      final store = LocalLedgerStore(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(() async => (await store.database).close());
      await store.create('دفتر اختبار', 'YER');
      final snapshot = (await store.current())!;
      final directory = await Directory.systemTemp.createTemp(
        'transfer-backup-',
      );
      final file = await ensureLocalTransferBackup(
        snapshot: snapshot,
        directory: directory,
        password: 'strong-secret',
      );
      final original = await file.readAsString();
      expect(
        await (await ensureLocalTransferBackup(
          snapshot: snapshot,
          directory: directory,
          password: 'strong-secret',
        )).readAsString(),
        original,
      );
      await file.writeAsString('{broken');
      final repaired = await ensureLocalTransferBackup(
        snapshot: snapshot,
        directory: directory,
        password: 'strong-secret',
      );
      expect(
        LocalLedgerStore.looksLikeEncryptedBackup(
          await repaired.readAsString(),
        ),
        isTrue,
      );
      expect((await store.current())!['transfer_state'], 'local');
      await store.reserveTransfer(owner, expectedSnapshot: snapshot);
      await store.markTransferCheckpoint(
        owner,
        'backup_created',
        notebookId: snapshot['id'],
      );
      expect((await store.current())!['transfer_checkpoint'], 'backup_created');
    },
  );
}
