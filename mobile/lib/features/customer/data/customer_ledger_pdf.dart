import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'models/customer_summary_model.dart';

/// Export only the displayed snapshot; never infer a complete/current balance
/// from a partial page or combine currencies into one financial total.
Future<Uint8List> customerLedgerPdf({
  required CustomerBusinessSummary summary,
  required List<Map<String, dynamic>> entries,
  required String updatedAt,
}) async {
  if (entries.isEmpty) throw ArgumentError('لا توجد حركات محمّلة للتصدير');
  if (entries.any(
    (e) =>
        e['business_customer_id'] != summary.businessCustomerId ||
        e['currency_code'] != summary.currencyCode,
  )) {
    throw ArgumentError('لا يمكن خلط حسابات البقالات أو العملات في هذا الكشف');
  }
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/Tajawal-Regular.ttf'),
  );
  final document = pw.Document();
  const labels = {
    'opening_balance': 'رصيد افتتاحي',
    'debt': 'دين',
    'payment': 'دفعة',
    'discount': 'خصم',
    'reversal': 'عكس',
  };
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 200,
      theme: pw.ThemeData.withFont(base: font, bold: font),
      textDirection: pw.TextDirection.rtl,
      header: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            summary.businessName,
            style: const pw.TextStyle(fontSize: 22),
          ),
          pw.Text('حركات حساب الزبون - ${summary.currencyCode}'),
          pw.SizedBox(height: 12),
        ],
      ),
      footer: (context) => pw.Text(
        'نسخة محلية للحركات المحملة فقط - ليست إقرارًا بالدين | ${context.pageNumber} / ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 9),
      ),
      build: (_) => [
        pw.Text('آخر تحديث للبيانات: $updatedAt'),
        pw.Text(
          'عدد الحركات المصدرة: ${entries.length}. قد توجد حركات أخرى لم تُحمّل أو تغيّرت بعد التحديث.',
        ),
        pw.SizedBox(height: 14),
        pw.TableHelper.fromTextArray(
          headers: ['الحالة', 'له / دائن', 'عليه / مدين', 'البيان', 'التاريخ'],
          data: entries.map((e) {
            final entry = CustomerPendingEntry.fromMap(e);
            final date =
                DateTime.tryParse(
                  entry.occurredAt,
                )?.toLocal().toIso8601String().substring(0, 10) ??
                '-';
            final status = e['is_reversed'] == true
                ? 'معكوسة'
                : e['dispute_status'] == 'open'
                ? 'اعتراض مفتوح'
                : e['confirmation_status'] == 'confirmed'
                ? 'مؤكدة'
                : 'غير مؤكدة';
            return [
              status,
              entry.direction == 'credit' ? '${entry.amount}' : '-',
              entry.direction == 'debit' ? '${entry.amount}' : '-',
              '${labels[entry.entryType] ?? entry.entryType}: ${entry.description}',
              date,
            ];
          }).toList(),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerStyle: const pw.TextStyle(fontSize: 10),
          cellAlignment: pw.Alignment.centerRight,
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          columnWidths: {
            0: const pw.FlexColumnWidth(1.2),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(2.5),
            4: const pw.FlexColumnWidth(1.3),
          },
        ),
      ],
    ),
  );
  return document.save();
}
