import 'dart:math';
import 'dart:typed_data';

import 'package:dotweave_age/src/exception.dart';
import 'package:dotweave_age/src/stream.dart';
import 'package:test/test.dart';

void main() {
  final fileKey = Uint8List.fromList(List<int>.generate(16, (i) => i));

  Uint8List patternedBytes(int size) {
    return Uint8List.fromList(List<int>.generate(size, (i) => (i * 17) & 0xff));
  }

  group('STREAM round-trip', () {
    for (final size in [0, 1, 65535, 65536, 65537, 131072, 131073]) {
      test('round-trips $size bytes', () async {
        final plaintext = patternedBytes(size);
        final payload = await encryptStream(fileKey, plaintext);
        final expectedChunks = size == 0 ? 1 : (size / streamChunkSize).ceil();
        expect(payload.length, 16 + size + 16 * expectedChunks);
        expect(await decryptStream(fileKey, payload), plaintext);
      });
    }
  });

  group('STREAM failure modes', () {
    test('rejects an empty payload', () async {
      await expectLater(
        decryptStream(fileKey, Uint8List(0)),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects a payload with only a nonce', () async {
      await expectLater(
        decryptStream(fileKey, Uint8List(16)),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects a truncated final chunk', () async {
      final payload = await encryptStream(fileKey, patternedBytes(100));
      await expectLater(
        decryptStream(
          fileKey,
          Uint8List.sublistView(payload, 0, payload.length - 1),
        ),
        throwsA(isA<AgeException>()),
      );
    });

    test(
      'rejects truncation at a chunk boundary (missing final flag)',
      () async {
        final payload = await encryptStream(
          fileKey,
          patternedBytes(2 * streamChunkSize),
        );
        // Keep the nonce and only the first encrypted chunk: the decrypter will
        // treat it as final (flag 0x01) but it was sealed with flag 0x00.
        final truncated = Uint8List.sublistView(
          payload,
          0,
          16 + streamChunkSize + 16,
        );
        await expectLater(
          decryptStream(fileKey, truncated),
          throwsA(isA<AgeException>()),
        );
      },
    );

    test('rejects trailing data appended to the payload', () async {
      final payload = await encryptStream(fileKey, patternedBytes(100));
      final extended = Uint8List(payload.length + 32);
      extended.setAll(0, payload);
      await expectLater(
        decryptStream(fileKey, extended),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects a trailing partial chunk shorter than a tag', () async {
      final payload = await encryptStream(
        fileKey,
        patternedBytes(streamChunkSize),
      );
      final extended = Uint8List(payload.length + 5);
      extended.setAll(0, payload);
      await expectLater(
        decryptStream(fileKey, extended),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects an empty final chunk after non-empty chunks', () async {
      // Build a payload whose last chunk is empty by construction: encrypt a
      // one-chunk plaintext, then append a forged empty chunk. Whatever the
      // attacker appends, decryption must fail (either the flag moves off the
      // real final chunk or the forged chunk fails to authenticate).
      final payload = await encryptStream(
        fileKey,
        patternedBytes(streamChunkSize),
      );
      final extended = Uint8List(payload.length + 16);
      extended.setAll(0, payload);
      await expectLater(
        decryptStream(fileKey, extended),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects swapped chunks', () async {
      final payload = await encryptStream(
        fileKey,
        patternedBytes(3 * streamChunkSize),
      );
      const encChunk = streamChunkSize + 16;
      final swapped = Uint8List.fromList(payload);
      swapped.setRange(16, 16 + encChunk, payload, 16 + encChunk);
      swapped.setRange(16 + encChunk, 16 + 2 * encChunk, payload, 16);
      await expectLater(
        decryptStream(fileKey, swapped),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects a flipped payload byte', () async {
      final payload = await encryptStream(fileKey, patternedBytes(1000));
      payload[42] ^= 0x01;
      await expectLater(
        decryptStream(fileKey, payload),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects the wrong file key', () async {
      final payload = await encryptStream(fileKey, patternedBytes(10));
      final wrongKey = Uint8List.fromList(fileKey)..[0] ^= 0xff;
      await expectLater(
        decryptStream(wrongKey, payload),
        throwsA(isA<AgeException>()),
      );
    });

    test('round-trips a random length', () async {
      final size = Random(1234).nextInt(3 * streamChunkSize);
      final plaintext = patternedBytes(size);
      final payload = await encryptStream(fileKey, plaintext);
      expect(await decryptStream(fileKey, payload), plaintext);
    });
  });
}
