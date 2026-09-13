import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/sync/presentation/rejected_operations_screen.dart';

void main() {
  testWidgets('server-rejected operation shows reason and retry action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RejectedOperationsScreen(
          loadOperations: () async => [
            {
              'client_request_id': 'a4888888-8888-4888-8888-888888888888',
              'command_type': 'create_ledger_entry',
              'payload_json': '{"p_amount":"12.3400","p_currency_code":"USD"}',
              'last_error': 'المبلغ يتجاوز الحد المسموح',
              'last_error_code': '22023',
            },
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('عمليات رفضها الخادم'), findsOneWidget);
    expect(find.text('قيد مالي مرفوض'), findsOneWidget);
    expect(find.text('المبلغ يتجاوز الحد المسموح'), findsOneWidget);
    expect(find.text('12.3400 USD'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
  });
}
