import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:muthbat/core/database/app_database.dart';
import 'package:muthbat/features/auth/data/business_access_repository.dart';
import 'package:muthbat/features/auth/presentation/controllers/auth_controller.dart'
    as app;
import 'package:muthbat/features/auth/presentation/workspace_preference.dart';
import 'package:muthbat/features/auth/presentation/workspace_navigation.dart';
import 'package:muthbat/app/router/app_routes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'restored account switches locally without any HTTP; revoked grants stay revoked',
    () async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      AppDatabase.debugDatabaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp(
        'workspace-local-access-',
      );
      await databaseFactoryFfi.setDatabasesPath(directory.path);
      final db = AppDatabase.instance;
      const owner = 'f1950000-0000-0000-0000-000000000001';
      await db.bindAccount(owner);
      await db.saveProfile({
        'id': owner,
        'display_name': 'اسمي الشخصي',
        'user_type': 'merchant',
      });
      await db.saveBusiness({
        'id': 'business',
        'owner_user_id': owner,
        'name': 'اسم المتجر',
        'is_active': 1,
      });
      await db.rememberCustomer();
      await db.rememberOwner();
      await db.lockAccount();
      var requests = 0;
      await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test-key',
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          persistSession: false,
          detectSessionInUri: false,
        ),
        httpClient: MockClient((request) async {
          requests++;
          throw const SocketException('offline');
        }),
      );
      final auth = app.AuthController();
      await auth.localReady;
      await auth.ready;
      expect(auth.state.hasLocalAccess, isTrue);
      expect(
        await prepareWorkspaceNavigation(auth: auth, kind: 'customer'),
        AppRoutes.customerHome,
      );
      expect((await WorkspacePreference.read(owner))?['kind'], 'customer');
      expect(auth.state.displayName, 'اسمي الشخصي');
      expect(
        await prepareWorkspaceNavigation(auth: auth, kind: 'merchant'),
        AppRoutes.merchantHome,
      );
      expect((await WorkspacePreference.read(owner))?['kind'], 'merchant');
      expect(auth.state.activeBusinessId, 'business');
      expect(auth.state.businessRole, 'owner');
      expect(requests, 0);
      await db.setSyncStateValue(
        BusinessAccessRepository.cacheKey,
        '{"user_id":"$owner","denied":true}',
      );
      await auth.refreshLocalBusinessAccess();
      expect(auth.state.activeBusinessId, isNull);
      expect(auth.state.businessRole, isNull);
      await expectLater(
        prepareWorkspaceNavigation(auth: auth, kind: 'merchant'),
        throwsStateError,
      );
      expect(requests, 0);
      auth.dispose();
      await Supabase.instance.dispose();
      await db.lockAccount();
    },
  );
}
