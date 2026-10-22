import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../../core/security/encrypted_backup.dart';
import 'local_ledger_store.dart';

/// Verify an encrypted snapshot before publishing it by atomic rename.
/// The caller reserves/freezes the notebook only after this succeeds.
Future<File> ensureLocalTransferBackup({
  required JsonMap snapshot,
  required Directory directory,
  required String password,
}) async {
  final fingerprint = LocalLedgerStore.transferFingerprint(snapshot);
  await directory.create(recursive: true);
  final target = File(
    '${directory.path}/${snapshot['id']}-$fingerprint.json.enc',
  );
  Future<bool> matches(File file) async {
    try {
      final envelope =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final plaintext = await EncryptedBackupCodec.decrypt(envelope, password);
      return LocalLedgerStore.transferFingerprint(
            LocalLedgerStore.decodeBackup(plaintext),
          ) ==
          fingerprint;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on StateError {
      return false;
    } on TypeError {
      return false;
    }
  }

  if (await target.exists() && await matches(target)) return target;
  final temporary = File('${target.path}.${const Uuid().v4()}.pending');
  await temporary.writeAsString(
    await LocalLedgerStore.encodeBackup(snapshot, password: password),
    flush: true,
  );
  if (!await matches(temporary)) {
    throw StateError('تعذر التحقق من النسخة الاحتياطية. لم يبدأ رفع الدفتر.');
  }
  await temporary.rename(target.path);
  return target;
}
