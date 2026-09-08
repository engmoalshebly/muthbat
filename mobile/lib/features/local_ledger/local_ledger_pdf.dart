import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'local_ledger_store.dart';

Future<Uint8List> localLedgerPdf(JsonMap doc, JsonMap customer) async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/Tajawal-Regular.ttf'),
  );
  final pdf = pw.Document();
  var running = 0;
  final rows = <List<String>>[];
  for (final e in doc['entries'] as List) {
    if (e['customer_id'] != customer['id']) continue;
    running += e['direction'] == 'debit'
        ? e['minor'] as int
        : -(e['minor'] as int);
    rows.add([
      LocalLedgerStore.money(running),
      e['direction'] == 'credit' ? LocalLedgerStore.money(e['minor']) : '-',
      e['direction'] == 'debit' ? LocalLedgerStore.money(e['minor']) : '-',
      '${LocalLedgerStore.labels[e['type']]}: ${e['description']}',
      (e['occurred_at'] as String).substring(0, 10),
    ]);
  }
  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 200,
      theme: pw.ThemeData.withFont(base: font, bold: font),
      textDirection: pw.TextDirection.rtl,
      header: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(doc['name'], style: const pw.TextStyle(fontSize: 22)),
          pw.Text('كشف حساب: ${customer['name']} - ${doc['currency']}'),
          pw.SizedBox(height: 12),
        ],
      ),
      footer: (context) => pw.Text(
        'كشف محلي - لا يحمل تحققًا سحابيًا | ${context.pageNumber} / ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 9),
      ),
      build: (_) => [
        pw.Text(
          'الرصيد: ${LocalLedgerStore.money(running)} ${doc['currency']}',
        ),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: ['الرصيد', 'له / سداد', 'عليه / دين', 'البيان', 'التاريخ'],
          data: rows,
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerStyle: const pw.TextStyle(fontSize: 10),
          cellAlignment: pw.Alignment.centerRight,
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(2.5),
            4: const pw.FlexColumnWidth(1.3),
          },
        ),
      ],
    ),
  );
  return pdf.save();
}
