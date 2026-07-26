import 'package:dotweave/src/cli/platform_flags.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/track.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:test/test.dart';

void expectDotweaveErrorCode(Object? Function() callback, String code) {
  try {
    callback();
  } catch (error) {
    expect(error, isA<DotweaveError>());
    expect((error as DotweaveError).code, code);
    return;
  }

  throw Exception('Expected DotweaveError with code $code');
}

/// Stand-in for the TS `toEqual` object assertions: [PartialPlatformStringValue]
/// has no value equality, so every field is asserted (absent keys are `null`).
void expectPartialStringValue(
  PartialPlatformStringValue? actual, {
  String? defaultValue,
  String? win,
  String? mac,
  String? linux,
  String? wsl,
}) {
  expect(actual, isNotNull);
  expect(actual!.defaultValue, defaultValue);
  expect(actual.win, win);
  expect(actual.mac, mac);
  expect(actual.linux, linux);
  expect(actual.wsl, wsl);
}

/// Stand-in for the TS `toEqual` object assertions on the parsed mode shape.
void expectPartialSyncMode(
  PartialPlatformSyncMode? actual, {
  String? defaultValue,
  String? win,
  String? mac,
  String? linux,
  String? wsl,
}) {
  expect(actual, isNotNull);
  expect(actual!.defaultValue, defaultValue);
  expect(actual.win, win);
  expect(actual.mac, mac);
  expect(actual.linux, linux);
  expect(actual.wsl, wsl);
}

void main() {
  group('platform flag parsing', () {
    group('parsePlatformStringFlags', () {
      test('returns undefined when no values are supplied', () {
        expect(parsePlatformStringFlags('repo', null), isNull);
      });

      test('parses a bare value as the default platform value', () {
        expectPartialStringValue(
          parsePlatformStringFlags('repo', ['dotfiles/bashrc']),
          defaultValue: 'dotfiles/bashrc',
        );
      });

      test('parses default=value as the default platform value', () {
        expectPartialStringValue(
          parsePlatformStringFlags('repo', ['default=dotfiles/bashrc']),
          defaultValue: 'dotfiles/bashrc',
        );
      });

      test('parses supported platform overrides with a default', () {
        expectPartialStringValue(
          parsePlatformStringFlags('repo', [
            '.config/app',
            'win=AppData/Roaming/App',
            'mac=Library/Application Support/App',
            'linux=.config/app-linux',
            'wsl=.config/app-wsl',
          ]),
          defaultValue: '.config/app',
          linux: '.config/app-linux',
          mac: 'Library/Application Support/App',
          win: 'AppData/Roaming/App',
          wsl: '.config/app-wsl',
        );
      });

      test('rejects duplicate default values', () {
        expectDotweaveErrorCode(
          () => parsePlatformStringFlags('repo', ['one', 'default=two']),
          'DUPLICATE_PLATFORM_FLAG',
        );
      });

      test('rejects duplicate platform keys', () {
        expectDotweaveErrorCode(
          () => parsePlatformStringFlags('repo', ['win=one', 'win=two']),
          'DUPLICATE_PLATFORM_FLAG',
        );
      });

      test('rejects unknown platform keys', () {
        expectDotweaveErrorCode(
          () => parsePlatformStringFlags('repo', ['freebsd=value']),
          'INVALID_PLATFORM_FLAG',
        );
      });

      test('rejects empty keys and empty values', () {
        expectDotweaveErrorCode(
          () => parsePlatformStringFlags('repo', ['=value']),
          'INVALID_PLATFORM_FLAG',
        );
        expectDotweaveErrorCode(
          () => parsePlatformStringFlags('repo', ['win=']),
          'INVALID_PLATFORM_FLAG',
        );
      });
    });

    group('parsePlatformStringOverrideFlags', () {
      test('parses only non-default platform overrides', () {
        expectPartialStringValue(
          parsePlatformStringOverrideFlags('local', [
            'win=%APPDATA%/App',
            'mac=Library/Application Support/App',
          ]),
          mac: 'Library/Application Support/App',
          win: '%APPDATA%/App',
        );
      });

      test('rejects bare and default values', () {
        expectDotweaveErrorCode(
          () => parsePlatformStringOverrideFlags('local', ['~/App']),
          'INVALID_PLATFORM_FLAG',
        );
        expectDotweaveErrorCode(
          () => parsePlatformStringOverrideFlags('local', ['default=~/App']),
          'INVALID_PLATFORM_FLAG',
        );
      });
    });

    group('parsePlatformModeFlags', () {
      test('parses mode values per platform', () {
        expectPartialSyncMode(
          parsePlatformModeFlags('mode', ['normal', 'win=ignore']),
          defaultValue: 'normal',
          win: 'ignore',
        );
      });

      test('rejects unsupported sync modes', () {
        expectDotweaveErrorCode(
          () => parsePlatformModeFlags('mode', ['normal', 'win=archive']),
          'INVALID_SYNC_MODE',
        );
      });
    });

    group('parsePlatformPermissionFlags', () {
      test('parses octal permissions per platform', () {
        expect(
          parsePlatformPermissionFlags('permission', ['0600', 'mac=0400']),
          const PlatformPermission(defaultValue: '0600', mac: '0400'),
        );
      });

      test('rejects non-octal permission strings', () {
        expectDotweaveErrorCode(
          () => parsePlatformPermissionFlags('permission', ['600']),
          'INVALID_PERMISSION',
        );
        expectDotweaveErrorCode(
          () => parsePlatformPermissionFlags('permission', ['win=08ff']),
          'INVALID_PERMISSION',
        );
      });
    });
  });
}
