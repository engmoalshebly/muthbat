import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Each immutable request path can safely be retried after a partial success.
Future<String> uploadBusinessLogo(
  SupabaseClient client, {
  required String businessId,
  required String requestId,
  required Uint8List bytes,
  required String extension,
}) async {
  final safeExtension = {'jpg', 'jpeg', 'png', 'webp'}.contains(extension)
      ? extension
      : 'jpg';
  final path = '$businessId/logo/$requestId.$safeExtension';
  try {
    await client.storage
        .from('business-assets')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: false,
            contentType: safeExtension == 'png'
                ? 'image/png'
                : safeExtension == 'webp'
                ? 'image/webp'
                : 'image/jpeg',
          ),
        );
  } on StorageException catch (error) {
    if (error.statusCode != '409' && error.error != 'Duplicate') rethrow;
  }
  // A duplicate object alone is not success: RPC validates ownership and path.
  final confirmed = await client.rpc(
    'set_business_logo_idempotent',
    params: {
      'p_business_id': businessId,
      'p_object_path': path,
      'p_request_id': requestId,
    },
  );
  if (confirmed != path) throw StateError('logo_update_unconfirmed');
  return path;
}
