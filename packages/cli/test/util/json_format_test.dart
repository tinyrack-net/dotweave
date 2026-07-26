import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/util/json_format.dart';
import 'package:test/test.dart';

void main() {
  group('formatJsonPretty', () {
    test('matches Node JSON.stringify(value, null, 2) byte-for-byte', () {
      final value = <String, Object?>{
        'version': 8,
        'repositoryFormat': 1,
        'age': {
          'recipients': [
            'age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq',
          ],
        },
        'profiles': ['default', 'work'],
        'entries': [
          {
            'kind': 'file',
            'localPath': {
              'default': '~/.zshrc',
              'win': r'%USERPROFILE%\.zshrc',
            },
            'repoPath': 'zshrc',
            'mode': 'normal',
            'permission': '0600',
            'profiles': <Object?>[],
          },
          {
            'kind': 'directory',
            'localPath': {'default': '~/테스트/config dir'},
            'empty': <String, Object?>{},
            'floaty': 0.5,
            'negative': -3,
            'escaped': 'line1\nline2\ttab "quoted" back\\slash / emoji 🎉',
          },
        ],
      };

      final golden = File(
        'test/fixtures/golden/pretty-json.json',
      ).readAsBytesSync();

      expect(utf8.encode(formatJsonPretty(value)), golden);
    });

    test('keeps integers free of decimal points', () {
      expect(formatJsonPretty({'version': 8}), '{\n  "version": 8\n}\n');
    });

    test('appends exactly one trailing newline', () {
      final output = formatJsonPretty(const <String, Object?>{});
      expect(output, '{}\n');
    });
  });
}
