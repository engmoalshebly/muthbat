import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' as sq;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/customer/data/customer_outbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'customer outbox survives restart, deduplicates, rejects conflicting actions and isolates accounts',
    () async {
      sqfliteFfiInit();
      sq.databaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'muthbat-outbox-test-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final db = AppDatabase.instance;
      final box = CustomerOutbox();
      const a = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      const b = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
      const payload = {
        'kind': 'confirm',
        'target_id': 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
      };
      await db.bindAccount(a);
      final id = await box.enqueue(a, payload);
      expect(await box.enqueue(a, payload), id);
      await expectLater(
        box.enqueue(a, {...payload, 'kind': 'dispute'}),
        throwsStateError,
      );
      await db.lockAccount();
      await db.bindAccount(b);
      expect(await box.list(b), isEmpty);
      await expectLater(box.list(a), throwsStateError);
      await db.lockAccount();
      await db.bindAccount(a);
      expect((await box.list(a)).single['id'], id);
      await box.fail(a, id, 'رفض الخادم');
      expect((await box.list(a)).single['status'], 'failed');
      await box.retry(a, id);
      expect((await box.list(a)).single['id'], id);
      expect((await box.list(a)).single['status'], 'pending');
      await box.complete(a, id);
      expect(await box.list(a), isEmpty);
      await db.lockAccount();
    },
  );
}
