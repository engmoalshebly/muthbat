import '../../app/theme/app_document_colors.dart';
import '../../core/constants/asset_paths.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'local_ledger_store.dart';

Future<Uint8List> localLedgerPdf(JsonMap doc, JsonMap customer) async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/29LTZaridSlab-Medium.ttf'),
  );
  final pdf = pw.Document();
  final bold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/29LTZaridSlab-Bold.ttf'),
  );
  final logo = (await rootBundle.load(AssetPaths.mark)).buffer.asUint8List();
  var running = 0;
  int debits = 0, credits = 0;
  final rows = <List<String>>[];
  for (final e in LocalLedgerStore.chronological(doc['entries'] as List)) {
    if (e['customer_id'] != customer['id']) continue;
    running += e['direction'] == 'debit'
        ? e['minor'] as int
        : -(e['minor'] as int);
    if (e['direction'] == 'debit') {
      debits += e['minor'] as int;
    } else {
      credits += e['minor'] as int;
    }
    rows.add([
      LocalLedgerStore.money(running),
      e['direction'] == 'credit' ? LocalLedgerStore.money(e['minor']) : '-',
      e['direction'] == 'debit' ? LocalLedgerStore.money(e['minor']) : '-',
      e['category']?.toString() ?? 'غير مصنف',
      e['description']?.toString() ?? '—',
      '${e['direction'] == 'debit' ? 'مدين +' : 'دائن −'}\n${LocalLedgerStore.labels[e['type']] ?? e['type']}',
      LocalLedgerStore.localDate(e['occurred_at']),
      '${rows.length + 1}',
    ]);
  }
  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 200,
      margin: const pw.EdgeInsets.all(32),
      theme: pw.ThemeData.withFont(base: font, bold: bold),
      textDirection: pw.TextDirection.rtl,
      header: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'كشف حساب العميل',
                    style: pw.TextStyle(
                      fontSize: 22,
                      fontWeight: pw.FontWeight.bold,
                      color: AppDocumentColors.ink,
                    ),
                  ),
                  pw.Text(
                    '${doc['name']} • ${customer['name']}',
                    style: pw.TextStyle(
                      fontSize: 12,
                      color: AppDocumentColors.muted,
                    ),
                  ),
                  if ((customer['phone'] ?? '').toString().isNotEmpty)
                    pw.Text(
                      customer['phone'].toString(),
                      textDirection: pw.TextDirection.ltr,
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: AppDocumentColors.muted,
                      ),
                    ),
                ],
              ),
              pw.Column(
                children: [
                  pw.Image(pw.MemoryImage(logo), width: 48, height: 48),
                  pw.Text(
                    'مُثبَت',
                    style: pw.TextStyle(
                      fontSize: 15,
                      color: AppDocumentColors.primary,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.Container(height: 2, color: AppDocumentColors.primary),
          pw.SizedBox(height: 12),
        ],
      ),
      footer: (context) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 8),
        decoration: pw.BoxDecoration(
          border: pw.Border(
            top: pw.BorderSide(color: AppDocumentColors.border),
          ),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'كشف محلي • لا يحمل تحققًا سحابيًا',
              style: pw.TextStyle(fontSize: 8, color: AppDocumentColors.muted),
            ),
            pw.Text(
              '${context.pageNumber} / ${context.pagesCount}',
              style: pw.TextStyle(fontSize: 8, color: AppDocumentColors.muted),
            ),
          ],
        ),
      ),
      build: (_) => [
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            color: AppDocumentColors.background,
            border: pw.Border.all(color: AppDocumentColors.border),
            borderRadius: pw.BorderRadius.circular(8),
          ),
          child: pw.Row(
            children: [
              for (final item in [
                ('عدد الحركات', '${rows.length}', AppDocumentColors.primary),
                (
                  'إجمالي المدين',
                  '${LocalLedgerStore.money(debits)} ${doc['currency']}',
                  AppDocumentColors.debt,
                ),
                (
                  'إجمالي الدائن',
                  '${LocalLedgerStore.money(credits)} ${doc['currency']}',
                  AppDocumentColors.primary,
                ),
              ])
                pw.Expanded(
                  child: pw.Container(
                    margin: const pw.EdgeInsets.symmetric(horizontal: 3),
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 10,
                    ),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      borderRadius: pw.BorderRadius.circular(6),
                      border: pw.Border.all(color: item.$3, width: .7),
                    ),
                    child: pw.Column(
                      children: [
                        pw.Text(
                          item.$1,
                          style: pw.TextStyle(
                            fontSize: 9,
                            color: AppDocumentColors.muted,
                          ),
                        ),
                        pw.SizedBox(height: 5),
                        pw.Text(
                          item.$2,
                          style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                            color: item.$3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: [
            'الرصيد',
            'دائن',
            'مدين',
            'التصنيف',
            'الوصف',
            'النوع',
            'التاريخ',
            'م',
          ],
          data: rows,
          cellBuilder: (index, data, rowNum) {
            if (index != 5) return null;
            final lines = data.toString().split('\n');
            final color = lines.first.startsWith('مدين')
                ? AppDocumentColors.debt
                : AppDocumentColors.primary;
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 3,
                  ),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: color, width: .5),
                    borderRadius: pw.BorderRadius.circular(4),
                  ),
                  child: pw.Text(
                    lines.first,
                    style: pw.TextStyle(
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  lines.skip(1).join(' '),
                  style: pw.TextStyle(
                    fontSize: 8,
                    color: AppDocumentColors.muted,
                  ),
                ),
              ],
            );
          },
          cellStyle: pw.TextStyle(fontSize: 9, color: AppDocumentColors.ink),
          headerStyle: pw.TextStyle(
            fontSize: 10,
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
          ),
          border: pw.TableBorder(
            horizontalInside: pw.BorderSide(
              color: AppDocumentColors.border,
              width: .4,
            ),
          ),
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 5,
            vertical: 8,
          ),
          oddRowDecoration: pw.BoxDecoration(
            color: AppDocumentColors.background,
          ),
          cellAlignment: pw.Alignment.centerRight,
          headerDecoration: pw.BoxDecoration(
            color: AppDocumentColors.tableHeader,
          ),
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(.9),
            4: const pw.FlexColumnWidth(1.8),
            5: const pw.FlexColumnWidth(.8),
            6: const pw.FlexColumnWidth(1.25),
            7: const pw.FlexColumnWidth(.35),
          },
        ),
        pw.SizedBox(height: 14),
        pw.SizedBox(height: 8),
        pw.Container(
          padding: const pw.EdgeInsets.all(14),
          decoration: pw.BoxDecoration(
            color: running > 0
                ? AppDocumentColors.debt
                : running < 0
                ? AppDocumentColors.credit
                : AppDocumentColors.primary,
            borderRadius: pw.BorderRadius.circular(10),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                running > 0
                    ? 'المتبقي على العميل'
                    : running < 0
                    ? 'رصيد مقدم للعميل'
                    : 'الحساب مسدد',
                style: pw.TextStyle(fontSize: 12, color: PdfColors.white),
              ),
              pw.Text(
                '${LocalLedgerStore.money(running.abs())} ${doc['currency']}',
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 7),
        pw.Text(
          'المدين والدائن يشملان التسويات وعكس القيود • الحركات من الأقدم إلى الأحدث',
          style: pw.TextStyle(fontSize: 8, color: AppDocumentColors.muted),
        ),
      ],
    ),
  );
  return pdf.save();
}
