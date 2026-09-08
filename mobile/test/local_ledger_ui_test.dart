import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/features/local_ledger/local_ledger_store.dart';
import 'package:muthbat/features/local_ledger/local_ledger_screen.dart';
import 'package:muthbat/features/local_ledger/local_ledger_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('local notebook renders without Supabase and opens entry form', (
    tester,
  ) async {
    final store = LocalLedgerStore(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await tester.runAsync(() async {
      await store.create('بقالة الاختبار', 'YER');
      await store.record(customerName: 'أحمد', type: 'debt', amount: '50');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: LocalLedgerScreen(store: store),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('أحمد'), findsOneWidget);
    expect(find.text('50 YER'), findsOneWidget);
    await tester.tap(find.text('دين / دفعة'));
    await tester.pumpAndSettle();
    expect(find.text('حفظ على الجهاز'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => (await store.database).close());
  });

  test('Arabic PDF is generated locally using bundled font', () async {
    final store = LocalLedgerStore(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await store.create('بقالة مُثبَت', 'YER');
    final id = await store.record(
      customerName: 'أحمد محمد',
      type: 'debt',
      amount: '2500',
      description: 'مواد غذائية',
    );
    await store.record(
      customerId: id,
      type: 'payment',
      amount: '500',
      description: 'سداد نقدي',
    );
    final doc = (await store.current())!;
    final bytes = await localLedgerPdf(doc, JsonMap.from(doc['customers'][0]));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(bytes.length, greaterThan(1000));
    if (Platform.environment['WRITE_PDF_QA'] == '1') {
      final folder = Directory('../output/pdf');
      await folder.create(recursive: true);
      await File('${folder.path}/local-statement-qa.pdf').writeAsBytes(bytes);
    }
    await (await store.database).close();
  });
}
