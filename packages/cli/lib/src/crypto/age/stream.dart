/// age payload encryption: STREAM with ChaCha20-Poly1305 in 64 KiB chunks.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'exception.dart';
import 'primitives.dart';

/// Plaintext chunk size (64 KiB).
const int streamChunkSize = 65536;

const int _tagSize = 16;
const int _nonceSize = 16;
const int _encryptedChunkSize = streamChunkSize + _tagSize;

Future<Uint8List> _streamKey(Uint8List fileKey, Uint8List nonce) {
  return hkdfSha256(ikm: fileKey, salt: nonce, info: utf8.encode('payload'));
}

Uint8List _chunkNonce(int counter, {required bool isFinal}) {
  final nonce = Uint8List(12);
  // 11-byte big-endian counter (high 3 bytes stay zero) + 1 final-flag byte.
  ByteData.sublistView(nonce).setUint64(3, counter);
  nonce[11] = isFinal ? 0x01 : 0x00;
  return nonce;
}

/// Encrypts [plaintext] into an age payload: a random 16-byte file nonce
/// followed by the STREAM ciphertext.
Future<Uint8List> encryptStream(Uint8List fileKey, Uint8List plaintext) async {
  final nonce = secureRandomBytes(_nonceSize);
  final key = await _streamKey(fileKey, nonce);
  final output = BytesBuilder(copy: false)..add(nonce);
  var counter = 0;
  var offset = 0;
  while (true) {
    final end = min(offset + streamChunkSize, plaintext.length);
    final isFinal = end == plaintext.length;
    output.add(
      await chacha20Poly1305Seal(
        key: key,
        nonce: _chunkNonce(counter, isFinal: isFinal),
        plaintext: Uint8List.sublistView(plaintext, offset, end),
      ),
    );
    if (isFinal) {
      return output.toBytes();
    }
    counter++;
    offset = end;
  }
}

/// Decrypts an age [payload] (16-byte file nonce + STREAM ciphertext) into the
/// plaintext, rejecting truncation, trailing data, reordered chunks, and
/// missing or misplaced final-chunk flags.
Future<Uint8List> decryptStream(Uint8List fileKey, Uint8List payload) async {
  if (payload.length < _nonceSize) {
    throw const AgeException(
      'age payload is missing its file nonce',
      code: AgeExceptionCode.decryptionFailed,
    );
  }
  final nonce = Uint8List.sublistView(payload, 0, _nonceSize);
  final body = Uint8List.sublistView(payload, _nonceSize);
  if (body.length < _tagSize) {
    throw const AgeException(
      'age payload is shorter than one chunk tag',
      code: AgeExceptionCode.decryptionFailed,
    );
  }
  final key = await _streamKey(fileKey, nonce);
  final output = BytesBuilder(copy: false);
  var counter = 0;
  var offset = 0;
  while (true) {
    final remaining = body.length - offset;
    final take = min(_encryptedChunkSize, remaining);
    if (take < _tagSize) {
      throw const AgeException(
        'age payload chunk is truncated',
        code: AgeExceptionCode.decryptionFailed,
      );
    }
    final isFinal = take == remaining;
    final plaintext = await chacha20Poly1305Open(
      key: key,
      nonce: _chunkNonce(counter, isFinal: isFinal),
      ciphertext: Uint8List.sublistView(body, offset, offset + take),
    );
    if (isFinal && plaintext.isEmpty && counter != 0) {
      throw const AgeException(
        'age payload has an empty final chunk after non-empty chunks',
        code: AgeExceptionCode.decryptionFailed,
      );
    }
    output.add(plaintext);
    if (isFinal) {
      return output.toBytes();
    }
    counter++;
    offset += take;
  }
}
