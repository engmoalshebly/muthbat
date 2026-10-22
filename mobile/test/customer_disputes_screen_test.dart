import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/app/theme/app_theme.dart';
import 'package:muthbat/app/theme/app_colors.dart';
import 'package:muthbat/features/customer/data/customer_disputes_repository.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';
import 'package:muthbat/features/customer/presentation/screens/customer_disputes_screen.dart';

class DisputesViewRepository extends CustomerDisputesRepository {
  String status = 'awaiting_customer';
  @override
  Future<List<Map<String, dynamic>>> local(String owner) async => [
    {
      'id': 'dispute',
      'entry_id': 'entry',
      'business_name': 'متجر الاختبار',
      'status': status,
      'description': 'المبلغ غير صحيح',
      'created_at': '2026-10-22T00:00:00Z',
      'entry': {
        'amount': 100,
        'currency_code': 'SAR',
        'description': 'شراء',
        'occurred_at': '2026-10-21T10:00:00Z',
      },
      'messages': [
        {
          'sender_user_id': 'merchant',
          'message': 'ما المبلغ الصحيح؟',
          'created_at': '2026-10-22T01:00:00Z',
        },
      ],
      'resolution_note': status == 'partially_accepted' ? 'صححنا المبلغ' : null,
      'corrected_amount': 80,
      'resolution': {'corrected_entry_id': 'corrected'},
    },
  ];
  @override
  Future<void> sync(String owner) async {}
}

class DisputesViewActions extends CustomerRepository {
  final replies = <String>[];
  List<Map<String, dynamic>> queue = [];
  @override
  Future<List<Map<String, dynamic>>> pendingActions() async => queue;
  @override
  Future<void> flushOutbox() async {}
  @override
  Future<void> replyToDispute(String id, String message) async {
    replies.add(message);
    queue = [
      {
        'id': 'reply',
        'target_id': id,
        'status': 'pending',
        'payload': jsonEncode({
          'kind': 'dispute_reply',
          'target_id': id,
          'message': message,
        }),
      },
    ];
  }
}

class MultipleDisputesViewRepository extends DisputesViewRepository {
  bool empty = false;
  @override
  Future<List<Map<String, dynamic>>> local(String owner) async {
    if (empty) return [];
    final sample = (await super.local(owner)).single;
    return [
      {
        ...sample,
        'id': 'reply-needed',
        'business_name': 'متجر يحتاج الرد',
        'status': 'awaiting_customer',
      },
      {
        ...sample,
        'id': 'review',
        'business_name': 'متجر قيد المراجعة',
        'status': 'awaiting_merchant',
      },
      {
        ...sample,
        'id': 'done',
        'business_name': 'متجر مكتمل',
        'status': 'accepted',
      },
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('disputes-screen-');
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    await AppDatabase.instance.bindAccount(
      'f1970000-0000-0000-0000-000000000001',
    );
  });
  tearDownAll(() => AppDatabase.instance.lockAccount());
  testWidgets(
    'returning from an entry-linked detail stays on the list after background changes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDisputesScreen(
            entryId: 'entry',
            repository: DisputesViewRepository(),
            actions: DisputesViewActions(),
            refreshOnOpen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('متابعة طلبك'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      CustomerDisputesRepository.changes.value++;
      await tester.pumpAndSettle();
      expect(find.text('طلباتي للتاجر'), findsOneWidget);
      expect(find.text('متابعة طلبك'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('simple list opens a request and back returns to the list', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomerDisputesScreen(
          repository: MultipleDisputesViewRepository(),
          actions: DisputesViewActions(),
          refreshOnOpen: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.ensureVisible(find.text('متجر يحتاج الرد'));
    await tester.tap(find.text('متجر يحتاج الرد'));
    await tester.pumpAndSettle();
    expect(find.text('متابعة طلبك'), findsOneWidget);
    expect(find.text('كل طلباتك في مكان واحد'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('طلباتي للتاجر'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'empty list explains how to start; RTL details fit narrow large-text screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget page(Widget child) => MaterialApp(
        theme: AppTheme.lightTheme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.5),
            ),
            child: child,
          ),
        ),
      );
      await tester.pumpWidget(
        page(
          CustomerDisputesScreen(
            repository: MultipleDisputesViewRepository()..empty = true,
            actions: DisputesViewActions(),
            refreshOnOpen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('لا توجد طلبات بعد'), 200);
      expect(find.text('لا توجد طلبات بعد'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        page(
          CustomerDisputesScreen(
            repository: MultipleDisputesViewRepository(),
            actions: DisputesViewActions(),
            refreshOnOpen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        page(
          CustomerDisputesScreen(
            disputeId: 'dispute',
            repository: DisputesViewRepository()..status = 'partially_accepted',
            actions: DisputesViewActions(),
            refreshOnOpen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('متابعة طلبك')).style?.color,
        AppColors.white,
      );
      expect(find.text('متجر الاختبار'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('رد التاجر'), 200);
      expect(tester.takeException(), isNull);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'merchant request is readable, customer can reply and sees a distinct queued state',
    (tester) async {
      final repository = DisputesViewRepository();
      final actions = DisputesViewActions();
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDisputesScreen(
            disputeId: 'dispute',
            repository: repository,
            actions: actions,
            refreshOnOpen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('التاجر يحتاج توضيحًا منك'), findsOneWidget);
      expect(find.textContaining('ما المبلغ الصحيح؟'), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(tester.getSize(find.byType(AppBar)).height, lessThanOrEqualTo(72));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(TextField)).bottom,
        lessThanOrEqualTo(
          tester.view.physicalSize.height / tester.view.devicePixelRatio -
              300 / tester.view.devicePixelRatio,
        ),
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'الصحيح 80 ريال');
      await tester.tap(find.byTooltip('إرسال الرسالة'));
      await tester.pumpAndSettle();
      expect(actions.replies, ['الصحيح 80 ريال']);
      expect(
        find.text('طلبك محفوظ. سنرسله عند توفر الإنترنت.'),
        findsOneWidget,
      );
      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.send_rounded),
      );
      expect(button.onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'correction shows financial result and exact currency without a reply composer',
    (tester) async {
      final repository = DisputesViewRepository()
        ..status = 'partially_accepted';
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDisputesScreen(
            disputeId: 'dispute',
            repository: repository,
            actions: DisputesViewActions(),
            refreshOnOpen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('وافق التاجر • صُحح المبلغ'), findsOneWidget);
      expect(
        find.text('المبلغ قبل التصحيح: 100 SAR\nالمبلغ بعد التصحيح: 80 SAR'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('صححنا المبلغ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed local requests expose failure and retry instead of claiming delivery',
    (tester) async {
      final actions = DisputesViewActions()
        ..queue = [
          {
            'id': 'failed',
            'target_id': 'entry',
            'status': 'failed',
            'error': 'تغيرت صلاحية العملية',
            'payload': jsonEncode({
              'kind': 'dispute',
              'target_id': 'entry',
              'description': 'طلب لم يصل',
            }),
          },
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: CustomerDisputesScreen(
            repository: DisputesViewRepository(),
            actions: actions,
            refreshOnOpen: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('لم نتمكن من الإرسال. اضغط «إرسال مرة أخرى».'),
        findsOneWidget,
      );
      expect(find.text('إرسال مرة أخرى'), findsOneWidget);
      expect(find.text('تغيرت صلاحية العملية'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
