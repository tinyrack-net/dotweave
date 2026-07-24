import 'dart:convert';
import 'dart:typed_data';

import 'package:dotweave/src/lib/content.dart';
import 'package:test/test.dart';

Uint8List bytes(Object value) {
  if (value is! String) {
    return Uint8List.fromList(value as List<int>);
  }

  return Uint8List.fromList(utf8.encode(value));
}

const utf8Bom = [0xef, 0xbb, 0xbf];

void main() {
  group('content helpers', () {
    test('matches exact bytes', () {
      expect(fileContentsEqual(bytes('value\n'), bytes('value\n')), true);
    });

    test('does not normalize text line endings by default', () {
      expect(fileContentsEqual(bytes('value\r\n'), bytes('value\n')), false);
    });

    test('can treat CRLF and LF as equivalent for UTF-8 text', () {
      expect(
        fileContentsEqual(
          bytes('a\r\nb\r\n'),
          bytes('a\nb\n'),
          normalizeTextLineEndings: true,
        ),
        true,
      );
    });

    test('normalizes UTF-8 text line endings symmetrically', () {
      expect(
        fileContentsEqual(
          bytes('a\nb\n'),
          bytes('a\r\nb\r\n'),
          normalizeTextLineEndings: true,
        ),
        true,
      );
    });

    test('treats matching mixed CRLF and LF text as unchanged', () {
      expect(
        fileContentsEqual(
          bytes('a\r\nb\nc\r\n'),
          bytes('a\nb\nc\n'),
          normalizeTextLineEndings: true,
        ),
        true,
      );
    });

    test('does not normalize lone carriage returns', () {
      expect(
        fileContentsEqual(
          bytes('a\rb\n'),
          bytes('a\nb\n'),
          normalizeTextLineEndings: true,
        ),
        false,
      );
    });

    test('preserves UTF-8 BOM differences while normalizing line endings', () {
      expect(
        fileContentsEqual(
          bytes([...utf8Bom, 0x61, 0x0d, 0x0a]),
          bytes('a\n'),
          normalizeTextLineEndings: true,
        ),
        false,
      );
    });

    test('normalizes line endings when both UTF-8 texts have the same BOM', () {
      expect(
        fileContentsEqual(
          bytes([...utf8Bom, 0x61, 0x0d, 0x0a]),
          bytes([...utf8Bom, 0x61, 0x0a]),
          normalizeTextLineEndings: true,
        ),
        true,
      );
    });

    test('keeps binary-like invalid UTF-8 content byte-strict', () {
      expect(
        fileContentsEqual(
          bytes([0xff, 0x0d, 0x0a]),
          bytes([0xff, 0x0a]),
          normalizeTextLineEndings: true,
        ),
        false,
      );
    });
  });
}
