import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/lib/crypto.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave_age/dotweave_age.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<AgeKeyPair> createAgeKeyPair() async {
  final identity = generateIdentity();

  return (identity: identity, recipient: await identityToRecipient(identity));
}

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-sync-crypto-',
    );

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  tearDown(() async {
    while (temporaryDirectories.isNotEmpty) {
      final directory = temporaryDirectories.removeLast();

      try {
        await Directory(directory).delete(recursive: true);
      } on FileSystemException {
        // Mirrors `rm(directory, { force: true, recursive: true })`.
      }
    }
  });

  group('sync crypto helpers', () {
    test('reads identities while ignoring blank lines and comments', () async {
      final workspace = await createWorkspace();
      final keyPair = await createAgeKeyPair();
      final identityFile = p.join(workspace, 'keys.txt');

      await File(identityFile).writeAsString(
        '\n# first\n${keyPair.identity}\n\n# second\n${keyPair.identity}\n',
      );

      expect(await readAgeIdentityLines(identityFile), [
        keyPair.identity,
        keyPair.identity,
      ]);
    });

    test('fails when no usable identities are present', () async {
      final workspace = await createWorkspace();
      final identityFile = p.join(workspace, 'keys.txt');

      await File(identityFile).writeAsString('\n# comment only\n\n');

      await expectLater(
        readAgeIdentityLines(identityFile),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            contains('No age identities were found'),
          ),
        ),
      );
    });

    test('deduplicates recipients derived from repeated identities', () async {
      final workspace = await createWorkspace();
      final keyPair = await createAgeKeyPair();
      final identityFile = p.join(workspace, 'keys.txt');

      await File(
        identityFile,
      ).writeAsString('${keyPair.identity}\n${keyPair.identity}\n');

      expect(await readAgeRecipientsFromIdentityFile(identityFile), [
        keyPair.recipient,
      ]);
    });

    test('creates a new identity file with a trailing newline', () async {
      final workspace = await createWorkspace();
      final identityFile = p.join(workspace, 'nested', 'keys.txt');

      final result = await createAgeIdentityFile(identityFile);
      final contents = await File(identityFile).readAsString();

      expect(contents.endsWith('\n'), true);
      expect(await readAgeRecipientsFromIdentityFile(identityFile), [
        result.recipient,
      ]);
    });

    test('validates and normalizes a supplied age identity', () async {
      final keyPair = await createAgeKeyPair();

      await expectLater(
        resolveAgeIdentity('  ${keyPair.identity}  '),
        completion((identity: keyPair.identity, recipient: keyPair.recipient)),
      );
    });

    test('rejects an invalid supplied age identity', () async {
      await expectLater(
        resolveAgeIdentity('not-a-key'),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            contains('Invalid age private key'),
          ),
        ),
      );
    });

    test('writes a supplied identity file with a trailing newline', () async {
      final workspace = await createWorkspace();
      final keyPair = await createAgeKeyPair();
      final identityFile = p.join(workspace, 'manual.txt');

      final result = await writeAgeIdentityFile(
        identityFile,
        '  ${keyPair.identity}  ',
      );

      expect(result, (
        identity: keyPair.identity,
        recipient: keyPair.recipient,
      ));
      expect(await File(identityFile).readAsString(), '${keyPair.identity}\n');
    });

    test('round-trips secret payloads through age encryption', () async {
      final workspace = await createWorkspace();
      final keyPair = await createAgeKeyPair();
      final identityFile = p.join(workspace, 'keys.txt');
      final payload = Uint8List.fromList(utf8.encode('super secret payload'));

      await File(identityFile).writeAsString('${keyPair.identity}\n');

      final ciphertext = await encryptSecretFile(payload, [keyPair.recipient]);
      final plaintext = await decryptSecretFile(ciphertext, identityFile);

      expect(utf8.decode(plaintext), 'super secret payload');
    });

    test(
      'fails to decrypt with the wrong identity or malformed ciphertext',
      () async {
        final workspace = await createWorkspace();
        final sender = await createAgeKeyPair();
        final wrongIdentity = await createAgeKeyPair();
        final senderIdentityFile = p.join(workspace, 'sender.txt');
        final wrongIdentityFile = p.join(workspace, 'wrong.txt');

        await File(senderIdentityFile).writeAsString('${sender.identity}\n');
        await File(
          wrongIdentityFile,
        ).writeAsString('${wrongIdentity.identity}\n');

        final ciphertext = await encryptSecretFile(
          Uint8List.fromList(utf8.encode('secret')),
          [sender.recipient],
        );

        await expectLater(
          decryptSecretFile(ciphertext, wrongIdentityFile),
          throwsA(anything),
        );
        await expectLater(
          decryptSecretFile('not a valid age payload', senderIdentityFile),
          throwsA(anything),
        );
      },
    );
  });
}
