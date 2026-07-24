import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dotweave/src/crypto/age/age.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Runs the vendored subset of the official C2SP CCTV age test vectors
/// (see test/fixtures/age_testkit/README.md).
class _Vector {
  _Vector({
    required this.name,
    required this.expectValue,
    required this.payloadSha256,
    required this.identity,
    required this.passphrase,
    required this.armored,
    required this.file,
  });

  final String name;
  final String? expectValue;
  final String? payloadSha256;
  final String? identity;
  final String? passphrase;
  final bool armored;
  final Uint8List file;
}

_Vector _loadVector(File source) {
  final bytes = source.readAsBytesSync();
  var separator = -1;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0x0a && bytes[i + 1] == 0x0a) {
      separator = i;
      break;
    }
  }
  if (separator == -1) {
    throw StateError('missing header separator in ${source.path}');
  }
  final headers = <String, String>{};
  for (final line in latin1.decode(bytes.sublist(0, separator)).split('\n')) {
    final colon = line.indexOf(': ');
    headers[line.substring(0, colon)] = line.substring(colon + 2);
  }
  var file = Uint8List.sublistView(bytes, separator + 2);
  if (headers['compressed'] == 'zlib') {
    file = Uint8List.fromList(zlib.decode(file));
  } else if (headers.containsKey('compressed')) {
    throw StateError('unsupported compression in ${source.path}');
  }
  return _Vector(
    name: p.basename(source.path),
    expectValue: headers['expect'],
    payloadSha256: headers['payload'],
    identity: headers['identity'],
    passphrase: headers['passphrase'],
    armored: headers['armored'] == 'yes',
    file: file,
  );
}

void main() {
  final fixturesDir = Directory(
    p.join(Directory.current.path, 'test', 'fixtures', 'age_testkit'),
  );
  final vectors = fixturesDir
      .listSync()
      .whereType<File>()
      .where((file) => p.basename(file.path) != 'README.md')
      .map(_loadVector)
      .toList();

  test('the vendored testkit subset is present', () {
    expect(vectors.length, greaterThanOrEqualTo(20));
    expect(vectors.map((v) => v.name), contains('x25519'));
    expect(vectors.map((v) => v.name), contains('scrypt'));
  });

  for (final vector in vectors) {
    test('testkit: ${vector.name} (expect: ${vector.expectValue})', () async {
      Future<Uint8List> decode() async {
        final raw = vector.armored
            ? armorDecode(latin1.decode(vector.file))
            : vector.file;
        final decrypter = AgeDecrypter()
          // Vectors without an identity still need one added so failures come
          // from the file itself rather than the empty-decrypter guard.
          ..addIdentity(vector.identity ?? generateIdentity());
        return decrypter.decrypt(raw);
      }

      if (vector.passphrase != null) {
        // Passphrase (scrypt) files are intentionally unsupported: they must
        // fail, and files that a full implementation would decrypt (expect:
        // success) must fail with the dedicated passphrase error code.
        try {
          await decode();
          fail('expected an AgeException for scrypt vector ${vector.name}');
        } on AgeException catch (error) {
          if (vector.expectValue == 'success') {
            expect(error.code, AgeExceptionCode.passphraseUnsupported);
          }
        }
        return;
      }

      if (vector.expectValue == 'success') {
        final plaintext = await decode();
        final digest = await Sha256().hash(plaintext);
        final hex = digest.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(hex, vector.payloadSha256);
        return;
      }

      await expectLater(decode(), throwsA(isA<AgeException>()));
    });
  }
}
