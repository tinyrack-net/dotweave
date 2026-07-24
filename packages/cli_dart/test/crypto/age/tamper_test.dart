import 'dart:convert';
import 'dart:typed_data';

import 'package:dotweave/src/crypto/age/age.dart';
import 'package:dotweave/src/crypto/age/stream.dart';
import 'package:test/test.dart';

void main() {
  late String identity;
  late Uint8List plaintext;
  late Uint8List ciphertext;
  late int payloadOffset;

  Future<void> expectDecryptFails(Uint8List tampered) async {
    final decrypter = AgeDecrypter()..addIdentity(identity);
    await expectLater(
      decrypter.decrypt(tampered),
      throwsA(isA<AgeException>()),
    );
  }

  setUpAll(() async {
    identity = generateIdentity();
    final encrypter = AgeEncrypter()
      ..addRecipient(await identityToRecipient(identity));
    // Three full chunks so chunk swapping is possible.
    plaintext = Uint8List.fromList(
      List<int>.generate(3 * streamChunkSize, (i) => (i * 7) & 0xff),
    );
    ciphertext = await encrypter.encrypt(plaintext);
    final text = latin1.decode(ciphertext);
    final macLineStart = text.indexOf('\n--- ') + 1;
    payloadOffset = text.indexOf('\n', macLineStart) + 1;
  });

  test('the untampered ciphertext decrypts (sanity check)', () async {
    final decrypter = AgeDecrypter()..addIdentity(identity);
    expect(await decrypter.decrypt(ciphertext), plaintext);
  });

  test('flipping a MAC byte fails', () async {
    final text = latin1.decode(ciphertext);
    final macIndex = text.indexOf('\n--- ') + 5;
    final tampered = Uint8List.fromList(ciphertext);
    // Swap the base64 character for a different valid one.
    tampered[macIndex] = tampered[macIndex] == 0x41
        ? 0x42
        : 0x41; // 'A' <-> 'B'
    await expectDecryptFails(tampered);
  });

  test('flipping a stanza body byte fails', () async {
    final text = latin1.decode(ciphertext);
    // First stanza body line starts after the first '-> X25519 ...' line.
    final stanzaLineEnd = text.indexOf('\n', text.indexOf('-> X25519')) + 1;
    final tampered = Uint8List.fromList(ciphertext);
    tampered[stanzaLineEnd] = tampered[stanzaLineEnd] == 0x41
        ? 0x42
        : 0x41; // 'A' <-> 'B'
    await expectDecryptFails(tampered);
  });

  test('flipping a payload byte fails', () async {
    final tampered = Uint8List.fromList(ciphertext);
    tampered[tampered.length - 1] ^= 0x01;
    await expectDecryptFails(tampered);
  });

  test('truncating the final chunk fails', () async {
    await expectDecryptFails(
      Uint8List.sublistView(ciphertext, 0, ciphertext.length - 1),
    );
  });

  test(
    'truncating at a chunk boundary (clearing the final flag) fails',
    () async {
      const encChunk = streamChunkSize + 16;
      // Keep header + nonce + first two encrypted chunks; the second chunk was
      // sealed with final flag 0x00 but will be read as the final chunk.
      await expectDecryptFails(
        Uint8List.sublistView(ciphertext, 0, payloadOffset + 16 + 2 * encChunk),
      );
    },
  );

  test('swapping two chunks fails', () async {
    const encChunk = streamChunkSize + 16;
    final bodyStart = payloadOffset + 16;
    final tampered = Uint8List.fromList(ciphertext);
    tampered.setRange(
      bodyStart,
      bodyStart + encChunk,
      ciphertext,
      bodyStart + encChunk,
    );
    tampered.setRange(
      bodyStart + encChunk,
      bodyStart + 2 * encChunk,
      ciphertext,
      bodyStart,
    );
    await expectDecryptFails(tampered);
  });

  test('a bech32 checksum off-by-one in the identity fails', () {
    final last = identity[identity.length - 1];
    final replacement = last == 'Q' ? 'P' : 'Q';
    final corrupted = identity.substring(0, identity.length - 1) + replacement;
    expect(
      () => AgeDecrypter().addIdentity(corrupted),
      throwsA(
        isA<AgeException>().having(
          (e) => e.code,
          'code',
          AgeExceptionCode.invalidIdentity,
        ),
      ),
    );
  });

  test('a bech32 checksum off-by-one in the recipient fails', () async {
    final recipient = await identityToRecipient(identity);
    final last = recipient[recipient.length - 1];
    final replacement = last == 'q' ? 'p' : 'q';
    final corrupted =
        recipient.substring(0, recipient.length - 1) + replacement;
    expect(
      () => AgeEncrypter().addRecipient(corrupted),
      throwsA(
        isA<AgeException>().having(
          (e) => e.code,
          'code',
          AgeExceptionCode.invalidRecipient,
        ),
      ),
    );
  });
}
