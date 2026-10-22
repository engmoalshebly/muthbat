import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/customer/data/customer_cache.dart';
import 'package:muthbat/features/customer/data/customer_local_store.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/data/models/customer_summary_model.dart';
import 'package:muthbat/features/notifications/notification_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'e1950000-0000-0000-0000-000000000001';
  const other = 'e1950000-0000-0000-0000-000000000002';
  final db = AppDatabase.instance;
  final local = CustomerLocalStore();
  final notices = NotificationRepository();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp(
      'customer-local-first-',
    );
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    await db.bindAccount(owner);
  });
  tearDownAll(() => db.lockAccount());

  CustomerReadSnapshot snapshot(
    String date, {
    List<Map<String, dynamic>>? entries,
    bool linked = true,
  }) => CustomerReadSnapshot(
    customerId: 'customer',
    updatedAt: date,
    summaries: [
      if (linked)
        const CustomerBusinessSummary(
          businessCustomerId: 'relationship',
          businessId: 'business',
          businessName: 'متجري',
          currencyCode: 'YER',
          currentBalance: 50,
          entryCount: 2,
        ),
    ],
    requests: const [],
    entries: entries ?? const [],
  );
  Map<String, dynamic> entry(String id, String currency) => {
    'id': id,
    'business_customer_id': 'relationship',
    'currency_code': currency,
    'occurred_at': '2026-10-21T10:00:00Z',
    'amount': 25,
  };

  test(
    'complete ledger survives restart; invalid replacement rolls back; newer home wins',
    () async {
      await local.saveHome(owner, snapshot('2026-10-21T10:00:00Z'));
      expect(await local.coverage(owner), (ready: 0, total: 1));
      await local.saveLedger(
        owner,
        snapshot(
          '2026-10-21T10:01:00Z',
          entries: [entry('first', 'YER'), entry('second', 'YER')],
        ),
        relationship: 'relationship',
        currency: 'YER',
      );
      await db.lockAccount();
      await db.bindAccount(owner);
      expect(await local.coverage(owner), (ready: 1, total: 1));
      expect(
        (await local.ledger(owner, 'relationship', 'YER'))!.entries,
        hasLength(2),
      );
      expect(
        (await local.summary(owner, 'relationship', 'YER'))!.businessName,
        'متجري',
      );
      await expectLater(
        local.saveLedger(
          owner,
          snapshot('2026-10-21T10:02:00Z', entries: [entry('wrong', 'USD')]),
          relationship: 'relationship',
          currency: 'YER',
        ),
        throwsStateError,
      );
      // Failure mid-transaction must retain both rows and the completion marker.
      await expectLater(
        local.saveLedger(
          owner,
          snapshot(
            '2026-10-21T10:02:00Z',
            entries: [entry('duplicate', 'YER'), entry('duplicate', 'YER')],
          ),
          relationship: 'relationship',
          currency: 'YER',
        ),
        throwsA(anything),
      );
      expect(
        (await local.ledger(
          owner,
          'relationship',
          'YER',
        ))!.entries.map((e) => e['id']),
        ['second', 'first'],
      );
      await local.saveHome(
        owner,
        snapshot('2026-10-21T09:00:00Z', linked: false),
      );
      expect(
        (await CustomerCache().read(owner, 'home'))!['summaries'],
        hasLength(1),
      );
      await local.saveHome(
        owner,
        snapshot('2026-10-21T11:00:00Z', linked: false),
      );
      expect(await local.ledger(owner, 'relationship', 'YER'), isNull);
      expect(await local.entry(owner, 'first'), isNull);
    },
  );

  Map<String, dynamic> notice(String id, String workspace) => {
    'id': id,
    'user_id': owner,
    'title': 'إشعار',
    'body': 'نص',
    'created_at': '2026-10-21T10:00:00Z',
    'read_at': null,
    'data': {'workspace': workspace},
  };
  test(
    'workspace-specific read receipts survive restart and stale server merges',
    () async {
      await notices.merge(owner, [
        notice('customer', 'customer'),
        notice('merchant', 'merchant'),
      ]);
      expect(await notices.unread(owner, 'customer'), 1);
      await notices.markRead(owner, 'customer');
      await db.lockAccount();
      await db.bindAccount(owner);
      await notices.merge(owner, [notice('customer', 'customer')]);
      expect(await notices.unread(owner, 'customer'), 0);
      expect(await notices.unread(owner, 'merchant'), 1);
      final connection = await db.database;
      expect(
        (await connection.query(
          'local_notifications',
          where: 'id=?',
          whereArgs: ['customer'],
        )).single['pending_read'],
        1,
      );
      await notices.savePreference(owner, 'push_enabled', false);
      await db.lockAccount();
      await db.bindAccount(owner);
      expect((await notices.preferences(owner))['push_enabled'], false);
      await expectLater(
        notices.merge(owner, [
          {...notice('alien', 'customer'), 'user_id': other},
        ]),
        throwsStateError,
      );
      expect(await notices.find(owner, 'alien'), isNull);
    },
  );

  test(
    'locked and different accounts cannot read local customer data or notifications',
    () async {
      await local.saveHome(owner, snapshot('2026-10-21T12:00:00Z'));
      await db.lockAccount();
      await expectLater(notices.list(owner, 'customer'), throwsStateError);
      await db.bindAccount(other);
      expect(await notices.list(other, 'customer'), isEmpty);
      expect(await local.summary(other, 'relationship', 'YER'), isNull);
      await expectLater(
        local.summary(owner, 'relationship', 'YER'),
        throwsStateError,
      );
      await db.bindAccount(owner);
      expect(await notices.list(owner, 'customer'), hasLength(1));
      expect(await local.summary(owner, 'relationship', 'YER'), isNotNull);
    },
  );
}
