/// age X25519 identity and recipient string handling.
///
/// Identities are encoded as uppercase `AGE-SECRET-KEY-1...`, recipients as
/// lowercase `age1...`.
library;

import 'dart:typed_data';

import 'bech32.dart';
import 'exception.dart';
import 'primitives.dart';

const String _recipientHrp = 'age';
const String _identityHrp = 'age-secret-key-';
const String _identityHrpUpper = 'AGE-SECRET-KEY-';

/// Generates a new age identity string (`AGE-SECRET-KEY-1...`).
String generateIdentity() {
  return formatIdentity(secureRandomBytes(32));
}

/// Derives the recipient string (`age1...`) for an [identity] string.
Future<String> identityToRecipient(String identity) async {
  final scalar = parseIdentity(identity);
  return formatRecipient(await x25519PublicKey(scalar));
}

/// Parses an `age1...` recipient string into its 32-byte X25519 public key.
Uint8List parseRecipient(String recipient) {
  final ({String hrp, Uint8List data}) decoded;
  try {
    decoded = bech32Decode(recipient.trim());
  } on AgeException catch (error) {
    throw AgeException(
      'invalid age recipient: ${error.message}',
      code: AgeExceptionCode.invalidRecipient,
    );
  }
  if (decoded.hrp != _recipientHrp || decoded.data.length != 32) {
    throw const AgeException(
      'invalid age recipient: expected "age1..." encoding a 32-byte key',
      code: AgeExceptionCode.invalidRecipient,
    );
  }
  return decoded.data;
}

/// Parses an `AGE-SECRET-KEY-1...` identity string into its 32-byte scalar.
Uint8List parseIdentity(String identity) {
  final ({String hrp, Uint8List data}) decoded;
  try {
    decoded = bech32Decode(identity.trim());
  } on AgeException catch (error) {
    throw AgeException(
      'invalid age identity: ${error.message}',
      code: AgeExceptionCode.invalidIdentity,
    );
  }
  if (decoded.hrp != _identityHrp || decoded.data.length != 32) {
    throw const AgeException(
      'invalid age identity: expected "AGE-SECRET-KEY-1..." encoding a 32-byte key',
      code: AgeExceptionCode.invalidIdentity,
    );
  }
  return decoded.data;
}

/// Encodes a 32-byte X25519 public key as an `age1...` recipient string.
String formatRecipient(Uint8List publicKey) {
  return bech32Encode(_recipientHrp, publicKey);
}

/// Encodes a 32-byte scalar as an uppercase `AGE-SECRET-KEY-1...` string.
String formatIdentity(Uint8List scalar) {
  return bech32Encode(_identityHrpUpper, scalar);
}
