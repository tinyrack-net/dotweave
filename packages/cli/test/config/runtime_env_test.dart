import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/lib/env.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Mirrors node:path `resolve` (see the TS test's `resolve` import).
String resolvePath(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

/// Stands in for the TS test's mocked `ENV` module: a fully controlled
/// environment where every variable not listed is unset.
Env makeEnv([Map<String, String> values = const {}]) {
  return Env(values);
}

void main() {
  group('runtime-env', () {
    group('readEnvValue', () {
      test('reads and trims environment values', () {
        final env = makeEnv({'HOME': '  /home/user  '});
        expect(readEnvValue('HOME', env: env), '/home/user');
      });

      test('returns undefined for unset environment values', () {
        expect(readEnvValue('HOME', env: makeEnv()), isNull);
      });
    });

    group('resolveHomeDirectoryFromEnv', () {
      test('resolves HOME when set', () {
        final env = makeEnv({'HOME': '/home/test'});
        expect(
          resolveHomeDirectoryFromEnv(env: env),
          resolvePath(['/home/test']),
        );
      });

      test('falls back to os.homedir when HOME is not set', () {
        final result = resolveHomeDirectoryFromEnv(env: makeEnv());
        expect(result, isA<String>());
        expect(result.length, greaterThan(0));
      });
    });

    group('resolveXdgConfigHomeFromEnv', () {
      test('resolves XDG_CONFIG_HOME when set', () {
        final env = makeEnv({
          'HOME': '/home/test',
          'XDG_CONFIG_HOME': '/home/test/.config',
        });
        expect(
          resolveXdgConfigHomeFromEnv(env: env),
          resolvePath(['/home/test/.config']),
        );
      });

      test('falls back to ~/.config when XDG_CONFIG_HOME is not set', () {
        final env = makeEnv({'HOME': '/home/test'});
        expect(
          resolveXdgConfigHomeFromEnv(env: env),
          resolvePath(['/home/test/.config']),
        );
      });
    });

    group('resolveDotweaveHomeDirectoryFromEnv', () {
      test('uses DOTWEAVE_HOME when set', () {
        final env = makeEnv({
          'DOTWEAVE_HOME': '/custom/dotweave',
          'HOME': '/home/test',
        });

        expect(
          resolveDotweaveHomeDirectoryFromEnv(env: env, platform: 'linux'),
          resolvePath(['/custom/dotweave']),
        );
      });

      test('uses APPDATA/dotweave by default on Windows', () {
        final env = makeEnv({
          'APPDATA': r'C:\Users\test\AppData\Roaming',
          'HOME': r'C:\Users\test',
        });

        expect(
          resolveDotweaveHomeDirectoryFromEnv(env: env, platform: 'win32'),
          resolvePath([r'C:\Users\test\AppData\Roaming', 'dotweave']),
        );
      });

      test('falls back to LOCALAPPDATA/dotweave on Windows', () {
        final env = makeEnv({
          'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
          'HOME': r'C:\Users\test',
        });

        expect(
          resolveDotweaveHomeDirectoryFromEnv(env: env, platform: 'win32'),
          resolvePath([r'C:\Users\test\AppData\Local', 'dotweave']),
        );
      });

      test('falls back to USERPROFILE/AppData/Roaming/dotweave on Windows', () {
        final env = makeEnv({'USERPROFILE': r'C:\Users\test'});

        expect(
          resolveDotweaveHomeDirectoryFromEnv(env: env, platform: 'win32'),
          resolvePath([r'C:\Users\test', 'AppData', 'Roaming', 'dotweave']),
        );
      });

      test('falls back to os homedir on Windows instead of HOME', () {
        final env = makeEnv({'HOME': r'C:\msys64\home\test'});

        expect(
          resolveDotweaveHomeDirectoryFromEnv(
            env: env,
            osHomeDirectory: r'C:\Users\test',
            platform: 'win32',
          ),
          resolvePath([r'C:\Users\test', 'AppData', 'Roaming', 'dotweave']),
        );
      });
    });

    group('resolveDotweaveGlobalConfigFilePathFromEnv', () {
      test('composes the dotweave global config path', () {
        final env = makeEnv({
          'HOME': '/home/test',
          'XDG_CONFIG_HOME': '/home/test/.config',
        });

        expect(
          resolveDotweaveGlobalConfigFilePathFromEnv(
            env: env,
            platform: 'linux',
          ),
          resolvePath(['/home/test/.config/dotweave/settings.jsonc']),
        );
      });

      test('uses DOTWEAVE_HOME for the global config path', () {
        final env = makeEnv({'DOTWEAVE_HOME': '/custom/dotweave'});

        expect(
          resolveDotweaveGlobalConfigFilePathFromEnv(
            env: env,
            platform: 'linux',
          ),
          resolvePath(['/custom/dotweave', 'settings.jsonc']),
        );
      });
    });

    group('resolveDotweaveSyncDirectoryFromEnv', () {
      test('composes the dotweave sync directory path', () {
        final env = makeEnv({
          'HOME': '/home/test',
          'XDG_CONFIG_HOME': '/home/test/.config',
        });

        expect(
          resolveDotweaveSyncDirectoryFromEnv(env: env, platform: 'linux'),
          resolvePath(['/home/test/.config/dotweave/repository']),
        );
      });

      test('uses Windows APPDATA for the sync directory by default', () {
        final env = makeEnv({'APPDATA': r'C:\Users\test\AppData\Roaming'});

        expect(
          resolveDotweaveSyncDirectoryFromEnv(env: env, platform: 'win32'),
          resolvePath([
            r'C:\Users\test\AppData\Roaming',
            'dotweave',
            'repository',
          ]),
        );
      });
    });

    group('resolveCurrentPlatformKey', () {
      test('returns linux on a non-WSL linux environment', () {
        expect(
          resolveCurrentPlatformKey(
            env: makeEnv(),
            platform: 'linux',
            osRelease: '6.1.0-generic',
          ),
          PlatformKey.linux,
        );
      });

      test('detects WSL when WSL_DISTRO_NAME is set', () {
        expect(
          resolveCurrentPlatformKey(
            env: makeEnv({'WSL_DISTRO_NAME': 'Ubuntu'}),
            platform: 'linux',
            osRelease: '5.15.0-microsoft-standard',
          ),
          PlatformKey.wsl,
        );
      });

      test('detects WSL when WSL_INTEROP is set', () {
        expect(
          resolveCurrentPlatformKey(
            env: makeEnv({'WSL_INTEROP': '/run/WSL/1_interop'}),
            platform: 'linux',
            osRelease: '5.15.0-microsoft-standard',
          ),
          PlatformKey.wsl,
        );
      });

      test('detects mac platform', () {
        expect(
          resolveCurrentPlatformKey(
            env: makeEnv(),
            platform: 'darwin',
            osRelease: '23.0.0',
          ),
          PlatformKey.mac,
        );
      });

      test('detects win platform', () {
        expect(
          resolveCurrentPlatformKey(
            env: makeEnv(),
            platform: 'win32',
            osRelease: '10.0.19045',
          ),
          PlatformKey.win,
        );
      });
    });
  });
}
