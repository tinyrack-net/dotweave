import 'dart:typed_data';

import 'package:dotweave/src/crypto/age/armor.dart';
import 'package:dotweave/src/crypto/age/exception.dart';
import 'package:test/test.dart';

void main() {
  group('armorEncode / armorDecode', () {
    for (final size in [1, 47, 48, 49, 100, 200]) {
      test('round-trips $size bytes', () {
        final data = Uint8List.fromList(
          List<int>.generate(size, (i) => (i * 13) & 0xff),
        );
        final armored = armorEncode(data);
        expect(armored, startsWith('-----BEGIN AGE ENCRYPTED FILE-----\n'));
        expect(armored, endsWith('-----END AGE ENCRYPTED FILE-----\n'));
        for (final line in armored.trim().split('\n')) {
          expect(line.length, lessThanOrEqualTo(64));
        }
        expect(armorDecode(armored), data);
      });
    }

    test('wraps base64 at 64 characters (48 input bytes per line)', () {
      final armored = armorEncode(Uint8List(96));
      final lines = armored.trim().split('\n');
      expect(lines.length, 4);
      expect(lines[1].length, 64);
      expect(lines[2].length, 64);
    });

    test('tolerates CRLF newlines', () {
      final data = Uint8List.fromList(List<int>.generate(60, (i) => i));
      final crlf = armorEncode(data).replaceAll('\n', '\r\n');
      expect(armorDecode(crlf), data);
    });

    test('tolerates surrounding whitespace', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final armored = '\n  \t${armorEncode(data)}\n\n  ';
      expect(armorDecode(armored), data);
    });

    test('rejects a wrong begin label', () {
      final armored = armorEncode(
        Uint8List(4),
      ).replaceFirst('BEGIN AGE', 'BEGIN PGP');
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });

    test('rejects a wrong end label', () {
      final armored = armorEncode(
        Uint8List(4),
      ).replaceFirst('END AGE', 'END PGP');
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });

    test('rejects non-whitespace garbage after the end line', () {
      final armored = '${armorEncode(Uint8List(4))}garbage';
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });

    test('rejects non-whitespace garbage before the begin line', () {
      final armored = 'garbage\n${armorEncode(Uint8List(4))}';
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });

    test('rejects an empty final data line', () {
      final armored = armorEncode(
        Uint8List(4),
      ).replaceFirst('-----END', '\n-----END');
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });

    test('rejects over-long data lines', () {
      final data = Uint8List(90);
      final armored = armorEncode(data);
      // Join the two data lines into one 120+ character line.
      final lines = armored.trim().split('\n');
      final merged = [
        lines.first,
        lines.sublist(1, lines.length - 1).join(),
        lines.last,
      ].join('\n');
      expect(() => armorDecode(merged), throwsA(isA<AgeException>()));
    });

    test('rejects missing base64 padding', () {
      final data = Uint8List(4); // encodes to 'AAAAAA==' with padding
      final armored = armorEncode(data).replaceFirst('==', '');
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });

    test('rejects invalid base64 characters', () {
      final armored = armorEncode(Uint8List(4)).replaceFirst('AA', '!!');
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });

    test('rejects non-canonical padding bits', () {
      // 'AB==' has non-zero bits in the discarded low nibble of 'B'.
      const armored =
          '-----BEGIN AGE ENCRYPTED FILE-----\n'
          'AB==\n'
          '-----END AGE ENCRYPTED FILE-----\n';
      expect(() => armorDecode(armored), throwsA(isA<AgeException>()));
    });
  });
}
