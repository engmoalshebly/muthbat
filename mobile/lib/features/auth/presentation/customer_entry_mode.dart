import 'workspace_preference.dart';

/// UI preference only; never grants server permissions.
class CustomerEntryMode {
  static Future<void> remember(String userId, bool customer) async {
    await WorkspacePreference.save(userId, customer ? 'customer' : 'merchant');
  }

  static Future<bool> selected(String userId) async {
    return (await WorkspacePreference.read(userId))?['kind'] == 'customer';
  }
}
