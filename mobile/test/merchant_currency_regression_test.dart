import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/core/finance/currency_info.dart';
import 'package:muthbat/core/finance/money.dart';
import 'package:muthbat/features/merchant/data/local_statement_totals.dart';
import 'package:muthbat/features/merchant/data/merchant_api_exception.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';
import 'package:muthbat/features/merchant/data/models/ledger_entry_model.dart';
import 'package:muthbat/features/merchant/data/models/statement_model.dart';

LedgerEntryModel entry({
  required String id,
  required String type,
  required String direction,
  required double amount,
  required String at,
  String currency = 'SAR',
  bool reversed = false,
}) => LedgerEntryModel(
  id: id,
  businessId: 'business',
  businessCustomerId: 'customer',
  entryType: type,
  direction: direction,
  amount: amount,
  currencyCode: currency,
  description: type,
  occurredAt: at,
  clientRequestId: id,
  isReversed: reversed,
);

StatementModel statement(
  String currency, {
  String? url = 'https://example.test/a',
}) => StatementModel(
  id: currency,
  scope: 'business_customer',
  periodFrom: '2026-01-01T00:00:00Z',
  periodTo: '2026-02-01T00:00:00Z',
  currencyCode: currency,
  openingBalance: 0,
  totalDebits: 0,
  totalCredits: 0,
  closingBalance: 0,
  verificationCode: currency,
  downloadUrl: url,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'offline statement retains both original and reversal at period boundaries',
    () {
      final entries = [
        entry(
          id: 'debt',
          type: 'debt',
          direction: 'debit',
          amount: 100.25,
          at: '2026-01-02T00:00:00Z',
          reversed: true,
        ),
        entry(
          id: 'reverse',
          type: 'reversal',
          direction: 'credit',
          amount: 100.25,
          at: '2026-01-10T00:00:00Z',
        ),
        entry(
          id: 'other-currency',
          type: 'debt',
          direction: 'debit',
          amount: 5,
          at: '2026-01-03T00:00:00Z',
          currency: 'YER',
        ),
      ];
      LocalStatementTotals totals(DateTime from, DateTime to) =>
          LocalStatementTotals.calculate(
            entries: entries,
            from: from,
            to: to,
            currencyCode: 'SAR',
          );
      final before = totals(
        DateTime.utc(2026, 1, 1),
        DateTime.utc(2026, 1, 10),
      );
      expect(before.debits.toDecimalString(), '100.2500');
      expect(before.credits.toDecimalString(), '0.0000');
      expect(before.closing.toDecimalString(), '100.2500');

      final after = totals(
        DateTime.utc(2026, 1, 10),
        DateTime.utc(2026, 1, 11),
      );
      expect(after.opening.toDecimalString(), '100.2500');
      expect(after.credits.toDecimalString(), '100.2500');
      expect(after.closing.toDecimalString(), '0.0000');
    },
  );

  test(
    'combined statement rejects missing, mismatched and offline currencies',
    () {
      expect(
        () => MerchantRepository.requireCompleteStatements(
          ['YER', 'SAR'],
          [statement('YER'), null],
        ),
        throwsA(isA<MerchantApiException>()),
      );
      expect(
        () => MerchantRepository.requireCompleteStatements(
          ['YER', 'SAR'],
          [statement('YER'), statement('USD')],
        ),
        throwsA(isA<MerchantApiException>()),
      );
      expect(
        () => MerchantRepository.requireCompleteStatements(
          ['YER', 'SAR'],
          [statement('YER'), statement('SAR', url: null)],
        ),
        throwsA(isA<MerchantApiException>()),
      );
      expect(
        MerchantRepository.requireCompleteStatements(
          ['YER', 'SAR'],
          [statement('YER'), statement('SAR')],
        ).length,
        2,
      );
      final bundle = statement('YER').copyWith(
        downloadUrl: 'https://example.test/combined.pdf',
        combinedStatements: [statement('YER'), statement('SAR')],
      );
      expect(bundle.combinedStatements.map((item) => item.currencyCode), [
        'YER',
        'SAR',
      ]);
    },
  );

  test('amount precision follows the selected currency', () {
    for (final (code, amount) in [('USD', '1.001'), ('JPY', '1.5')]) {
      expect(
        () => Money.fromCurrencyText(
          amount,
          decimalScale: CurrencyCatalog.forCode(code).decimalScale,
        ),
        throwsFormatException,
      );
    }
    expect(
      Money.fromCurrencyText(
        '1.234',
        decimalScale: CurrencyCatalog.forCode('KWD').decimalScale,
      ).toDecimalString(),
      '1.2340',
    );
  });

  test(
    'offline SAR reversal updates SAR only and blocks a duplicate',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final folder = await Directory.systemTemp.createTemp(
        'merchant-reversal-',
      );
      await databaseFactoryFfi.setDatabasesPath(folder.path);
      final store = AppDatabase.instance;
      const owner = 'abbb0000-0000-0000-0000-000000000001';
      const originalId = 'abbb0000-0000-0000-0000-000000000002';
      await store.bindAccount(owner);
      final db = await store.database;
      await db.insert('local_businesses', {
        'id': 'business',
        'owner_user_id': owner,
        'name': 'Store',
        'currency_code': 'YER',
      });
      await db.insert('local_business_customers', {
        'id': 'customer',
        'business_id': 'business',
        'local_display_name': 'Customer',
      });
      await db.insert('local_ledger_entries', {
        ...entry(
          id: originalId,
          type: 'payment',
          direction: 'credit',
          amount: 12.5,
          at: '2026-01-01T00:00:00Z',
        ).toMap(),
        'sync_status': 'synced',
      });
      await db.insert('local_customer_currency_balances', {
        'id': 'bal-customer-SAR',
        'business_id': 'business',
        'business_customer_id': 'customer',
        'currency_code': 'SAR',
        'current_balance': -12.5,
        'current_balance_minor': -125000,
        'total_credits': 12.5,
        'total_credits_minor': 125000,
      });
      final repository = MerchantRepository(requestSync: () {});
      final queueBeforeInvalidAmount = (await db.query(
        'offline_mutations_queue',
      )).length;
      await expectLater(
        repository.createLedgerEntry(
          businessId: 'business',
          businessCustomerId: 'customer',
          entryType: 'debt',
          amount: 1.001,
          description: 'invalid precision',
          currencyCode: 'USD',
        ),
        throwsA(isA<MerchantApiException>()),
      );
      expect(
        (await db.query('offline_mutations_queue')).length,
        queueBeforeInvalidAmount,
      );
      await repository.reverseLedgerEntry(
        businessId: 'business',
        originalEntryId: originalId,
        businessCustomerId: 'customer',
        originalEntryType: 'payment',
        originalDirection: 'credit',
        originalAmount: 12.5,
        reason: 'correction',
        currencyCode: 'SAR',
      );
      final sar = await db.query(
        'local_customer_currency_balances',
        where: 'business_customer_id = ? AND currency_code = ?',
        whereArgs: ['customer', 'SAR'],
      );
      expect(sar.single['current_balance_minor'], 0);
      expect(
        await db.query(
          'local_customer_currency_balances',
          where: 'currency_code = ?',
          whereArgs: ['YER'],
        ),
        isEmpty,
      );
      expect(
        (await db.query(
          'local_ledger_entries',
          where: 'id = ?',
          whereArgs: [originalId],
        )).single['is_reversed'],
        1,
      );
      final reportRows = await store.getBusinessLedgerEntriesSince(
        'business',
        DateTime.utc(2025, 12, 31),
      );
      expect(reportRows.length, 2);
      expect(reportRows.first['entry_type'], 'reversal');
      await expectLater(
        repository.reverseLedgerEntry(
          businessId: 'business',
          originalEntryId: originalId,
          businessCustomerId: 'customer',
          originalEntryType: 'payment',
          originalDirection: 'credit',
          originalAmount: 12.5,
          reason: 'duplicate',
          currencyCode: 'SAR',
        ),
        throwsStateError,
      );
      await store.lockAccount();
      await folder.delete(recursive: true);
    },
  );
}
