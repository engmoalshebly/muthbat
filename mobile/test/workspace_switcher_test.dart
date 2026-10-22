import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/app/router/app_routes.dart';
import 'package:muthbat/features/auth/presentation/controllers/auth_controller.dart';
import 'package:muthbat/features/auth/presentation/widgets/workspace_switcher.dart';
import 'package:muthbat/features/auth/presentation/workspace_navigation.dart';
import 'package:muthbat/features/auth/presentation/workspace_preference.dart';
import 'package:muthbat/features/local_ledger/local_ledger_store.dart';

class PickerNotebookStore extends LocalLedgerStore {
  bool failRead = false;
  String selected = 'one';
  final rows = <JsonMap>[
    {'id': 'one', 'name': 'دفتر البيت', 'transfer_state': 'local'},
    {'id': 'two', 'name': 'دفتر العمل', 'transfer_state': 'local'},
  ];
  @override
  Future<List<JsonMap>> notebooks() async {
    if (failRead) throw StateError('unreadable');
    return rows;
  }

  @override
  Future<void> selectNotebook(String id) async {
    selected = id;
  }

  @override
  Future<JsonMap?> current() async =>
      rows.firstWhere((r) => r['id'] == selected);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'sheet closes on current notebook and switches another with a persisted preference',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = PickerNotebookStore();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            routes: {
              AppRoutes.localLedger: (_) =>
                  const Scaffold(body: Text('الدفتر المختار')),
            },
            home: Scaffold(
              body: WorkspaceSwitcherButton(
                currentKind: 'local',
                notebookId: 'one',
                store: store,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('تبديل الحساب'));
      await tester.pumpAndSettle();
      expect(find.text('دفتر محلي • الحالي'), findsOneWidget);
      await tester.tap(find.text('دفتر البيت'));
      await tester.pumpAndSettle();
      expect(find.text('دفتر العمل'), findsNothing);
      expect(store.selected, 'one');
      await tester.tap(find.byTooltip('تبديل الحساب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('دفتر العمل'));
      await tester.pumpAndSettle();
      expect(find.text('الدفتر المختار'), findsOneWidget);
      expect(store.selected, 'two');
      expect((await WorkspacePreference.read(null))?['notebook_id'], 'two');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unreadable notebooks show retry without offering an empty replacement notebook',
    (tester) async {
      final store = PickerNotebookStore()..failRead = true;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: WorkspaceSwitcherButton(
                currentKind: 'local',
                notebookId: 'one',
                store: store,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('تبديل الحساب'));
      await tester.pumpAndSettle();
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.text('ابدأ دفترًا على هذا الجهاز'), findsNothing);
      store.failRead = false;
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(find.text('دفتر البيت'), findsOneWidget);
      expect(find.text('دفتر العمل'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  final notebooks = <JsonMap>[
    {'id': 'one', 'name': 'دفتر البيت', 'transfer_state': 'local'},
    {
      'id': 'two',
      'name': 'دفتر آخر باسم طويل لعرض الحساب',
      'transfer_state': 'complete',
    },
  ];
  const owner = AuthState(
    status: AuthStatus.localOnly,
    userId: 'owner',
    businessAccessChecked: true,
    activeBusinessId: 'shop',
    businessRole: 'owner',
  );

  test(
    'picker offers available roles and all notebooks, including offline accounts',
    () {
      final choices = availableWorkspaces(owner, notebooks);
      expect(choices.map((c) => c.kind), [
        'customer',
        'merchant',
        'local',
        'local',
      ]);
      expect(choices.last.subtitle, contains('للقراءة'));
      final denied = availableWorkspaces(
        owner.copyWith(clearBusinessAccess: true),
        notebooks,
      );
      expect(denied.any((c) => c.kind == 'merchant'), isFalse);
      final guest = availableWorkspaces(const AuthState(), []);
      expect(guest.single.kind, 'local');
      expect(
        availableWorkspaces(
          const AuthState(),
          notebooks,
        ).every((c) => c.kind == 'local'),
        isTrue,
      );
    },
  );

  testWidgets(
    'picker marks the exact current notebook and fits narrow RTL screens with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      WorkspaceChoice? selected;
      final choices = availableWorkspaces(owner, notebooks);
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(1.6),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: WorkspaceChoiceList(
                      choices: choices,
                      currentKind: 'local',
                      notebookId: 'two',
                      onSelect: (value) => selected = value,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(find.textContaining('الحالي'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('workspace-merchant-')),
      );
      await tester.tap(find.byKey(const ValueKey('workspace-merchant-')));
      expect(selected?.kind, 'merchant');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'avatar renders without initializing cloud auth and has an accessible switch action',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WorkspaceSwitcherButton(
              currentKind: 'local',
              name: 'محمد',
              enabled: false,
            ),
          ),
        ),
      );
      expect(find.byTooltip('تبديل الحساب'), findsOneWidget);
      expect(find.text('م'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'guest local switch persists exact notebook without initializing Supabase',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      final store = LocalLedgerStore(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      await store.create('دفتر البيت', 'YER');
      final notebook = (await store.current())!;
      expect(
        await prepareWorkspaceNavigation(
          kind: 'local',
          notebook: notebook,
          store: store,
        ),
        AppRoutes.localLedger,
      );
      expect(
        (await WorkspacePreference.read(null))?['notebook_id'],
        notebook['id'],
      );
      await expectLater(
        prepareWorkspaceNavigation(
          kind: 'local',
          notebook: {'id': 'missing'},
          store: store,
        ),
        throwsStateError,
      );
      expect(
        (await WorkspacePreference.read(null))?['notebook_id'],
        notebook['id'],
      );
      await expectLater(
        prepareWorkspaceNavigation(kind: 'merchant'),
        throwsStateError,
      );
      await (await store.database).close();
    },
  );
}
