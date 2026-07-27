import 'dart:io';
import 'dart:typed_data';

import 'package:dartage/dartage.dart';
import 'package:path/path.dart' as p;

import 'error.dart';
import 'string.dart';

/// A validated age identity paired with its derived recipient.
typedef AgeKeyPair = ({String identity, String recipient});

/// Validates and normalizes a single age identity for dotweave use.
Future<AgeKeyPair> resolveAgeIdentity(String identity) async {
  final normalizedIdentity = identity.trim();

  if (normalizedIdentity == '') {
    throw DotweaveError(
      'Age private key cannot be empty.',
      code: 'AGE_IDENTITY_INVALID',
      hint: "Provide a valid age private key starting with 'AGE-SECRET-KEY-'.",
    );
  }

  try {
    return (
      identity: normalizedIdentity,
      recipient: await identityToRecipient(normalizedIdentity),
    );
  } on Object catch (error) {
    throw wrapUnknownError(
      'Invalid age private key.',
      error,
      code: 'AGE_IDENTITY_INVALID',
      hint: "Provide a valid age private key starting with 'AGE-SECRET-KEY-'.",
    );
  }
}

/// Reads usable age identities from an identity file.
Future<List<String>> readAgeIdentityLines(String identityFile) async {
  final contents = await File(identityFile).readAsString();
  final identities = contents
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) {
        return line != '' && !line.startsWith('#');
      })
      .toList();

  if (identities.isEmpty) {
    throw DotweaveError(
      'No age identities were found in the configured identity file.',
      code: 'AGE_IDENTITY_EMPTY',
      details: ['Identity file: $identityFile'],
      hint:
          'Add at least one age private key to the identity file, '
          "or run 'dotweave init' to generate one.",
    );
  }

  return identities;
}

/// Derives the unique recipient list represented by an identity file.
Future<List<String>> readAgeRecipientsFromIdentityFile(
  String identityFile,
) async {
  final identities = await readAgeIdentityLines(identityFile);
  List<String> recipients;

  try {
    recipients = await Future.wait(
      identities.map((identity) async {
        return identityToRecipient(identity);
      }),
    );
  } on Object catch (error) {
    throw wrapUnknownError(
      'Failed to read age recipients from the configured identity file.',
      error,
      code: 'AGE_RECIPIENT_READ_FAILED',
      details: ['Identity file: $identityFile'],
      hint: 'Check that the identity file contains valid age private keys.',
    );
  }

  return {...recipients}.toList();
}

/// Generates and persists a new age identity file for dotweave.
Future<AgeKeyPair> createAgeIdentityFile(String identityFile) async {
  final identity = generateIdentity();
  final recipient = await identityToRecipient(identity);

  await Directory(p.dirname(identityFile)).create(recursive: true);
  await File(identityFile).writeAsString(ensureTrailingNewline(identity));

  return (identity: identity, recipient: recipient);
}

/// Persists a supplied age identity after validating it.
Future<AgeKeyPair> writeAgeIdentityFile(
  String identityFile,
  String identity,
) async {
  final resolvedIdentity = await resolveAgeIdentity(identity);

  await Directory(p.dirname(identityFile)).create(recursive: true);
  await File(
    identityFile,
  ).writeAsString(ensureTrailingNewline(resolvedIdentity.identity));

  return resolvedIdentity;
}

/// Encrypts secret file contents for the configured recipients.
Future<String> encryptSecretFile(
  Uint8List contents,
  List<String> recipients,
) async {
  final encrypter = AgeEncrypter();

  for (final recipient in recipients) {
    encrypter.addRecipient(recipient);
  }

  final ciphertext = await encrypter.encrypt(contents);

  return armorEncode(ciphertext);
}

/// Decrypts an armored secret artifact with identities from the configured
/// file.
Future<Uint8List> decryptSecretFile(
  String armoredCiphertext,
  String identityFile,
) async {
  final decrypter = AgeDecrypter();
  final identities = await readAgeIdentityLines(identityFile);

  for (final identity in identities) {
    decrypter.addIdentity(identity);
  }

  try {
    return await decrypter.decrypt(armorDecode(armoredCiphertext));
  } on Object catch (error) {
    throw wrapUnknownError(
      'Failed to decrypt a secret artifact.',
      error,
      code: 'AGE_DECRYPT_FAILED',
      details: ['Identity file: $identityFile'],
      hint:
          'Check that the artifact is valid age data and that the configured '
          'identity file matches one of its recipients.',
    );
  }
}
