/// Pure-Dart age v1 encryption (X25519 recipients only).
///
/// Mirrors the API surface of the npm `age-encryption` package consumed by the
/// TypeScript CLI: [AgeEncrypter], [AgeDecrypter], `armorEncode`/`armorDecode`,
/// `generateIdentity`, and `identityToRecipient`.
library;

import 'dart:typed_data';

import 'exception.dart';
import 'header.dart';
import 'keys.dart';
import 'primitives.dart';
import 'stanza.dart';
import 'stream.dart';
import 'x25519_stanza.dart';

export 'armor.dart' show armorDecode, armorEncode;
export 'exception.dart';
export 'keys.dart' show generateIdentity, identityToRecipient;

const String _scryptStanzaType = 'scrypt';

/// Encrypts data to one or more X25519 recipients (age v1 binary format).
class AgeEncrypter {
  final List<Uint8List> _recipients = [];

  /// Adds an `age1...` recipient. Throws [AgeException] if invalid.
  void addRecipient(String recipient) {
    _recipients.add(parseRecipient(recipient));
  }

  /// Encrypts [plaintext], returning the binary age file.
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    if (_recipients.isEmpty) {
      throw const AgeException(
        'no recipients were added to the encrypter',
        code: AgeExceptionCode.invalidArgument,
      );
    }
    final fileKey = secureRandomBytes(16);
    final stanzas = <Stanza>[
      for (final recipient in _recipients) await x25519Wrap(fileKey, recipient),
    ];
    final mac = await computeHeaderMac(
      fileKey,
      serializeHeaderWithoutMac(stanzas),
    );
    final header = serializeHeader(stanzas, mac);
    final payload = await encryptStream(fileKey, plaintext);
    final file = Uint8List(header.length + payload.length);
    file.setAll(0, header);
    file.setAll(header.length, payload);
    return file;
  }
}

/// Decrypts age v1 binary files with one or more X25519 identities.
class AgeDecrypter {
  final List<Uint8List> _identities = [];

  /// Adds an `AGE-SECRET-KEY-1...` identity. Throws [AgeException] if invalid.
  void addIdentity(String identity) {
    _identities.add(parseIdentity(identity));
  }

  /// Decrypts a binary age [file], returning the plaintext.
  ///
  /// Unknown stanza types are skipped (grease tolerance); an `scrypt` stanza
  /// causes an [AgeException] with
  /// [AgeExceptionCode.passphraseUnsupported]; the header MAC is verified
  /// with the recovered file key before the payload is decrypted.
  Future<Uint8List> decrypt(Uint8List file) async {
    if (_identities.isEmpty) {
      throw const AgeException(
        'no identities were added to the decrypter',
        code: AgeExceptionCode.invalidArgument,
      );
    }
    final header = parseHeader(file);
    if (header.stanzas.any((stanza) => stanza.type == _scryptStanzaType)) {
      throw const AgeException.passphraseUnsupported();
    }
    final fileKey = await _unwrapFileKey(header.stanzas);
    if (fileKey == null) {
      throw const AgeException(
        'no identity matched any of the file recipients',
        code: AgeExceptionCode.noIdentityMatched,
      );
    }
    await verifyHeaderMac(fileKey, header);
    return decryptStream(
      fileKey,
      Uint8List.sublistView(file, header.payloadOffset),
    );
  }

  Future<Uint8List?> _unwrapFileKey(List<Stanza> stanzas) async {
    final identityKeys = <(Uint8List, Uint8List)>[
      for (final scalar in _identities) (scalar, await x25519PublicKey(scalar)),
    ];
    for (final stanza in stanzas) {
      if (stanza.type != x25519StanzaType) {
        continue;
      }
      for (final (scalar, publicKey) in identityKeys) {
        final fileKey = await x25519Unwrap(stanza, scalar, publicKey);
        if (fileKey != null) {
          return fileKey;
        }
      }
    }
    return null;
  }
}
