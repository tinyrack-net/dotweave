import 'dart:typed_data';

import 'package:dotweave_age/src/exception.dart';
import 'package:dotweave_age/src/stanza.dart';
import 'package:test/test.dart';

Stanza parseSerialized(String serialized) {
  final lines = serialized.split('\n');
  var index = 0;
  return parseStanza(lines[index++], () {
    if (index >= lines.length) {
      throw const AgeException('unexpected end of stanza');
    }
    return lines[index++];
  });
}

void main() {
  group('base64 helpers', () {
    test('encodes without padding', () {
      expect(encodeBase64NoPad([]), '');
      expect(encodeBase64NoPad([0]), 'AA');
      expect(encodeBase64NoPad([0, 0]), 'AAA');
      expect(encodeBase64NoPad([0, 0, 0]), 'AAAA');
    });

    test('decodes canonical unpadded base64', () {
      expect(decodeBase64NoPad(''), isEmpty);
      expect(decodeBase64NoPad('AA'), [0]);
      expect(decodeBase64NoPad('/w'), [255]);
    });

    test('rejects padding characters', () {
      expect(() => decodeBase64NoPad('AA=='), throwsA(isA<AgeException>()));
    });

    test('rejects invalid lengths', () {
      expect(() => decodeBase64NoPad('A'), throwsA(isA<AgeException>()));
      expect(() => decodeBase64NoPad('AAAAA'), throwsA(isA<AgeException>()));
    });

    test('rejects non-canonical trailing bits', () {
      // 'AB' decodes to one byte; the low 4 bits of 'B' (value 1) are not zero.
      expect(() => decodeBase64NoPad('AB'), throwsA(isA<AgeException>()));
      expect(() => decodeBase64NoPad('AAB'), throwsA(isA<AgeException>()));
    });

    test('rejects url-safe alphabet characters', () {
      expect(() => decodeBase64NoPad('-w'), throwsA(isA<AgeException>()));
      expect(() => decodeBase64NoPad('_w'), throwsA(isA<AgeException>()));
    });
  });

  group('Stanza', () {
    test('validates type and args', () {
      expect(() => Stanza('', [], Uint8List(0)), throwsA(isA<AgeException>()));
      expect(
        () => Stanza('X25519', ['a b'], Uint8List(0)),
        throwsA(isA<AgeException>()),
      );
      expect(
        () => Stanza('X25519', [''], Uint8List(0)),
        throwsA(isA<AgeException>()),
      );
    });

    for (final size in [0, 47, 48, 49, 96]) {
      test('round-trips a $size-byte body with final line < 64 chars', () {
        final body = Uint8List.fromList(
          List<int>.generate(size, (i) => (i * 31) & 0xff),
        );
        final stanza = Stanza('test', ['arg1', 'arg2'], body);
        final serialized = stanza.serialize();

        final lines = serialized.split('\n');
        expect(lines.first, '-> test arg1 arg2');
        expect(lines.last, '', reason: 'serialization ends with a newline');
        final bodyLines = lines.sublist(1, lines.length - 1);
        expect(bodyLines, isNotEmpty);
        for (final line in bodyLines.sublist(0, bodyLines.length - 1)) {
          expect(line.length, 64);
        }
        expect(bodyLines.last.length, lessThan(64));
        if (size % 48 == 0) {
          expect(
            bodyLines.last,
            isEmpty,
            reason:
                'bodies that are a multiple of 48 bytes need an empty final line',
          );
        }

        final parsed = parseSerialized(serialized);
        expect(parsed.type, 'test');
        expect(parsed.args, ['arg1', 'arg2']);
        expect(parsed.body, body);
      });
    }

    test('parses a stanza with no args', () {
      final parsed = parseSerialized(
        Stanza('grease', [], Uint8List(3)).serialize(),
      );
      expect(parsed.type, 'grease');
      expect(parsed.args, isEmpty);
      expect(parsed.body, Uint8List(3));
    });

    test('rejects a missing empty final line for 48-byte bodies', () {
      // 48 bytes -> exactly one full 64-char line; the empty final line is
      // required, so a stanza whose body ends at the full line keeps reading
      // and consumes the next header line (`--- ...`), which is not valid
      // base64.
      final lines = ['-> test', 'A' * 64, '--- hmac'];
      var index = 0;
      expect(
        () => parseStanza(lines[index++], () {
          if (index >= lines.length) {
            throw const AgeException('unexpected end of header');
          }
          return lines[index++];
        }),
        throwsA(isA<AgeException>()),
      );
    });

    test('rejects body lines longer than 64 characters', () {
      final serialized = '-> test\n${'A' * 68}\n';
      expect(() => parseSerialized(serialized), throwsA(isA<AgeException>()));
    });

    test('rejects malformed first lines', () {
      expect(() => parseSerialized('->test\n\n'), throwsA(isA<AgeException>()));
      expect(() => parseSerialized('-> \n\n'), throwsA(isA<AgeException>()));
      expect(
        () => parseSerialized('-> type  doublespace\n\n'),
        throwsA(isA<AgeException>()),
      );
    });
  });
}
