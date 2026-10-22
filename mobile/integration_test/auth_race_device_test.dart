import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/core/security/secure_auth_storage.dart';
import 'package:muthbat/features/auth/presentation/controllers/auth_controller.dart'
    as app;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device: delayed A cannot overwrite B or resurrect after reset', (
    tester,
  ) async {
    const a = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    const b = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
    final delayed = Completer<void>();
    final arrived = Completer<void>();
    var delayA = true;
    var tokenCalls = 0;
    Completer<void>? resetGate;
    final resetArrived = Completer<void>();
    String jwt(String id) {
      String enc(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc({'sub': id, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600, 'role': 'authenticated'})}.test';
    }

    final client = MockClient((request) async {
      http.Response json(Object? value, [int status = 200]) => http.Response(
        jsonEncode(value),
        status,
        request: request,
        headers: {'content-type': 'application/json'},
      );
      if (request.url.path.endsWith('/token')) {
        tokenCalls++;
        final phone = (jsonDecode(request.body) as Map)['phone'] as String;
        final id = phone.endsWith('173') ? a : b;
        return json({
          'access_token': jwt(id),
          'refresh_token': 'test-refresh-$id',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': id,
            'aud': 'authenticated',
            'role': 'authenticated',
            'phone': phone,
            'created_at': '2026-01-01T00:00:00Z',
            'app_metadata': {'phone_verification_bypassed': true},
            'user_metadata': {
              'display_name': id == a ? 'Account A' : 'Account B',
              'user_type': 'customer',
            },
          },
        });
      }
      if (request.url.path.endsWith('/logout')) return json({});
      if (request.url.path.endsWith('/profiles')) {
        if (resetGate != null) {
          if (!resetArrived.isCompleted) resetArrived.complete();
          await resetGate!.future;
        }
        final isA = request.url.queryParameters['id'] == 'eq.$a';
        if (isA && delayA) {
          if (!arrived.isCompleted) arrived.complete();
          await delayed.future;
        }
        return json({
          'display_name': isA ? 'Account A' : 'Account B',
          'user_type': 'customer',
        });
      }
      if (request.url.path.endsWith('/businesses')) return json(null);
      return json([]);
    });
    await Supabase.initialize(
      url: 'https://auth-device-test.supabase.co',
      publishableKey: 'test-public-key',
      httpClient: client,
      authOptions: secureAuthOptions('https://auth-device-test.supabase.co'),
      debug: false,
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Auth device test'))),
    );
    await tester.runAsync(() async {
      final controller = app.AuthController();
      await controller.ready;
      final first = controller.loginWithPassword(
        phone: '+12025550173',
        password: 'Test-password-938!',
      );
      await arrived.future.timeout(const Duration(seconds: 15));
      final second = await controller.loginWithPassword(
        phone: '+12025550174',
        password: 'Test-password-938!',
      );
      expect(second, isTrue);
      expect(controller.state.userId, b);
      delayed.complete();
      // A now completes from its local identity before background hydration.
      // Its delayed refresh must still never overwrite the later B login.
      expect(await first, isTrue);
      expect(controller.state.userId, b);
      expect(controller.state.status, app.AuthStatus.authenticated);
      expect(controller.state.displayName, 'Account B');
      expect(AppDatabase.instance.accountId, b);
      final one = controller.signOut();
      final two = controller.signOut();
      expect((await one).signedOut, isTrue);
      expect((await two).signedOut, isTrue);
      expect(AppDatabase.instance.accountId, isNull);
      expect(controller.state.status, app.AuthStatus.unauthenticated);
      final vault = SecureAuthVault(
        supabaseUrl: 'https://auth-device-test.supabase.co',
      );
      expect(await vault.read(vault.legacySessionKey), isNull);
      controller.dispose();
      delayA = false;
      final login = app.AuthController();
      await login.ready;
      expect(
        await login.loginWithPassword(
          phone: '+12025550174',
          password: 'Test-password-938!',
        ),
        isTrue,
      );
      login.dispose();
      resetGate = Completer<void>();
      final restored = app.AuthController();
      await resetArrived.future.timeout(const Duration(seconds: 15));
      // Real wall-clock delay on Android: exceed the profile request timeout.
      await Future<void>.delayed(const Duration(seconds: 9));
      restored.reset();
      resetGate!.complete();
      await restored.ready;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(restored.state.status, isNot(app.AuthStatus.authenticated));
      restored.dispose();
      expect(tokenCalls, 3);
      await Supabase.instance.dispose();
    });
  });
}
