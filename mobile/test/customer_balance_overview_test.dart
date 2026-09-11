import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/features/customer/data/models/customer_summary_model.dart';
import '../lib/features/customer/presentation/screens/customer_balance_overview.dart';

void main() {
  testWidgets('personal overview separates credit and debt across currencies', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CustomerBalanceOverview(summaries: [
      for (final row in [('a', 'YER', 100.0), ('b', 'YER', -20.0), ('a', 'SAR', 5.0)])
        CustomerBusinessSummary(businessCustomerId: row.$1, businessId: row.$1, businessName: row.$1, currencyCode: row.$2, currentBalance: row.$3, entryCount: 1),
    ]))));
    expect(find.text('100 YER'), findsOneWidget);
    expect(find.text('20 YER'), findsOneWidget);
    expect(find.text('5 SAR'), findsOneWidget);
    expect(find.text('2 بقالات مرتبطة بحسابك'), findsOneWidget);
    expect(find.text('80 YER'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
