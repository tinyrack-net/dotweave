import 'dart:typed_data';

import 'package:dotweave_age/src/bech32.dart';
import 'package:dotweave_age/src/exception.dart';
import 'package:test/test.dart';

void main() {
  group('bech32Encode / bech32Decode', () {
    test('round-trips random-looking data with lowercase hrp', () {
      final data = Uint8List.fromList(
        List<int>.generate(32, (i) => i * 7 & 0xff),
      );
      final encoded = bech32Encode('age', data);
      expect(encoded, startsWith('age1'));
      expect(encoded, equals(encoded.toLowerCase()));
      final decoded = bech32Decode(encoded);
      expect(decoded.hrp, 'age');
      expect(decoded.data, data);
    });

    test('round-trips with uppercase hrp producing uppercase string', () {
      final data = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      final encoded = bech32Encode('AGE-SECRET-KEY-', data);
      expect(encoded, startsWith('AGE-SECRET-KEY-1'));
      expect(encoded, equals(encoded.toUpperCase()));
      final decoded = bech32Decode(encoded);
      expect(decoded.hrp, 'age-secret-key-');
      expect(decoded.data, data);
    });

    test('accepts BIP-173 valid checksum strings', () {
      for (final valid in ['a12uel5l', 'A12UEL5L']) {
        final decoded = bech32Decode(valid);
        expect(decoded.hrp, 'a');
        expect(decoded.data, isEmpty);
      }
    });

    test('rejects mixed case', () {
      final encoded = bech32Encode('age', Uint8List(32));
      final mixed =
          encoded.substring(0, encoded.length - 1) +
          encoded[encoded.length - 1].toUpperCase();
      expect(() => bech32Decode(mixed), throwsA(isA<AgeException>()));
      expect(() => bech32Decode('A12uEL5L'), throwsA(isA<AgeException>()));
    });

    test('rejects an invalid checksum (single character change)', () {
      final encoded = bech32Encode(
        'age',
        Uint8List.fromList(List<int>.filled(32, 0x42)),
      );
      final last = encoded[encoded.length - 1];
      final replacement = last == 'q' ? 'p' : 'q';
      final corrupted = encoded.substring(0, encoded.length - 1) + replacement;
      expect(() => bech32Decode(corrupted), throwsA(isA<AgeException>()));
    });

    test('rejects BIP-173 invalid strings', () {
      const invalid = [
        'pzry9x0s0muk', // no separator
        '1pzry9x0s0muk', // empty hrp
        'x1b4n0q5v', // invalid data character
        'li1dgmt3', // checksum too short
        'A1G7SGD8', // checksum error
        '\x201nwldj5', // hrp character out of range
      ];
      for (final value in invalid) {
        expect(
          () => bech32Decode(value),
          throwsA(isA<AgeException>()),
          reason: value,
        );
      }
    });

    test('round-trips non-32-byte payloads with zero padding bits', () {
      final encoded = bech32Encode('age', Uint8List.fromList([0xff]));
      final decoded = bech32Decode(encoded);
      expect(decoded.data, [0xff]);
    });

    test('rejects an empty data section shorter than the checksum', () {
      expect(() => bech32Decode('age1qqq'), throwsA(isA<AgeException>()));
    });
  });
}
