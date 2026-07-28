import 'package:dotweave/src/config/xdg.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Mirrors node:path `resolve` (see the TS test's `resolve` import).
String resolvePath(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

String? Function(String name) readEnv(Map<String, String?> environment) {
  return (name) => environment[name];
}

void main() {
  group('resolveHomeDirectory', () {
    test('uses HOME environment variable when set', () {
      expect(resolveHomeDirectory('/tmp/home'), resolvePath(['/tmp/home']));
    });

    test('ignores blank HOME', () {
      final result = resolveHomeDirectory('  ');
      expect(result, isNotEmpty);
    });
  });

  group('resolveXdgConfigHome', () {
    test('uses XDG_CONFIG_HOME when set', () {
      expect(
        resolveXdgConfigHome(null, '/custom/config'),
        resolvePath(['/custom/config']),
      );
    });

    test('falls back to ~/.config on all platforms', () {
      expect(
        resolveXdgConfigHome('/tmp/home', null),
        resolvePath(['/tmp/home', '.config']),
      );
    });
  });

  group('resolveDotweaveConfigDirectory', () {
    test('appends dotweave to config home', () {
      expect(
        resolveDotweaveConfigDirectory('/custom/config'),
        resolvePath(['/custom/config', 'dotweave']),
      );
    });
  });

  group('resolveDotweaveHomeDirectory', () {
    test('uses DOTWEAVE_HOME when set', () {
      expect(
        resolveDotweaveHomeDirectory(
          dotweaveHome: '/custom/dotweave',
          home: '/tmp/home',
          platform: 'linux',
        ),
        resolvePath(['/custom/dotweave']),
      );
    });

    test('trims DOTWEAVE_HOME before resolving', () {
      expect(
        resolveDotweaveHomeDirectory(
          dotweaveHome: '  /custom/dotweave  ',
          home: '/tmp/home',
          platform: 'linux',
        ),
        resolvePath(['/custom/dotweave']),
      );
    });

    test('uses APPDATA/dotweave by default on Windows', () {
      expect(
        resolveDotweaveHomeDirectory(
          appData: r'C:\Users\test\AppData\Roaming',
          home: r'C:\Users\test',
          platform: 'win32',
        ),
        resolvePath([r'C:\Users\test\AppData\Roaming', 'dotweave']),
      );
    });

    test(
      'falls back to LOCALAPPDATA/dotweave on Windows when APPDATA is unset',
      () {
        expect(
          resolveDotweaveHomeDirectory(
            localAppData: r'C:\Users\test\AppData\Local',
            home: r'C:\Users\test',
            platform: 'win32',
          ),
          resolvePath([r'C:\Users\test\AppData\Local', 'dotweave']),
        );
      },
    );

    test('falls back to USERPROFILE/AppData/Roaming/dotweave on Windows', () {
      expect(
        resolveDotweaveHomeDirectory(
          home: null,
          platform: 'win32',
          userProfile: r'C:\Users\test',
        ),
        resolvePath([r'C:\Users\test', 'AppData', 'Roaming', 'dotweave']),
      );
    });

    test('falls back to os homedir on Windows instead of HOME when app-data '
        'variables are unset', () {
      expect(
        resolveDotweaveHomeDirectory(
          home: r'C:\msys64\home\test',
          osHomeDirectory: r'C:\Users\test',
          platform: 'win32',
        ),
        resolvePath([r'C:\Users\test', 'AppData', 'Roaming', 'dotweave']),
      );
    });

    test('keeps XDG_CONFIG_HOME/dotweave on non-Windows', () {
      expect(
        resolveDotweaveHomeDirectory(
          home: '/home/test',
          platform: 'linux',
          xdgConfigHome: '/custom/config',
        ),
        resolvePath(['/custom/config', 'dotweave']),
      );
    });

    test('keeps ~/.config/dotweave fallback on non-Windows', () {
      expect(
        resolveDotweaveHomeDirectory(home: '/home/test', platform: 'linux'),
        resolvePath(['/home/test', '.config', 'dotweave']),
      );
    });
  });

  group('expandHomePath', () {
    test('expands ~ to home directory', () {
      expect(expandHomePath('~', '/tmp/home'), resolvePath(['/tmp/home']));
    });

    test('expands ~/ prefix', () {
      expect(
        expandHomePath('~/.gitconfig', '/tmp/home'),
        resolvePath(['/tmp/home', '.gitconfig']),
      );
    });

    test('leaves absolute paths unchanged', () {
      expect(expandHomePath('/absolute/path', '/tmp/home'), '/absolute/path');
    });
  });

  group('expandConfiguredPath', () {
    test(r'expands $XDG_CONFIG_HOME', () {
      expect(
        expandConfiguredPath(r'$XDG_CONFIG_HOME', null, '/custom/config'),
        resolvePath(['/custom/config']),
      );
    });

    test(r'expands $XDG_CONFIG_HOME/ prefix', () {
      expect(
        expandConfiguredPath(
          r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          null,
          '/custom/config',
        ),
        resolvePath(['/custom/config', 'dotweave', 'keys.txt']),
      );
    });

    test(r'expands ${XDG_CONFIG_HOME} braced syntax', () {
      expect(
        expandConfiguredPath(
          r'${XDG_CONFIG_HOME}/dotweave',
          null,
          '/custom/config',
        ),
        resolvePath(['/custom/config', 'dotweave']),
      );
    });
  });

  group('resolveConfiguredAbsolutePath', () {
    test('resolves absolute paths', () {
      expect(
        resolveConfiguredAbsolutePath('/absolute/path', null, null),
        resolvePath(['/absolute/path']),
      );
    });

    test('throws for relative paths', () {
      expect(
        () => resolveConfiguredAbsolutePath('relative/path', null, null),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('must be absolute'),
          ),
        ),
      );
    });

    test('resolves ~ prefixed paths', () {
      expect(
        resolveConfiguredAbsolutePath('~/.gitconfig', '/tmp/home', null),
        resolvePath(['/tmp/home', '.gitconfig']),
      );
    });

    test('resolves %LOCALAPPDATA% paths when readEnv is provided', () {
      expect(
        resolveConfiguredAbsolutePath(
          '%LOCALAPPDATA%/app',
          null,
          null,
          readEnv({'LOCALAPPDATA': '/tmp/appdata'}),
        ),
        resolvePath(['/tmp/appdata', 'app']),
      );
    });

    test('resolves ~ paths with readEnv', () {
      expect(
        resolveConfiguredAbsolutePath(
          '~/.config/app',
          '/tmp/home',
          null,
          readEnv({}),
        ),
        resolvePath(['/tmp/home', '.config', 'app']),
      );
    });

    test('throws for relative paths with readEnv', () {
      expect(
        () => resolveConfiguredAbsolutePath(
          'relative/path',
          null,
          null,
          readEnv({}),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('must be absolute'),
          ),
        ),
      );
    });
  });

  group('expandWindowsEnvVars', () {
    test('expands %LOCALAPPDATA% variable', () {
      expect(
        expandWindowsEnvVars(
          '%LOCALAPPDATA%/app/config',
          readEnv({'LOCALAPPDATA': r'C:\Users\test\AppData\Local'}),
        ),
        r'C:\Users\test\AppData\Local/app/config',
      );
    });

    test('expands multiple variables', () {
      expect(
        expandWindowsEnvVars(
          '%DRIVE%/%FOLDER%',
          readEnv({'DRIVE': 'C:', 'FOLDER': 'Users'}),
        ),
        'C:/Users',
      );
    });

    test('throws when variable is not defined', () {
      expect(
        () => expandWindowsEnvVars('%MISSING_VAR%/path', readEnv({})),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('%MISSING_VAR%'),
          ),
        ),
      );
    });

    test('returns string unchanged when no % tokens present', () {
      expect(
        expandWindowsEnvVars('~/.config/app', readEnv({})),
        '~/.config/app',
      );
    });

    test('handles empty %% token without matching', () {
      expect(expandWindowsEnvVars('%%', readEnv({})), '%%');
    });

    test('throws for variable with whitespace-only value', () {
      expect(
        () => expandWindowsEnvVars('%VAR%/path', readEnv({'VAR': '  '})),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('%VAR%'),
          ),
        ),
      );
    });
  });

  group('expandConfiguredPath with readEnv', () {
    test('expands %LOCALAPPDATA% then resolves', () {
      expect(
        expandConfiguredPath(
          '%LOCALAPPDATA%/app',
          null,
          null,
          readEnv({'LOCALAPPDATA': '/tmp/appdata'}),
        ),
        '/tmp/appdata/app',
      );
    });

    test('expands ~ paths with readEnv', () {
      expect(
        expandConfiguredPath('~/.config/app', '/tmp/home', null, readEnv({})),
        resolvePath(['/tmp/home', '.config', 'app']),
      );
    });

    test(r'expands $XDG_CONFIG_HOME paths with readEnv', () {
      expect(
        expandConfiguredPath(
          r'$XDG_CONFIG_HOME/app',
          null,
          '/custom/config',
          readEnv({}),
        ),
        resolvePath(['/custom/config', 'app']),
      );
    });
  });
}
