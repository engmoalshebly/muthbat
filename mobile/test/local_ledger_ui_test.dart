import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/features/local_ledger/local_ledger_store.dart';
import 'package:muthbat/features/local_ledger/local_ledger_screen.dart';
import 'package:muthbat/features/local_ledger/local_ledger_pdf.dart';
import 'package:muthbat/app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('local notebook renders without Supabase and opens entry form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalLedgerStore(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await tester.runAsync(() async {
      await store.create('بقالة الاختبار', 'YER');
      await store.record(
        description: 'قيد اختبار',
        customerName: 'أحمد',
        type: 'debt',
        amount: '50',
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
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
    expect(find.text('دفتر حساب شخصي'), findsOneWidget);
    await tester.tap(find.text('العملاء').last);
    await tester.pumpAndSettle();
    expect(find.text('أحمد'), findsOneWidget);
    expect(find.text('50 YER'), findsOneWidget);
    await tester.tap(find.text('مسددون'));
    await tester.pumpAndSettle();
    expect(find.text('أحمد'), findsNothing);
    expect(find.text('لا توجد نتائج في هذه القائمة'), findsOneWidget);
    await tester.tap(find.text('الكل'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'غير موجود');
    await tester.pumpAndSettle();
    expect(find.text('أحمد'), findsNothing);
    await tester.enterText(find.byType(TextField), 'أحمد');
    await tester.pumpAndSettle();
    await tester.tap(find.text('أحمد').last);
    await tester.pumpAndSettle();
    expect(find.text('المتبقي على العميل'), findsOneWidget);
    expect(find.byTooltip('مشاركة كشف PDF'), findsOneWidget);
    expect(find.byTooltip('عكس العملية'), findsNothing);
    await tester.tap(find.text('دفعات'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد نتائج في هذه القائمة'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('التقارير'));
    await tester.pumpAndSettle();
    expect(find.text('إجمالي المستحق لك'), findsOneWidget);
    expect(find.text('أحمد'), findsNothing);
    await tester.tap(find.byTooltip('الحساب'));
    await tester.pumpAndSettle();
    expect(find.text('انتقل إلى حساب تاجر، بنفس بياناتك'), findsOneWidget);
    await tester.tap(find.text('كيف أنقل دفتري؟'));
    await tester.pumpAndSettle();
    expect(find.text('مراجعة الدفتر وتأكيد نقله'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العملاء').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('دين / دفعة'));
    await tester.pumpAndSettle();
    expect(find.text('حفظ على الجهاز'), findsOneWidget);
    await tester.ensureVisible(find.text('حفظ على الجهاز'));
    await tester.tap(find.text('حفظ على الجهاز'));
    await tester.pumpAndSettle();
    expect(find.text('أدخل وصف العملية قبل الحفظ'), findsOneWidget);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('إلغاء'));
    await tester.pumpAndSettle();
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('التقارير'));
    await tester.pumpAndSettle();
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
      category: 'مشتريات المنزل',
    );
    await store.record(
      customerId: id,
      type: 'payment',
      amount: '500',
      description: 'سداد نقدي',
      category: 'دفعات نقدية',
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
