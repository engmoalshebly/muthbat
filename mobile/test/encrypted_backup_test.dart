import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muthbat/core/security/encrypted_backup.dart';

void main() {
  test('round-trips arbitrary text with the correct password', () async {
    const plaintext = '{"hello":"world","amount":123}';
    final envelopeText = await EncryptedBackupCodec.encrypt(
      plaintext,
      'a-strong-password',
    );
    final envelope = jsonDecode(envelopeText) as Map<String, dynamic>;

    expect(EncryptedBackupCodec.isEncryptedEnvelope(envelope), isTrue);
    final decrypted = await EncryptedBackupCodec.decrypt(
      envelope,
      'a-strong-password',
    );
    expect(decrypted, plaintext);
  });

  test('rejects the wrong password', () async {
    final envelopeText = await EncryptedBackupCodec.encrypt(
      'secret payload',
      'correct-password',
    );
    final envelope = jsonDecode(envelopeText) as Map<String, dynamic>;

    await expectLater(
      EncryptedBackupCodec.decrypt(envelope, 'wrong-password'),
      throwsStateError,
    );
  });

  test('rejects a tampered ciphertext (authentication failure)', () async {
    final envelopeText = await EncryptedBackupCodec.encrypt(
      'secret payload',
      'correct-password',
    );
    final envelope = jsonDecode(envelopeText) as Map<String, dynamic>;
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    ciphertext[0] ^= 0xff; // flip a bit
    envelope['ciphertext'] = base64Encode(ciphertext);

    await expectLater(
      EncryptedBackupCodec.decrypt(envelope, 'correct-password'),
      throwsStateError,
    );
  });

  test('rejects an unrecognized envelope format', () async {
    await expectLater(
      EncryptedBackupCodec.decrypt({
        'format': 'something-else',
        'version': 1,
      }, 'any-password'),
      throwsFormatException,
    );
  });

  test('empty password is rejected up front', () async {
    await expectLater(
      EncryptedBackupCodec.encrypt('payload', ''),
      throwsArgumentError,
    );
  });

  test('isEncryptedEnvelope distinguishes plain backups', () {
    expect(
      EncryptedBackupCodec.isEncryptedEnvelope({
        'format': 'muthbat-notebook',
        'version': 1,
      }),
      isFalse,
    );
    expect(EncryptedBackupCodec.isEncryptedEnvelope('not a map'), isFalse);
    expect(EncryptedBackupCodec.isEncryptedEnvelope(null), isFalse);
  });
}
