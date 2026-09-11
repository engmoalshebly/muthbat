import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/data/models/customer_summary_model.dart';
import 'package:muthbat/features/customer/presentation/screens/customer_account_ledger_screen.dart';

class LedgerRepository extends CustomerRepository {
  final offsets = <int>[];
  @override
  String? get userId => 'test-owner';
  @override
  Future<List<Map<String, dynamic>>> fetchLedgerPage({
    required String businessCustomerId,
    required String currency,
    required int offset,
  }) async {
    expect(businessCustomerId, 'relationship-a');
    expect(currency, 'YER');
    offsets.add(offset);
    return List.generate(
      offset == 0 ? 50 : 1,
      (i) => {
        'id': 'entry-${offset + i}',
        'business_customer_id': 'relationship-a',
        'entry_type': 'debt',
        'direction': 'debit',
        'amount': 20,
        'currency_code': 'YER',
        'description': 'حركة ${offset + i}',
        'occurred_at': '2026-09-08T12:00:00Z',
        'confirmation_status': 'pending',
        'dispute_status': 'none',
        'is_reversed': false,
      },
    );
  }
}

void main() {
  testWidgets(
    'ledger requests only the selected relationship and currency and loads older pages',
    (tester) async {
      final repository = LedgerRepository();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: CustomerAccountLedgerScreen(
              repository: repository,
              summary: const CustomerBusinessSummary(
                businessCustomerId: 'relationship-a',
                businessId: 'shop-a',
                businessName: 'بقالتي',
                currencyCode: 'YER',
                currentBalance: 100,
                entryCount: 51,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.offsets, [0]);
      final older = find.text('تحميل حركات أقدم');
      await tester.scrollUntilVisible(older, 600, maxScrolls: 30,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
      await tester.pumpAndSettle();
      await tester.tap(older);
      await tester.pumpAndSettle();
      expect(repository.offsets, [0, 50]);
      expect(find.text('تحميل حركات أقدم'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
