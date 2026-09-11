import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../lib/features/customer/presentation/screens/customer_entry_details_screen.dart';

void main() {
  testWidgets('customer receipt displays status without merchant controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(
        home: CustomerEntryDetailsScreen(
          businessName: 'بقالة الاختبار',
          entry: {
            'id': 'receipt-1',
            'entry_type': 'payment',
            'amount': 25,
            'currency_code': 'YER',
            'description': 'سداد حساب',
            'occurred_at': '2026-09-11T10:00:00Z',
            'confirmation_status': 'pending',
            'dispute_status': 'open',
          },
        ),
      )),
    );
    expect(find.text('بقالة الاختبار'), findsOneWidget);
    expect(find.text('25 YER'), findsOneWidget);
    expect(find.text('سداد حساب'), findsOneWidget);
    expect(find.text('تعديل'), findsNothing);
    expect(find.text('حذف'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
