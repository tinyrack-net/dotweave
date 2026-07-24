import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/jsonc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('stripJsoncComments', () {
    test('passes plain JSON through unchanged', () {
      const input = '{"key": "value"}';
      expect(stripJsoncComments(input), input);
    });

    test('strips single-line comments', () {
      const input = '{\n  // a comment\n  "key": "value"\n}';
      final result = stripJsoncComments(input);
      expect(result, isNot(contains('// a comment')));
      expect(jsonDecode(result), {'key': 'value'});
    });

    test('strips block comments', () {
      const input = '{ /* block */ "key": "value" }';
      final result = stripJsoncComments(input);
      expect(result, isNot(contains('block')));
      expect(jsonDecode(result), {'key': 'value'});
    });

    test('preserves comment-like text inside string literals', () {
      const input = '{"url": "https://example.com"}';
      expect(jsonDecode(stripJsoncComments(input)), {
        'url': 'https://example.com',
      });
    });

    test('preserves escape sequences inside strings', () {
      const input = r'{"key": "line1\nline2"}';
      expect(jsonDecode(stripJsoncComments(input)), {'key': 'line1\nline2'});
    });

    test(
      'preserves newlines inside block comments for correct error line numbers',
      () {
        const input = '{\n/* line1\nline2 */\n"key": "value"\n}';
        final stripped = stripJsoncComments(input);
        final lines = stripped.split('\n');
        expect(lines.length, greaterThanOrEqualTo(4));
      },
    );
  });

  group('parseJsonc', () {
    test('parses plain JSON', () {
      expect(parseJsonc('{"a": 1}'), {'a': 1});
    });

    test('parses JSONC with comments', () {
      const input = '{\n  // comment\n  "a": 1 /* inline */\n}';
      expect(parseJsonc(input), {'a': 1});
    });

    test('throws SyntaxError for invalid JSON after stripping', () {
      expect(() => parseJsonc('{ bad json }'), throwsFormatException);
    });
  });

  group('validateJsoncConfigPath', () {
    late String dir;

    setUp(() async {
      dir = p.join(
        Directory.systemTemp.path,
        'jsonc-test-${DateTime.now().millisecondsSinceEpoch}',
      );
      await Directory(dir).create(recursive: true);
    });

    tearDown(() async {
      final directory = Directory(dir);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('returns the .jsonc path when only .jsonc exists', () async {
      final jsoncPath = p.join(dir, 'config.jsonc');
      await File(jsoncPath).writeAsString('{}');
      expect(await validateJsoncConfigPath(jsoncPath), jsoncPath);
    });

    test('rejects .json when only .json exists', () async {
      final jsoncPath = p.join(dir, 'config.jsonc');
      final jsonPath = p.join(dir, 'config.json');
      await File(jsonPath).writeAsString('{}');
      await expectLater(
        validateJsoncConfigPath(jsoncPath),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            contains('Unsupported dotweave config file'),
          ),
        ),
      );
    });

    test('rejects .json when both .jsonc and .json exist', () async {
      final jsoncPath = p.join(dir, 'config.jsonc');
      final jsonPath = p.join(dir, 'config.json');
      await File(jsoncPath).writeAsString('{}');
      await File(jsonPath).writeAsString('{}');
      await expectLater(
        validateJsoncConfigPath(jsoncPath),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            contains('Unsupported dotweave config file'),
          ),
        ),
      );
    });

    test('returns the preferred path when neither exists', () async {
      final jsoncPath = p.join(dir, 'config.jsonc');
      expect(await validateJsoncConfigPath(jsoncPath), jsoncPath);
    });
  });
}
