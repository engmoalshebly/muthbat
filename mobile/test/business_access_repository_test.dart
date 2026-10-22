import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/auth/data/business_access_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const imported = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  const previous = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  late SupabaseClient client;
  late BusinessAccessRepository repository;
  final requests = <Uri>[];
  bool revoked = false;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('business-access-');
    await databaseFactoryFfi.setDatabasesPath(folder.path);
    await AppDatabase.instance.bindAccount(owner);
    client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token': 'test-token',
              'refresh_token': 'test-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': owner,
                'aud': 'authenticated',
                'role': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final memberQuery = request.url.path.endsWith('/business_members');
        final id = memberQuery ? imported : previous;
        final business = {
          'id': id,
          'owner_user_id': owner,
          'name': id,
          'business_type': 'grocery',
          'status': 'active',
          'created_at': '2026-01-01T00:00:00Z',
        };
        return http.Response(
          jsonEncode(
            memberQuery
                ? revoked
                      ? []
                      : [
                          {'role': 'owner', 'businesses': business},
                        ]
                : business,
          ),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    await client.auth.signInWithPassword(
      email: 'test@example.test',
      password: 'password',
    );
    repository = BusinessAccessRepository(client: client);
  });
  setUp(() {
    requests.clear();
    revoked = false;
  });
  tearDownAll(() async {
    await client.dispose();
    await AppDatabase.instance.lockAccount();
  });

  test(
    'explicit handoff selects imported business rather than first owned',
    () async {
      final access = await repository.load(
        owner,
        preferredBusinessId: imported,
      );
      expect(access?.businessId, imported);
      expect(access?.role, 'owner');
      expect(requests.single.queryParameters['business_id'], 'eq.$imported');
      expect((await repository.cached(owner))?.businessId, imported);
    },
  );

  test('next login revalidates persisted workspace preference', () async {
    await repository.load(owner, preferredBusinessId: imported);
    requests.clear();
    expect((await repository.load(owner))?.businessId, imported);
    expect(requests.single.queryParameters['business_id'], 'eq.$imported');
  });

  test(
    'revoked explicit target fails instead of silently opening another shop',
    () async {
      revoked = true;
      await expectLater(
        repository.load(owner, preferredBusinessId: imported),
        throwsStateError,
      );
      expect(
        requests.every((uri) => uri.path.endsWith('/business_members')),
        isTrue,
      );
    },
  );

  test('stale handoff cannot overwrite selected workspace', () async {
    await expectLater(
      repository.load(
        owner,
        preferredBusinessId: imported,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect((await repository.cached(owner))?.businessId, imported);
    expect(
      (await AppDatabase.instance.getBusinessByOwnerId(owner))?['id'],
      imported,
    );
    expect(await repository.cached('another-account'), isNull);
  });
}
