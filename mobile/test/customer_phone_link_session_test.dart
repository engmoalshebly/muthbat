import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/core/config/env.dart';
import 'package:muthbat/core/sync/user_contact_bootstrap.dart';
import 'package:muthbat/features/customer/data/customer_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'd1940000-0000-0000-0000-000000000002';
  late SupabaseClient client;
  var bypassed = false;
  var linkRequests = 0;
  Completer<void>? contactGate;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp(
      'customer-phone-session-',
    );
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    await AppDatabase.instance.bindAccount(owner);
  });
  tearDownAll(() => AppDatabase.instance.lockAccount());
  setUp(() {
    linkRequests = 0;
    contactGate = null;
  });
  Future<CustomerRepository> repository({required bool bypass}) async {
    bypassed = bypass;
    client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        Object result;
        if (request.url.path.endsWith('/token')) {
          String encode(Object value) => base64Url
              .encode(utf8.encode(jsonEncode(value)))
              .replaceAll('=', '');
          final token =
              '${encode({'alg': 'HS256'})}.${encode({'sub': owner, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.test';
          result = {
            'access_token': token,
            'refresh_token': 'test-refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': owner,
              'aud': 'authenticated',
              'role': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'phone': '967777123456',
              'phone_confirmed_at': '2026-01-01T00:00:00Z',
              'app_metadata': {'phone_verification_bypassed': bypassed},
              'user_metadata': {},
            },
          };
        } else if (request.url.path.endsWith('/bootstrap-user-contact')) {
          linkRequests++;
          await contactGate?.future;
          result = {'customerId': 'claimed-customer'};
        } else {
          throw StateError('Unexpected request: ${request.url}');
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.auth.signInWithPassword(
      phone: '+967777123456',
      password: 'test-password',
    );
    return CustomerRepository(client: client);
  }

  tearDown(() async => client.dispose());
  test(
    'verified session claims phone independently of signup feature flag',
    () async {
      final repo = await repository(bypass: false);
      await repo.refreshPhoneLinks();
      expect(linkRequests, 1);
    },
  );
  test('bypassed phone follows only the explicit staging opt-in', () async {
    final repo = await repository(bypass: true);
    if (EnvConfig.allowStagingUnverifiedPhoneLinks) {
      await repo.refreshPhoneLinks();
      expect(linkRequests, 1);
    } else {
      await expectLater(
        repo.refreshPhoneLinks(),
        throwsA(isA<CustomerPhoneVerificationRequired>()),
      );
      expect(linkRequests, 0);
    }
  });
  test(
    'login hydration and customer refresh share one in-flight phone request',
    () async {
      final repo = await repository(bypass: false);
      contactGate = Completer<void>();
      final loginHydration = bootstrapUserContact(client);
      final customerRefresh = repo.refreshPhoneLinks();
      for (var i = 0; i < 100 && linkRequests == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final count = linkRequests;
      contactGate!.complete();
      await Future.wait([loginHydration, customerRefresh]);
      expect(count, 1);
      expect(linkRequests, 1);
      await repo.refreshPhoneLinks();
      expect(linkRequests, 2);
    },
  );
}
