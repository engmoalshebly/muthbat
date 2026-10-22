import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/features/merchant/data/merchant_repository.dart';
import 'package:muthbat/features/merchant/data/models/dispute_model.dart';
import 'package:muthbat/features/merchant/presentation/controllers/merchant_controller.dart';
import 'package:muthbat/features/merchant/presentation/widgets/resolve_dispute_sheet.dart';
import 'package:muthbat/shared/widgets/custom_button.dart';

class _Decisions extends MerchantController {
  _Decisions() : super(MerchantRepository(), requestSync: () {});
  final decisions = <Map<String, dynamic>>[];
  @override
  Future<bool> resolveDispute({
    required String disputeId,
    required String resolution,
    required String note,
    double? correctedAmount,
  }) async {
    decisions.add({
      'id': disputeId,
      'resolution': resolution,
      'note': note,
      'amount': correctedAmount,
    });
    return false; // Keep the sheet open without sending any real command.
  }
}

void main() {
  late _Decisions controller;
  Future<void> open(WidgetTester tester, {double? amount = 100}) async {
    await tester.binding.setSurfaceSize(const Size(480, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    controller = _Decisions();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          merchantControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: ResolveDisputeSheet(
                dispute: DisputeModel(
                  id: 'dispute',
                  entryId: 'entry',
                  businessId: 'business',
                  customerId: 'customer',
                  reason: 'wrong_amount',
                  description: 'المبلغ غير صحيح',
                  entryAmount: amount,
                  currencyCode: 'SAR',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> review(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('dispute-review')));
    await tester.tap(find.byKey(const Key('dispute-review')));
    await tester.pumpAndSettle();
  }

  Future<void> note(WidgetTester tester) => tester.enterText(
    find.byKey(const Key('dispute-decision-note')),
    'المبلغ المتفق عليه',
  );

  testWidgets('no destructive decision is selected by default', (tester) async {
    await open(tester);
    expect(
      tester
          .widget<CustomButton>(find.byKey(const Key('dispute-review')))
          .onPressed,
      isNull,
    );
    expect(controller.decisions, isEmpty);
  });
  testWidgets(
    'corrected Arabic amount uses entry currency and needs confirmation',
    (tester) async {
      await open(tester);
      await tester.tap(find.text('قبول الاعتراض وتصحيح المبلغ'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('dispute-corrected-amount')),
        '٨٠٫٥',
      );
      await note(tester);
      await review(tester);
      expect(find.text('المبلغ بعد التصحيح: 80.5 SAR'), findsWidgets);
      expect(controller.decisions, isEmpty);
      await tester.tap(find.text('العودة للتعديل'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('dispute-corrected-amount')),
            )
            .controller!
            .text,
        '٨٠٫٥',
      );
      await review(tester);
      await tester.tap(find.text('تأكيد وحفظ القرار'));
      await tester.pumpAndSettle();
      expect(controller.decisions.single['resolution'], 'partially_accepted');
      expect(controller.decisions.single['amount'], 80.5);
      await tester.pump(const Duration(seconds: 5));
    },
  );
  testWidgets('zero equal and larger amounts cannot reach confirmation', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('قبول الاعتراض وتصحيح المبلغ'));
    await tester.pumpAndSettle();
    await note(tester);
    for (final value in ['0', '100', '120', '-5']) {
      await tester.enterText(
        find.byKey(const Key('dispute-corrected-amount')),
        value,
      );
      await review(tester);
      expect(find.byType(AlertDialog), findsNothing);
    }
    expect(controller.decisions, isEmpty);
  });
  testWidgets('cancellation ignores an amount entered for a different choice', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('قبول الاعتراض وتصحيح المبلغ'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('dispute-corrected-amount')),
      '80',
    );
    await tester.ensureVisible(find.text('قبول الاعتراض وإلغاء العملية'));
    await tester.tap(find.text('قبول الاعتراض وإلغاء العملية'));
    await tester.pumpAndSettle();
    await note(tester);
    await review(tester);
    expect(
      find.text('سيُلغى أثر هذه العملية بالكامل على الرصيد.'),
      findsWidgets,
    );
    await tester.tap(find.text('تأكيد وحفظ القرار'));
    await tester.pumpAndSettle();
    expect(controller.decisions.single['resolution'], 'accepted');
    expect(controller.decisions.single['amount'], isNull);
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets('missing original amount disables decision submission', (
    tester,
  ) async {
    await open(tester, amount: null);
    await tester.tap(find.text('قبول الاعتراض وإلغاء العملية'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CustomButton>(find.byKey(const Key('dispute-review')))
          .onPressed,
      isNull,
    );
    expect(controller.decisions, isEmpty);
  });
}
