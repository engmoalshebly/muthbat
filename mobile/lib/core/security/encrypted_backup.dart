import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Wraps an arbitrary JSON backup string in a password-protected envelope
/// using AES-256-GCM, with the key derived via PBKDF2-HMAC-SHA256 (600,000
/// iterations — OWASP's current recommendation for that combination). Never
/// hand-rolls cipher or padding logic — everything cryptographic goes
/// through `package:cryptography`.
class EncryptedBackupCodec {
  EncryptedBackupCodec._();

  static const format = 'muthbat-notebook-encrypted';
  static const _version = 1;
  static const _pbkdf2Iterations = 600000;
  static const _saltLength = 16;
  static const _keyBits = 256;

  static final _cipher = AesGcm.with256bits();

  static Pbkdf2 _kdf() =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _pbkdf2Iterations, bits: _keyBits);

  /// Returns a JSON envelope; [plaintext] is typically an existing backup
  /// envelope string (kept opaque here — this codec only adds a layer).
  static Future<String> encrypt(String plaintext, String password) async {
    if (password.isEmpty) {
      throw ArgumentError('Password must not be empty');
    }
    final salt = _randomBytes(_saltLength);
    final secretKey = await _kdf().deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final secretBox = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
    );
    return jsonEncode({
      'format': format,
      'version': _version,
      'kdf': 'pbkdf2-hmac-sha256',
      'iterations': _pbkdf2Iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    });
  }

  /// Throws [FormatException] for a malformed envelope and [StateError] when
  /// [password] is wrong or the file was tampered with (AEAD tag mismatch).
  static Future<String> decrypt(
    Map<String, dynamic> envelope,
    String password,
  ) async {
    if (envelope['format'] != format || envelope['version'] != _version) {
      throw const FormatException('صيغة النسخة المشفَّرة غير مدعومة');
    }
    final iterations = envelope['iterations'];
    final salt = envelope['salt'];
    final nonce = envelope['nonce'];
    final cipherText = envelope['ciphertext'];
    final mac = envelope['mac'];
    if (iterations is! int ||
        salt is! String ||
        nonce is! String ||
        cipherText is! String ||
        mac is! String) {
      throw const FormatException('النسخة المشفَّرة تالفة');
    }

    final secretKey = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: _keyBits,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: base64Decode(salt));

    try {
      final clear = await _cipher.decrypt(
        SecretBox(
          base64Decode(cipherText),
          nonce: base64Decode(nonce),
          mac: Mac(base64Decode(mac)),
        ),
        secretKey: secretKey,
      );
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw StateError('كلمة المرور غير صحيحة أو النسخة تالفة.');
    }
  }

  static bool isEncryptedEnvelope(Object? decodedJson) =>
      decodedJson is Map && decodedJson['format'] == format;

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
