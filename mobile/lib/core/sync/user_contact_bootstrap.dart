import 'package:supabase_flutter/supabase_flutter.dart';

final _contactRequests = Expando<Map<String, Future<FunctionResponse>>>();

/// Login hydration and the customer screen share an in-flight phone claim.
/// Completed results are not cached: a later refresh can discover new links.
Future<FunctionResponse> bootstrapUserContact(SupabaseClient client) {
  final owner = client.auth.currentUser?.id;
  if (owner == null) throw const AuthException('Authentication is required.');
  final pending = _contactRequests[client] ??= {};
  final existing = pending[owner];
  if (existing != null) return existing;
  late final Future<FunctionResponse> request;
  request = client.functions
      .invoke('bootstrap-user-contact')
      .timeout(const Duration(seconds: 15))
      .whenComplete(() {
        if (identical(pending[owner], request)) pending.remove(owner);
      });
  pending[owner] = request;
  return request;
}
