import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/customer/data/customer_ledger_pdf.dart';
import 'package:muthbat/features/customer/data/models/customer_summary_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const summary = CustomerBusinessSummary(
    businessCustomerId: 'a',
    businessId: 'b',
    businessName: 'بقالة الأمانة - عدن',
    currencyCode: 'YER',
    currentBalance: 20,
    entryCount: 1,
  );
  final row = <String, dynamic>{
    'id': 'e',
    'business_customer_id': 'a',
    'entry_type': 'debt',
    'direction': 'debit',
    'amount': 1200,
    'currency_code': 'YER',
    'description': 'مواد غذائية للأسرة',
    'occurred_at': '2026-09-08T12:00:00Z',
    'confirmation_status': 'pending',
  };
  test('customer PDF generates offline and refuses mixed currencies', () async {
    final bytes = await customerLedgerPdf(
      summary: summary,
      entries: [row],
      updatedAt: '2026-09-08 12:00 UTC',
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    await expectLater(
      customerLedgerPdf(
        summary: summary,
        entries: [
          {...row, 'currency_code': 'SAR'},
        ],
        updatedAt: 'today',
      ),
      throwsArgumentError,
    );
    await expectLater(
      customerLedgerPdf(
        summary: summary,
        entries: [
          {...row, 'business_customer_id': 'other'},
        ],
        updatedAt: 'today',
      ),
      throwsArgumentError,
    );
    if (Platform.environment['WRITE_PDF_QA'] == '1') {
      await File('../output/pdf/customer-statement-qa.pdf').writeAsBytes(bytes);
    }
  });
}
