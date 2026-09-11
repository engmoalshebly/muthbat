import 'package:shared_preferences/shared_preferences.dart';

/// UI preference only; never grants server permissions.
class CustomerEntryMode {
  static Future<void> remember(String userId, bool customer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('customer_workspace_$userId', customer);
  }

  static Future<bool> selected(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('customer_workspace_$userId') ?? false;
  }
}
