/// Error codes attached to [AgeException] so callers can map failures
/// without parsing messages.
enum AgeExceptionCode {
  /// Malformed input (header, stanza, armor, bech32, base64, ...).
  invalidFormat,

  /// An `age1...` recipient string could not be parsed.
  invalidRecipient,

  /// An `AGE-SECRET-KEY-1...` identity string could not be parsed.
  invalidIdentity,

  /// The file is passphrase-encrypted (scrypt stanza), which is unsupported.
  passphraseUnsupported,

  /// None of the provided identities matched the file's recipient stanzas.
  noIdentityMatched,

  /// Cryptographic verification failed (MAC mismatch, AEAD open failure).
  decryptionFailed,

  /// The operation was invoked with invalid arguments or state.
  invalidArgument,
}

/// Exception thrown by the age encryption module.
class AgeException implements Exception {
  /// Creates an [AgeException] with a human readable [message].
  const AgeException(
    this.message, {
    this.code = AgeExceptionCode.invalidFormat,
  });

  /// Creates the canonical error for passphrase-encrypted (scrypt) files.
  const AgeException.passphraseUnsupported()
    : message = 'passphrase-encrypted files are not supported',
      code = AgeExceptionCode.passphraseUnsupported;

  /// Human readable description of the failure.
  final String message;

  /// Machine readable error category.
  final AgeExceptionCode code;

  @override
  String toString() => 'AgeException(${code.name}): $message';
}
