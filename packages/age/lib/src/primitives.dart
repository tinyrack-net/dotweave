/// Cryptographic primitives for the age module.
///
/// This is the only file in the age module allowed to import
/// `package:cryptography`. Everything else goes through these wrappers.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'exception.dart';

final X25519 _x25519 = X25519();
final Cipher _chacha20Poly1305 = Chacha20.poly1305Aead();
final Hmac _hmacSha256 = Hmac.sha256();

/// Generates [length] cryptographically secure random bytes.
Uint8List secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Computes the X25519 public key for a 32-byte private [scalar].
///
/// The scalar is clamped per RFC 7748 before the scalar multiplication, which
/// matches how age treats identity scalars.
Future<Uint8List> x25519PublicKey(Uint8List scalar) async {
  if (scalar.length != 32) {
    throw const AgeException(
      'X25519 private scalar must be 32 bytes',
      code: AgeExceptionCode.invalidArgument,
    );
  }
  final keyPair = await _x25519.newKeyPairFromSeed(scalar);
  final publicKey = await keyPair.extractPublicKey();
  return Uint8List.fromList(publicKey.bytes);
}

/// Computes the X25519 shared secret between a private [scalar] and a peer's
/// 32-byte [peerPublicKey]. Rejects an all-zero result (low-order point) as
/// required by the age spec.
Future<Uint8List> x25519SharedSecret(
  Uint8List scalar,
  Uint8List peerPublicKey,
) async {
  if (scalar.length != 32 || peerPublicKey.length != 32) {
    throw const AgeException(
      'X25519 keys must be 32 bytes',
      code: AgeExceptionCode.invalidArgument,
    );
  }
  final keyPair = await _x25519.newKeyPairFromSeed(scalar);
  final secretKey = await _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
  );
  final shared = Uint8List.fromList(await secretKey.extractBytes());
  if (shared.length != 32) {
    throw const AgeException(
      'X25519 shared secret has unexpected length',
      code: AgeExceptionCode.decryptionFailed,
    );
  }
  var accumulator = 0;
  for (final byte in shared) {
    accumulator |= byte;
  }
  if (accumulator == 0) {
    throw const AgeException(
      'X25519 shared secret is the all-zero value (low-order point)',
      code: AgeExceptionCode.decryptionFailed,
    );
  }
  return shared;
}

/// HKDF-SHA-256 with the given input key material, salt, and info.
Future<Uint8List> hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  int length = 32,
}) async {
  final hkdf = Hkdf(hmac: _hmacSha256, outputLength: length);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    // package:cryptography's Hkdf takes the HKDF salt via `nonce:`.
    nonce: salt,
    info: info,
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// HMAC-SHA-256 of [message] under [key].
Future<Uint8List> hmacSha256(List<int> key, List<int> message) async {
  final mac = await _hmacSha256.calculateMac(
    message,
    secretKey: SecretKey(key),
  );
  return Uint8List.fromList(mac.bytes);
}

/// ChaCha20-Poly1305 seal: returns `ciphertext || 16-byte tag`.
Future<Uint8List> chacha20Poly1305Seal({
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List plaintext,
}) async {
  _checkAeadKeyAndNonce(key, nonce);
  final box = await _chacha20Poly1305.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  final result = Uint8List(box.cipherText.length + box.mac.bytes.length);
  result.setAll(0, box.cipherText);
  result.setAll(box.cipherText.length, box.mac.bytes);
  return result;
}

/// ChaCha20-Poly1305 open: takes `ciphertext || 16-byte tag`, returns the
/// plaintext, or throws [AgeException] on authentication failure.
Future<Uint8List> chacha20Poly1305Open({
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List ciphertext,
}) async {
  _checkAeadKeyAndNonce(key, nonce);
  if (ciphertext.length < 16) {
    throw const AgeException(
      'ChaCha20-Poly1305 ciphertext shorter than its tag',
      code: AgeExceptionCode.decryptionFailed,
    );
  }
  final box = SecretBox(
    Uint8List.sublistView(ciphertext, 0, ciphertext.length - 16),
    nonce: nonce,
    mac: Mac(Uint8List.sublistView(ciphertext, ciphertext.length - 16)),
  );
  try {
    final plaintext = await _chacha20Poly1305.decrypt(
      box,
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(plaintext);
  } on SecretBoxAuthenticationError {
    throw const AgeException(
      'ChaCha20-Poly1305 authentication failed',
      code: AgeExceptionCode.decryptionFailed,
    );
  }
}

void _checkAeadKeyAndNonce(Uint8List key, Uint8List nonce) {
  if (key.length != 32) {
    throw const AgeException(
      'ChaCha20-Poly1305 key must be 32 bytes',
      code: AgeExceptionCode.invalidArgument,
    );
  }
  if (nonce.length != 12) {
    throw const AgeException(
      'ChaCha20-Poly1305 nonce must be 12 bytes',
      code: AgeExceptionCode.invalidArgument,
    );
  }
}

/// Constant-time comparison of two byte strings of equal length.
///
/// Returns false immediately when lengths differ (length is not secret).
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}
