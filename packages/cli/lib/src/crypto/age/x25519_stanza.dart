/// X25519 recipient stanza: wraps/unwraps the 16-byte file key.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'exception.dart';
import 'primitives.dart';
import 'stanza.dart';

/// The stanza type used by native X25519 recipients.
const String x25519StanzaType = 'X25519';

const String _x25519Info = 'age-encryption.org/v1/X25519';

/// Wraps [fileKey] for [recipientPublicKey], returning an `X25519` stanza with
/// the ephemeral public key as its sole argument and the 32-byte
/// ChaCha20-Poly1305 sealed file key (16-byte key + 16-byte tag) as its body.
Future<Stanza> x25519Wrap(
  Uint8List fileKey,
  Uint8List recipientPublicKey,
) async {
  final ephemeralSecret = secureRandomBytes(32);
  final ephemeralPublic = await x25519PublicKey(ephemeralSecret);
  final sharedSecret = await x25519SharedSecret(
    ephemeralSecret,
    recipientPublicKey,
  );
  final wrapKey = await _wrapKey(
    sharedSecret,
    ephemeralPublic,
    recipientPublicKey,
  );
  final body = await chacha20Poly1305Seal(
    key: wrapKey,
    nonce: Uint8List(12),
    plaintext: fileKey,
  );
  return Stanza(x25519StanzaType, [encodeBase64NoPad(ephemeralPublic)], body);
}

/// Attempts to unwrap the file key from an `X25519` [stanza] using an identity
/// (its private [identityScalar] and derived [identityPublicKey]).
///
/// Returns the 16-byte file key, or null when the identity does not match
/// this stanza. Structurally malformed X25519 stanzas throw [AgeException].
Future<Uint8List?> x25519Unwrap(
  Stanza stanza,
  Uint8List identityScalar,
  Uint8List identityPublicKey,
) async {
  if (stanza.type != x25519StanzaType) {
    throw const AgeException(
      'not an X25519 stanza',
      code: AgeExceptionCode.invalidArgument,
    );
  }
  if (stanza.args.length != 1) {
    throw const AgeException(
      'invalid X25519 stanza: expected exactly one argument',
    );
  }
  final ephemeralPublic = decodeBase64NoPad(stanza.args.first);
  if (ephemeralPublic.length != 32) {
    throw const AgeException(
      'invalid X25519 stanza: ephemeral share must be 32 bytes',
    );
  }
  if (stanza.body.length != 32) {
    throw const AgeException('invalid X25519 stanza: body must be 32 bytes');
  }
  final sharedSecret = await x25519SharedSecret(
    identityScalar,
    ephemeralPublic,
  );
  final wrapKey = await _wrapKey(
    sharedSecret,
    ephemeralPublic,
    identityPublicKey,
  );
  try {
    final fileKey = await chacha20Poly1305Open(
      key: wrapKey,
      nonce: Uint8List(12),
      ciphertext: stanza.body,
    );
    if (fileKey.length != 16) {
      throw const AgeException(
        'invalid X25519 stanza: file key must be 16 bytes',
      );
    }
    return fileKey;
  } on AgeException catch (error) {
    if (error.code == AgeExceptionCode.decryptionFailed) {
      // Wrong identity for this stanza; the caller should try the next one.
      return null;
    }
    rethrow;
  }
}

Future<Uint8List> _wrapKey(
  Uint8List sharedSecret,
  Uint8List ephemeralPublic,
  Uint8List recipientPublic,
) {
  final salt = Uint8List(ephemeralPublic.length + recipientPublic.length);
  salt.setAll(0, ephemeralPublic);
  salt.setAll(ephemeralPublic.length, recipientPublic);
  return hkdfSha256(
    ikm: sharedSecret,
    salt: salt,
    info: utf8.encode(_x25519Info),
  );
}
