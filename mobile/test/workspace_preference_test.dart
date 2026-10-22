import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muthbat/features/auth/presentation/workspace_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'workspace choices are isolated by account and preserve notebook identity',
    () async {
      await WorkspacePreference.save(
        'owner-a',
        'local',
        notebookId: 'notebook-a',
      );
      await WorkspacePreference.save('owner-b', 'customer');
      await WorkspacePreference.save(
        null,
        'local',
        notebookId: 'device-notebook',
      );
      expect(
        (await WorkspacePreference.read('owner-a'))?['notebook_id'],
        'notebook-a',
      );
      expect((await WorkspacePreference.read('owner-b'))?['kind'], 'customer');
      expect(
        (await WorkspacePreference.read(null))?['notebook_id'],
        'device-notebook',
      );
      await WorkspacePreference.save('owner-a', 'merchant');
      expect((await WorkspacePreference.read('owner-a'))?['kind'], 'merchant');
      expect((await WorkspacePreference.read('owner-b'))?['kind'], 'customer');
    },
  );
  test('unknown and corrupt choices fall back without throwing', () async {
    expect(await WorkspacePreference.read('missing'), isNull);
    SharedPreferences.setMockInitialValues({'workspace_v1_owner': '{invalid'});
    expect(await WorkspacePreference.read('owner'), isNull);
  });
  test(
    'legacy selection migrates once and cannot override a newer workspace',
    () async {
      SharedPreferences.setMockInitialValues({
        'customer_workspace_owner': true,
      });
      expect((await WorkspacePreference.read('owner'))?['kind'], 'customer');
      await WorkspacePreference.save('owner', 'merchant');
      expect((await WorkspacePreference.read('owner'))?['kind'], 'merchant');
      await WorkspacePreference.save('owner', 'local', notebookId: 'book');
      expect((await WorkspacePreference.read('owner'))?['notebook_id'], 'book');
    },
  );
}
