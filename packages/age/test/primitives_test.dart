import 'dart:typed_data';

import 'package:dotweave_age/src/exception.dart';
import 'package:dotweave_age/src/primitives.dart';
import 'package:test/test.dart';

Uint8List hexToBytes(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return bytes;
}

String bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  group('x25519', () {
    // RFC 7748 section 6.1 Diffie-Hellman test vectors.
    final alicePrivate = hexToBytes(
      '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
    );
    final alicePublic = hexToBytes(
      '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
    );
    final bobPrivate = hexToBytes(
      '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb',
    );
    final bobPublic = hexToBytes(
      'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
    );
    const sharedHex =
        '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742';

    test('derives RFC 7748 public keys', () async {
      expect(
        bytesToHex(await x25519PublicKey(alicePrivate)),
        bytesToHex(alicePublic),
      );
      expect(
        bytesToHex(await x25519PublicKey(bobPrivate)),
        bytesToHex(bobPublic),
      );
    });

    test('derives the RFC 7748 shared secret from both sides', () async {
      expect(
        bytesToHex(await x25519SharedSecret(alicePrivate, bobPublic)),
        sharedHex,
      );
      expect(
        bytesToHex(await x25519SharedSecret(bobPrivate, alicePublic)),
        sharedHex,
      );
    });

    test('rejects an all-zero shared secret (low-order point)', () async {
      // The all-zero public key is a low-order point; X25519 output is zero.
      await expectLater(
        x25519SharedSecret(alicePrivate, Uint8List(32)),
        throwsA(
          isA<AgeException>().having(
            (e) => e.code,
            'code',
            AgeExceptionCode.decryptionFailed,
          ),
        ),
      );
    });
  });

  group('hkdfSha256', () {
    test('matches RFC 5869 test case 1', () async {
      final okm = await hkdfSha256(
        ikm: hexToBytes('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        salt: hexToBytes('000102030405060708090a0b0c'),
        info: hexToBytes('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
      );
      expect(
        bytesToHex(okm),
        '3cb25f25faacd57a90434f64d0362f2a'
        '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });
  });

  group('hmacSha256', () {
    test('matches RFC 4231 test case 2', () async {
      final mac = await hmacSha256(
        'Jefe'.codeUnits,
        'what do ya want for nothing?'.codeUnits,
      );
      expect(
        bytesToHex(mac),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });
  });

  group('chacha20Poly1305', () {
    test('seals and opens round-trip', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final nonce = Uint8List.fromList(List<int>.generate(12, (i) => i));
      final plaintext = Uint8List.fromList('an age file key.'.codeUnits);
      final sealed = await chacha20Poly1305Seal(
        key: key,
        nonce: nonce,
        plaintext: plaintext,
      );
      expect(sealed.length, plaintext.length + 16);
      final opened = await chacha20Poly1305Open(
        key: key,
        nonce: nonce,
        ciphertext: sealed,
      );
      expect(opened, plaintext);
    });

    test('rejects a tampered ciphertext', () async {
      final key = Uint8List(32);
      final nonce = Uint8List(12);
      final sealed = await chacha20Poly1305Seal(
        key: key,
        nonce: nonce,
        plaintext: Uint8List(16),
      );
      sealed[0] ^= 0x01;
      await expectLater(
        chacha20Poly1305Open(key: key, nonce: nonce, ciphertext: sealed),
        throwsA(
          isA<AgeException>().having(
            (e) => e.code,
            'code',
            AgeExceptionCode.decryptionFailed,
          ),
        ),
      );
    });
  });

  group('constantTimeEquals', () {
    test('compares equal and unequal byte strings', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(constantTimeEquals(<int>[], <int>[]), isTrue);
    });
  });
}
