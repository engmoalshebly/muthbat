import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muthbat/app/app.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sq;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:muthbat/features/local_ledger/local_ledger_screen.dart';
import 'package:muthbat/features/local_ledger/local_ledger_store.dart';

void main() {
  testWidgets(
    'MuthbatApp boots into local notebook without Supabase or an account',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      sq.databaseFactory = databaseFactoryFfi;
      await tester.runAsync(() async {
        final folder = await Directory.systemTemp.createTemp(
          'muthbat-boot-test-',
        );
        await databaseFactoryFfi.setDatabasesPath(folder.path);
        await LocalLedgerStore.instance.database;
      });
      await tester.pumpWidget(const ProviderScope(child: MuthbatApp()));

      // Real SQLite work must run outside Flutter's fake timer clock.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
      expect(find.byType(LocalLedgerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () async => (await LocalLedgerStore.instance.database).close(),
      );
    },
  );
}
