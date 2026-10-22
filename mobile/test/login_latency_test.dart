import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/core/sync/sync_engine.dart';
import 'package:muthbat/features/auth/presentation/controllers/auth_controller.dart'
    as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = 'f2100000-0000-0000-0000-000000000001';
  const b = 'f2100000-0000-0000-0000-000000000002';
  const shop = 'f2100000-0000-0000-0000-000000000003';
  late app.AuthController auth;
  final requests = <String>[];
  Completer<void>? profileGate, accessGate, contactGate, membershipGate;
  var userId = a;
  bool invalidPassword = false;
  String jwt(String id) {
    String enc(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc({'sub': id, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600})}.test';
  }

  // Pumps real wall-clock time so pending background futures (gated by the
  // Completers below) get a chance to run. A fixed 250ms budget was enough
  // locally but proved too tight under CI's slower/shared runners, where
  // this file's async HTTP-mock plumbing can take longer to settle; poll
  // for longer and in smaller steps so the common case still returns fast.
  Future<void> settleBackground() async {
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('login-latency-');
    await databaseFactoryFfi.setDatabasesPath(folder.path);
    await Supabase.initialize(
      url: 'https://example.test',
      publishableKey: 'test-key',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        final path = request.url.path.split('/').last;
        requests.add(path);
        http.Response reply(Object? v, [int status = 200]) => http.Response(
          jsonEncode(v),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
        if (path == 'token') {
          if (invalidPassword) {
            return reply({'msg': 'Invalid login credentials'}, 400);
          }
          return reply({
            'access_token': jwt(userId),
            'refresh_token': 'test-refresh',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': userId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'phone': '+12025550173',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {
                'display_name': userId == a ? 'شخص أ' : 'شخص ب',
                'user_type': 'customer',
              },
            },
          });
        }
        if (path == 'profiles') {
          await profileGate?.future;
          final id = request.url.queryParameters['id'];
          return reply({
            'display_name': id == 'eq.$a' ? 'شخص أ محدث' : 'شخص ب محدث',
            'user_type': 'merchant',
          });
        }
        if (path == 'businesses') {
          await accessGate?.future;
          return reply([
            {
              'id': shop,
              'owner_user_id': userId,
              'name': 'متجري',
              'status': 'active',
              'currency_code': 'YER',
            },
          ]);
        }
        if (path == 'business_members') {
          await membershipGate?.future;
          await accessGate?.future;
          return reply([]);
        }
        if (path == 'bootstrap-user-contact') {
          await contactGate?.future;
          return reply({});
        }
        return reply([]);
      }),
    );
    // Keep the unrelated account sync worker out of this login timing test.
    await SyncEngine.instance.pauseAndDrain();
  });
  setUp(() async {
    requests.clear();
    profileGate = null;
    accessGate = null;
    contactGate = null;
    membershipGate = null;
    invalidPassword = false;
    userId = a;
    auth = app.AuthController();
    await auth.ready;
    requests.clear();
  });
  tearDown(() async {
    for (final gate in [profileGate, accessGate, contactGate, membershipGate]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await settleBackground();
    auth.dispose();
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    await SyncEngine.instance.pauseAndDrain();
    await AppDatabase.instance.lockAccount();
  });
  test(
    'first-time owner login does not wait for unrelated membership lookup',
    () async {
      // Use a fresh account with no preferred cached business.
      userId = 'f2100000-0000-0000-0000-000000000099';
      membershipGate = Completer<void>();
      contactGate = Completer<void>();
      expect(
        await auth
            .loginWithPassword(
              phone: '+12025550179',
              password: 'Test-password-938!',
              merchantMode: true,
            )
            .timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(membershipGate!.isCompleted, isFalse);
      expect(auth.state.activeBusinessId, shop);
      expect(auth.state.businessRole, 'owner');
    },
  );
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });

  test(
    'customer login completes with profile, membership and contact still blocked',
    () async {
      profileGate = Completer<void>();
      accessGate = Completer<void>();
      contactGate = Completer<void>();
      expect(
        await auth
            .loginWithPassword(
              phone: '+12025550173',
              password: 'Test-password-938!',
            )
            .timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(auth.state.status, app.AuthStatus.authenticated);
      expect(auth.state.userId, a);
      expect(profileGate!.isCompleted, isFalse);
      expect(contactGate!.isCompleted, isFalse);
      await settleBackground();
      expect(
        requests,
        containsAll(['profiles', 'businesses', 'bootstrap-user-contact']),
      );
    },
  );
  test(
    'returning owner opens local merchant before remote refresh completes',
    () async {
      await AppDatabase.instance.bindAccount(a);
      await AppDatabase.instance.saveBusiness({
        'id': shop,
        'owner_user_id': a,
        'name': 'متجري',
        'is_active': 1,
      });
      profileGate = Completer<void>();
      accessGate = Completer<void>();
      contactGate = Completer<void>();
      expect(
        await auth
            .loginWithPassword(
              phone: '+12025550173',
              password: 'Test-password-938!',
              merchantMode: true,
            )
            .timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(auth.state.activeBusinessId, shop);
      expect(auth.state.businessRole, 'owner');
      expect(profileGate!.isCompleted, isFalse);
    },
  );
  test(
    'new merchant fetches profile and membership concurrently and does not await contact',
    () async {
      userId = b;
      profileGate = Completer<void>();
      accessGate = Completer<void>();
      contactGate = Completer<void>();
      var completed = false;
      final login = auth
          .loginWithPassword(
            phone: '+12025550174',
            password: 'Test-password-938!',
            merchantMode: true,
          )
          .then((value) {
            completed = true;
            return value;
          });
      await settleBackground();
      expect(requests, containsAll(['profiles', 'businesses']));
      expect(completed, isFalse);
      accessGate!.complete();
      profileGate!.complete();
      expect(await login.timeout(const Duration(seconds: 2)), isTrue);
      expect(auth.state.userId, b);
      expect(auth.state.activeBusinessId, shop);
      expect(contactGate!.isCompleted, isFalse);
    },
  );
  test('delayed background A cannot overwrite a later B login', () async {
    profileGate = Completer<void>();
    accessGate = Completer<void>();
    contactGate = Completer<void>();
    expect(
      await auth.loginWithPassword(
        phone: '+12025550173',
        password: 'Test-password-938!',
      ),
      isTrue,
    );
    await settleBackground();
    userId = b;
    expect(
      await auth.loginWithPassword(
        phone: '+12025550174',
        password: 'Test-password-938!',
      ),
      isTrue,
    );
    expect(auth.state.userId, b);
    profileGate!.complete();
    accessGate!.complete();
    contactGate!.complete();
    await settleBackground();
    expect(auth.state.userId, b);
    expect(auth.state.displayName, 'شخص ب محدث');
    expect(AppDatabase.instance.accountId, b);
  });
  test('reset invalidates a pending background refresh', () async {
    profileGate = Completer<void>();
    accessGate = Completer<void>();
    expect(
      await auth.loginWithPassword(
        phone: '+12025550173',
        password: 'Test-password-938!',
      ),
      isTrue,
    );
    await settleBackground();
    auth.reset();
    expect(auth.state.status, app.AuthStatus.localOnly);
    profileGate!.complete();
    accessGate!.complete();
    await settleBackground();
    expect(auth.state.status, app.AuthStatus.localOnly);
  });
  test('invalid password cannot open a cached account', () async {
    invalidPassword = true;
    expect(
      await auth.loginWithPassword(
        phone: '+12025550173',
        password: 'Test-password-938!',
      ),
      isFalse,
    );
    expect(auth.state.status, isNot(app.AuthStatus.authenticated));
    expect(requests, isNot(contains('profiles')));
  });
}
