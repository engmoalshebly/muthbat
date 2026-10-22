import 'package:supabase_flutter/supabase_flutter.dart';

/// A cached notebook identity is never sufficient for a cloud operation.
bool canUseCloudSession(Session? session, String? accountId) =>
    session != null &&
    !session.isExpired &&
    accountId != null &&
    session.user.id == accountId;

void requireCloudSession(SupabaseClient client, String? accountId) {
  if (!canUseCloudSession(client.auth.currentSession, accountId)) {
    throw StateError('العمل المحلي متاح. سجّل الدخول لاستكمال المزامنة.');
  }
}
