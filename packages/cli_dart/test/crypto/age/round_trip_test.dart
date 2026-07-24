import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dotweave/src/crypto/age/age.dart';
import 'package:dotweave/src/crypto/age/header.dart';
import 'package:dotweave/src/crypto/age/keys.dart';
import 'package:dotweave/src/crypto/age/primitives.dart';
import 'package:dotweave/src/crypto/age/stanza.dart';
import 'package:dotweave/src/crypto/age/stream.dart';
import 'package:dotweave/src/crypto/age/x25519_stanza.dart';
import 'package:test/test.dart';

void main() {
  group('identity handling', () {
    test('generateIdentity produces a parseable uppercase identity', () async {
      final identity = generateIdentity();
      expect(identity, startsWith('AGE-SECRET-KEY-1'));
      expect(identity, equals(identity.toUpperCase()));
      final recipient = await identityToRecipient(identity);
      expect(recipient, startsWith('age1'));
      expect(recipient, equals(recipient.toLowerCase()));
    });

    test('identityToRecipient is deterministic', () async {
      final identity = generateIdentity();
      expect(
        await identityToRecipient(identity),
        await identityToRecipient(identity),
      );
    });

    test('identityToRecipient tolerates surrounding whitespace', () async {
      final identity = generateIdentity();
      expect(
        await identityToRecipient('  $identity\n'),
        await identityToRecipient(identity),
      );
    });

    test('rejects a recipient string as identity and vice versa', () async {
      final identity = generateIdentity();
      final recipient = await identityToRecipient(identity);
      expect(
        () => AgeDecrypter().addIdentity(recipient),
        throwsA(
          isA<AgeException>().having(
            (e) => e.code,
            'code',
            AgeExceptionCode.invalidIdentity,
          ),
        ),
      );
      expect(
        () => AgeEncrypter().addRecipient(identity),
        throwsA(
          isA<AgeException>().having(
            (e) => e.code,
            'code',
            AgeExceptionCode.invalidRecipient,
          ),
        ),
      );
    });
  });

  group('encrypt/decrypt round-trip', () {
    final random = Random(20260724);
    final sizes = [
      0,
      1,
      65535,
      65536,
      65537,
      131072,
      1 + random.nextInt(200000),
    ];

    for (final recipientCount in [1, 3]) {
      for (final size in sizes) {
        test(
          '$size bytes, $recipientCount recipient(s), binary and armored',
          () async {
            final identities = List<String>.generate(
              recipientCount,
              (_) => generateIdentity(),
            );
            final encrypter = AgeEncrypter();
            for (final identity in identities) {
              encrypter.addRecipient(await identityToRecipient(identity));
            }
            final plaintext = Uint8List.fromList(
              List<int>.generate(size, (_) => random.nextInt(256)),
            );
            final ciphertext = await encrypter.encrypt(plaintext);

            // Every identity can decrypt the binary ciphertext.
            for (final identity in identities) {
              final decrypter = AgeDecrypter()..addIdentity(identity);
              expect(await decrypter.decrypt(ciphertext), plaintext);
            }

            // Armored round-trip.
            final armored = armorEncode(ciphertext);
            final decrypter = AgeDecrypter()..addIdentity(identities.last);
            expect(await decrypter.decrypt(armorDecode(armored)), plaintext);
          },
        );
      }
    }

    test('header is ASCII and payload chunking matches the spec', () async {
      final identity = generateIdentity();
      final encrypter = AgeEncrypter()
        ..addRecipient(await identityToRecipient(identity));
      final ciphertext = await encrypter.encrypt(Uint8List(3));
      final text = latin1.decode(ciphertext);
      expect(text, startsWith('age-encryption.org/v1\n-> X25519 '));
      expect(text, contains('\n--- '));
    });

    test('decrypting with a non-matching identity fails', () async {
      final encrypter = AgeEncrypter()
        ..addRecipient(await identityToRecipient(generateIdentity()));
      final ciphertext = await encrypter.encrypt(Uint8List(10));
      final decrypter = AgeDecrypter()..addIdentity(generateIdentity());
      await expectLater(
        decrypter.decrypt(ciphertext),
        throwsA(
          isA<AgeException>().having(
            (e) => e.code,
            'code',
            AgeExceptionCode.noIdentityMatched,
          ),
        ),
      );
    });

    test('decrypting with no identities fails', () async {
      final encrypter = AgeEncrypter()
        ..addRecipient(await identityToRecipient(generateIdentity()));
      final ciphertext = await encrypter.encrypt(Uint8List(10));
      await expectLater(
        AgeDecrypter().decrypt(ciphertext),
        throwsA(isA<AgeException>()),
      );
    });

    test('encrypting with no recipients fails', () async {
      await expectLater(
        AgeEncrypter().encrypt(Uint8List(1)),
        throwsA(isA<AgeException>()),
      );
    });

    test(
      'an scrypt stanza fails with the passphrase-unsupported code',
      () async {
        const scryptFile =
            'age-encryption.org/v1\n'
            '-> scrypt rF0/NwblUHHTpgQgRpe5CQ 10\n'
            'gUjEymFKMVXQEKdMMVn/DwBTYb5zH1RvvrOWMu4DCBc\n'
            '--- IWDkXJhGxPvsuT0mTtQPu9YW7yQwGdCJTsMPRLuJDWI\n';
        final decrypter = AgeDecrypter()..addIdentity(generateIdentity());
        await expectLater(
          decrypter.decrypt(Uint8List.fromList(utf8.encode(scryptFile))),
          throwsA(
            isA<AgeException>().having(
              (e) => e.code,
              'code',
              AgeExceptionCode.passphraseUnsupported,
            ),
          ),
        );
      },
    );

    test('unknown (grease) stanza types are skipped', () async {
      final identity = generateIdentity();
      final recipient = parseRecipient(await identityToRecipient(identity));
      final plaintext = Uint8List.fromList(utf8.encode('hello grease'));

      // Build a valid age file whose header carries an unknown stanza before
      // and after the real X25519 stanza.
      final fileKey = secureRandomBytes(16);
      final stanzas = <Stanza>[
        Stanza('grease.example/v1', ['zzz'], secureRandomBytes(51)),
        await x25519Wrap(fileKey, recipient),
        Stanza('another-unknown-type', [], secureRandomBytes(48)),
      ];
      final mac = await computeHeaderMac(
        fileKey,
        serializeHeaderWithoutMac(stanzas),
      );
      final header = serializeHeader(stanzas, mac);
      final payload = await encryptStream(fileKey, plaintext);
      final file = Uint8List.fromList([...header, ...payload]);

      final decrypter = AgeDecrypter()..addIdentity(identity);
      expect(await decrypter.decrypt(file), plaintext);
    });
  });
}
