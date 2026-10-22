import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muthbat/app/router/session_navigation_frame.dart';
import 'package:muthbat/features/app_lock/app_lock_overlay.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'session banner toggles during push and pop preserve navigator and routes',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final banner = ValueNotifier(false);
      addTearDown(banner.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: banner,
            builder: (context, visible, _) => SessionNavigationFrame(
              showBanner: visible,
              banner: const Text('Session banner'),
              child: child!,
            ),
          ),
          home: const Scaffold(
            body: Hero(tag: 'test', child: Text('Home')),
          ),
        ),
      );
      final original = navigator.currentState;
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: Hero(tag: 'test', child: Text('Destination')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      banner.value = true;
      await tester.pump(const Duration(milliseconds: 50));
      banner.value = false;
      await tester.pumpAndSettle();
      expect(navigator.currentState, same(original));
      expect(find.text('Destination'), findsOneWidget);
      expect(tester.takeException(), isNull);
      navigator.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 50));
      banner.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(navigator.currentState, same(original));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('lock navigator does not acquire the root Hero controller', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'app_lock_pin_hash_v1': 'configured',
    });
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => AppLockOverlay(child: child!),
        home: const Scaffold(body: Text('Protected home')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Navigator), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Next route')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
