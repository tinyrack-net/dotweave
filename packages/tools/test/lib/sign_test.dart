import 'dart:convert';

import 'package:dotweave_tools/src/lib/sign.dart';
import 'package:test/test.dart';

void main() {
  group('decodeBase64Secret', () {
    final payload = List<int>.generate(180, (index) => index % 251);
    final encoded = base64Encode(payload);

    test('decodes plain single-line base64', () {
      expect(decodeBase64Secret(encoded), payload);
    });

    test('decodes base64 wrapped at 64 columns like the base64 CLI', () {
      final wrapped = RegExp(
        '.{1,64}',
      ).allMatches(encoded).map((match) => match.group(0)).join('\n');

      // Dart's strict decoder rejects this shape outright — the lenient
      // helper must accept it (Node Buffer.from(s, 'base64') semantics the
      // CI secrets were created for).
      expect(() => base64Decode(wrapped), throwsFormatException);
      expect(decodeBase64Secret(wrapped), payload);
    });

    test('decodes base64 with surrounding whitespace and CRLF wrapping', () {
      final wrapped = RegExp(
        '.{1,76}',
      ).allMatches(encoded).map((match) => match.group(0)).join('\r\n');

      expect(decodeBase64Secret(' $wrapped\r\n'), payload);
    });
  });
}
