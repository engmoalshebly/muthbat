import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Navigation preference only. Never grants a session or business membership.
class WorkspacePreference {
  static String _key(String? owner) => 'workspace_v1_${owner ?? 'device'}';
  static Future<void> save(
    String? owner,
    String kind, {
    String? notebookId,
  }) async {
    if (!{'customer', 'merchant', 'local'}.contains(kind)) {
      throw ArgumentError.value(kind, 'kind');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      _key(owner),
      jsonEncode({'kind': kind, 'notebook_id': notebookId}),
    )) {
      throw StateError('تعذر حفظ مساحة الحساب');
    }
  }

  static Future<Map<String, dynamic>?> read(String? owner) async {
    final raw = (await SharedPreferences.getInstance()).getString(_key(owner));
    if (raw == null) {
      final legacy = owner == null
          ? null
          : (await SharedPreferences.getInstance()).getBool(
              'customer_workspace_$owner',
            );
      if (legacy == null) return null;
      final kind = legacy ? 'customer' : 'merchant';
      await save(owner, kind);
      return {'kind': kind};
    }
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> &&
              {'customer', 'merchant', 'local'}.contains(value['kind'])
          ? value
          : null;
    } on FormatException {
      return null;
    }
  }
}
