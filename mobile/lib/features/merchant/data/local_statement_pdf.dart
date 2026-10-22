import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'models/statement_model.dart';
import '../../../core/finance/money.dart';

/// Renders the same immutable local rows used to calculate the preview totals.
Future<Uint8List> localStatementPdf(
  StatementModel statement,
  String customer,
) async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/29LTZaridSlab-Medium.ttf'),
  );
  final pdf = pw.Document();
  final statements = statement.combinedStatements.isEmpty
      ? [statement]
      : statement.combinedStatements;
  for (final item in statements) {
    if (item.localEntries.any(
      (e) =>
          e['currency_code'] != item.currencyCode ||
          e['business_customer_id'] != item.businessCustomerId,
    )) {
      throw StateError('الكشف يحتوي عملية لحساب أو عملة مختلفة');
    }
    String amount(num value) => Money.fromNum(value).toDecimalString();
    pdf.addPage(
      pw.MultiPage(
        maxPages: item.localEntries.length + 10,
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: font, bold: font),
        textDirection: pw.TextDirection.rtl,
        build: (_) => [
          pw.Text('كشف حساب • $customer', style: pw.TextStyle(fontSize: 20)),
          pw.Text('العملة: ${item.currencyCode}'),
          pw.Text(
            'الفترة: ${item.periodFrom.substring(0, 10)} إلى ${item.periodTo.substring(0, 10)}',
          ),
          pw.Text('نسخة من بيانات الجهاز • ليست نسخة موثقة من الخادم'),
          pw.SizedBox(height: 12),
          pw.Text('رصيد البداية: ${amount(item.openingBalance)}'),
          pw.Text(
            'مدين: ${amount(item.totalDebits)} • دائن: ${amount(item.totalCredits)}',
          ),
          pw.Text('رصيد النهاية: ${amount(item.closingBalance)}'),
          pw.SizedBox(height: 12),
          if (item.localEntries.isEmpty)
            pw.Text('لا توجد حركات خلال الفترة المحددة.'),
          if (item.localEntries.isNotEmpty)
            pw.TableHelper.fromTextArray(
              headers: ['دائن', 'مدين', 'الوصف', 'التاريخ'],
              data: item.localEntries
                  .map(
                    (e) => [
                      e['direction'] == 'credit'
                          ? amount(e['amount'] as num)
                          : '-',
                      e['direction'] != 'credit'
                          ? amount(e['amount'] as num)
                          : '-',
                      e['description']?.toString() ?? '',
                      e['occurred_at'].toString().substring(0, 10),
                    ],
                  )
                  .toList(),
              cellStyle: const pw.TextStyle(fontSize: 9),
            ),
        ],
      ),
    );
  }
  return pdf.save();
}
