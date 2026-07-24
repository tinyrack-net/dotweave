import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/global_config.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('global config', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('global-config-test-');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('normalizes the active profile name', () {
      final config = parseGlobalDotweaveConfig(<String, Object?>{
        'activeProfile': ' work ',
        'version': 3,
      });

      expect(config.toJson(), equals({'activeProfile': 'work', 'version': 3}));
    });

    test('rejects v2 config (migration happens before parsing)', () {
      expect(
        () => parseGlobalDotweaveConfig(<String, Object?>{
          'age': {
            'identityFile': r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            'recipients': ['age1example'],
          },
          'version': 2,
        }),
        throwsA(isA<DotweaveError>()),
      );
    });

    test('parses v3 config without age', () {
      final config = parseGlobalDotweaveConfig(<String, Object?>{
        'activeProfile': 'work',
        'version': 3,
      });

      expect(config.toJson(), equals({'activeProfile': 'work', 'version': 3}));
    });

    test('treats missing config as base-only', () {
      final selection = resolveActiveProfileSelection(null);

      expect(selection.mode, 'none');
      expect(selection.profile, isNull);
      expect(isProfileActive(selection, null), isTrue);
      expect(isProfileActive(selection, 'work'), isFalse);
    });

    test('uses the configured active profile', () {
      final selection = resolveActiveProfileSelection(
        const GlobalDotweaveConfig(activeProfile: 'work', version: 3),
      );

      expect(selection.mode, 'single');
      expect(selection.profile, 'work');
      expect(isProfileActive(selection, null), isTrue);
      expect(isProfileActive(selection, 'work'), isTrue);
      expect(isProfileActive(selection, 'personal'), isFalse);
    });

    test('rejects settings.json files', () async {
      final filePath = p.join(dir.path, 'settings.jsonc');

      await File(
        p.join(dir.path, 'settings.json'),
      ).writeAsString(jsonEncode({'activeProfile': 'work', 'version': 3}));

      await expectLater(
        readGlobalDotweaveConfig(filePath),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            matches(RegExp('Unsupported dotweave config file')),
          ),
        ),
      );
    });
  });
}
