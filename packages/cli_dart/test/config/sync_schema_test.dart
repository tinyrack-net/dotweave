import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart' hide parseSyncConfig;
import 'package:dotweave/src/config/sync_schema.dart'
    as sync_schema
    show parseSyncConfig;
import 'package:dotweave/src/lib/error.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

PlatformKey forcedPlatformKey = 'linux';

void forcePlatform(PlatformKey platformKey) {
  forcedPlatformKey = platformKey;
}

ResolvedSyncConfig parseSyncConfig(
  Object? input,
  Map<String, String?> environment,
) {
  final homeDirectory = environment['HOME'] ?? '/tmp/home';
  return sync_schema.parseSyncConfig(
    input,
    SyncConfigResolutionContext(
      homeDirectory: homeDirectory,
      platformKey: forcedPlatformKey,
      readEnv: (name) => environment[name],
      xdgConfigHome:
          environment['XDG_CONFIG_HOME'] ?? p.join(homeDirectory, '.config'),
    ),
  );
}

Future<String> createTemporaryDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
  });
  return directory.path;
}

Matcher throwsDotweaveErrorMatching(String messagePart) {
  return throwsA(
    isA<DotweaveError>().having(
      (error) => error.message,
      'message',
      contains(messagePart),
    ),
  );
}

ResolvedSyncConfigEntry? findEntry(
  ResolvedSyncConfig config,
  bool Function(ResolvedSyncConfigEntry entry) predicate,
) {
  for (final entry in config.entries) {
    if (predicate(entry)) {
      return entry;
    }
  }
  return null;
}

void main() {
  tearDown(() {
    forcedPlatformKey = 'linux';
  });

  group('sync config', () {
    test('does not write migrated v8 config when migrated v7 config fails '
        'semantic validation', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final syncDirectory = p.join(workspace, 'sync');
      final manifestPath = p.join(syncDirectory, 'manifest.jsonc');

      final manifest = {
        'version': 7,
        'entries': [
          {
            'kind': 'file',
            'localPath': {'default': '~/.gitconfig'},
          },
          {
            'kind': 'file',
            'localPath': {'default': '~/.gitconfig'},
          },
        ],
      };

      await Directory(syncDirectory).create();
      await File(
        manifestPath,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

      await expectLater(
        readSyncConfig(
          syncDirectory,
          SyncConfigResolutionContext(
            homeDirectory: p.join(workspace, 'home'),
            platformKey: 'linux',
            readEnv: (_) => null,
            xdgConfigHome: p.join(workspace, 'home', '.config'),
          ),
        ),
        throwsDotweaveErrorMatching('same repository path'),
      );

      final saved = await File(manifestPath).readAsString();
      expect(saved, contains('"version": 7'));
      expect(saved, isNot(contains('"profiles"')));
    });

    test('allows all alphanumeric profile names', () {
      expect(normalizeSyncProfileName('work'), 'work');
      expect(normalizeSyncProfileName('default'), 'default');
      expect(normalizeSyncProfileName('personal'), 'personal');
    });

    test('rejects the reserved physical profiles root as a profile name', () {
      expect(
        () => normalizeSyncProfileName('profiles'),
        throwsDotweaveErrorMatching('reserved profile artifact directory'),
      );
    });

    test('parses v7 entries with flat profiles', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
              'profiles': ['default', 'work'],
              'mode': {'default': 'secret'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.version, 7);
      expect(config.entries, hasLength(2));
      expect(resolveSyncRule(config, '.config/zsh/secrets.zsh'), (
        profile: 'default',
        mode: 'secret',
      ));
      expect(resolveSyncRule(config, '.config/zsh/secrets.zsh', 'work'), (
        profile: 'work',
        mode: 'secret',
      ));
      expect(resolveSyncRule(config, '.config/zsh/other.zsh', 'work'), (
        profile: 'default',
        mode: 'normal',
      ));

      expect(
        resolveSyncRule(config, '.config/zsh/secrets.zsh', 'personal'),
        isNull,
      );
    });

    test('parses v7 file entries with mode and profiles', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'profiles': ['default', 'work'],
              'mode': {'default': 'secret'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries, hasLength(1));
      expect(config.entries[0].profiles, ['default', 'work']);
      expect(resolveSyncRule(config, '.gitconfig', 'work'), (
        profile: 'work',
        mode: 'secret',
      ));
      expect(resolveSyncRule(config, '.gitconfig'), (
        profile: 'default',
        mode: 'secret',
      ));
    });

    test('finds the most specific entry for nested paths', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
              'mode': {'default': 'secret'},
            },
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh/cache'},
              'mode': {'default': 'ignore'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(
        resolveSyncRule(config, '.config/zsh/secrets.zsh')?.mode,
        'secret',
      );
      expect(
        resolveSyncRule(config, '.config/zsh/cache/state.txt')?.mode,
        'ignore',
      );
      expect(resolveSyncRule(config, '.config/zsh/other.zsh')?.mode, 'normal');
    });

    test('rejects v6 config format', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {'entries': <Object?>[], 'version': 6},
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('Sync configuration is invalid.'),
      );
    });

    test('ignores age.identityFile in the config (unknown field)', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'age': {
              'identityFile': r'$XDG_CONFIG_HOME/dotweave/keys.txt',
              'recipients': ['age1example'],
            },
            'entries': <Object?>[],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        returnsNormally,
      );
    });

    test('rejects string repoPath in the config', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'repoPath': '.gitconfig',
              },
            ],
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('Sync configuration is invalid.'),
      );
    });

    test('rejects duplicate repo paths', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
              },
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('same repository path'),
      );
    });

    test('uses explicit repoPath when configured', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/tool/settings.json'},
              'repoPath': {'default': 'profiles/shared/tool/settings.json'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].repoPath, 'profiles/shared/tool/settings.json');
      expect(
        config.entries[0].configuredRepoPath,
        const PlatformStringValue(
          defaultValue: 'profiles/shared/tool/settings.json',
        ),
      );
    });

    test('uses explicit platform-aware repoPath when configured', () async {
      forcePlatform('linux');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gnupg/gpg-agent.conf'},
              'repoPath': {
                'default': '.gnupg/gpg-agent.conf',
                'linux': '.gnupg/gpg-agent.linux.conf',
                'wsl': '.gnupg/gpg-agent.wsl.conf',
              },
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].repoPath, '.gnupg/gpg-agent.linux.conf');
      expect(
        config.entries[0].configuredRepoPath,
        const PlatformStringValue(
          defaultValue: '.gnupg/gpg-agent.conf',
          linux: '.gnupg/gpg-agent.linux.conf',
          wsl: '.gnupg/gpg-agent.wsl.conf',
        ),
      );
    });

    test('rejects invalid explicit repoPath values', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'repoPath': {'default': '../outside'},
              },
            ],
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching(
          'Repository path must be a relative POSIX path',
        ),
      );

      expect(
        () => parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'repoPath': {'default': '/absolute/path'},
              },
            ],
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching(
          'Repository path must be a relative POSIX path',
        ),
      );
    });

    test('rejects duplicate resolved repo paths from implicit and explicit '
        'entries', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/git/config'},
                'repoPath': {'default': '.gitconfig'},
              },
            ],
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('same repository path'),
      );
    });

    test('rejects duplicate resolved repo paths from platform-specific entries '
        'on the active platform', () async {
      forcePlatform('linux');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gnupg/gpg-agent.conf'},
                'repoPath': {
                  'default': '.gnupg/gpg-agent.conf',
                  'linux': '.gnupg/gpg-agent.linux.conf',
                },
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/gpg-agent/linux.conf'},
                'repoPath': {'default': '.gnupg/gpg-agent.linux.conf'},
              },
            ],
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('same repository path'),
      );
    });

    test('allows parent-child path overlaps', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
              'mode': {'default': 'secret'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries, hasLength(2));
    });

    test('child inherits mode from parent directory', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'secret'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/aliases.zsh'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final child = findEntry(
        config,
        (e) => e.repoPath == '.config/zsh/aliases.zsh',
      );
      expect(child?.mode, 'secret');
      expect(child?.modeExplicit, false);
    });

    test('child inherits profiles from parent directory', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'profiles': ['vivident', 'default'],
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final child = findEntry(
        config,
        (e) => e.repoPath == '.config/zsh/secrets.zsh',
      );
      expect(child?.profiles, ['vivident', 'default']);
      expect(child?.profilesExplicit, false);
    });

    test('explicit child mode overrides parent', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'secret'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/aliases.zsh'},
              'mode': {'default': 'normal'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final child = findEntry(
        config,
        (e) => e.repoPath == '.config/zsh/aliases.zsh',
      );
      expect(child?.mode, 'normal');
      expect(child?.modeExplicit, true);
      expect(
        child?.configuredMode,
        const PlatformSyncMode(defaultValue: 'normal'),
      );
    });

    test(
      'inherits the full parent mode policy when child mode is omitted',
      () async {
        forcePlatform('win');
        final workspace = await createTemporaryDirectory(
          'dotweave-sync-config-',
        );
        final homeDirectory = p.join(workspace, 'home');

        final config = parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/zsh'},
                'mode': {'default': 'normal', 'mac': 'secret', 'win': 'ignore'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/zsh/aliases.zsh'},
              },
            ],
          },
          {'HOME': homeDirectory},
        );

        final child = findEntry(
          config,
          (e) => e.repoPath == '.config/zsh/aliases.zsh',
        );

        expect(
          child?.configuredMode,
          const PlatformSyncMode(
            defaultValue: 'normal',
            mac: 'secret',
            win: 'ignore',
          ),
        );
        expect(child?.mode, 'ignore');
      },
    );

    test(
      'does not merge parent platform overrides into explicit child mode',
      () async {
        forcePlatform('win');
        final workspace = await createTemporaryDirectory(
          'dotweave-sync-config-',
        );
        final homeDirectory = p.join(workspace, 'home');

        final config = parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/zsh'},
                'mode': {'default': 'normal', 'mac': 'secret', 'win': 'ignore'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/zsh/aliases.zsh'},
                'mode': {'default': 'secret'},
              },
            ],
          },
          {'HOME': homeDirectory},
        );

        final child = findEntry(
          config,
          (e) => e.repoPath == '.config/zsh/aliases.zsh',
        );

        expect(
          child?.configuredMode,
          const PlatformSyncMode(defaultValue: 'secret'),
        );
        expect(child?.mode, 'secret');
      },
    );

    test('transitive inheritance through multiple levels', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config'},
              'profiles': ['vivident'],
              'mode': {'default': 'secret'},
            },
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final mid = findEntry(config, (e) => e.repoPath == '.config/zsh');
      final leaf = findEntry(
        config,
        (e) => e.repoPath == '.config/zsh/secrets.zsh',
      );

      expect(mid?.profiles, ['vivident']);
      expect(mid?.mode, 'secret');
      expect(leaf?.profiles, ['vivident']);
      expect(leaf?.mode, 'secret');
    });

    test('entry order in config does not affect inheritance', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
            },
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'profiles': ['vivident'],
              'mode': {'default': 'secret'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final child = findEntry(
        config,
        (e) => e.repoPath == '.config/zsh/secrets.zsh',
      );
      expect(child?.profiles, ['vivident']);
      expect(child?.mode, 'secret');
    });

    test('root entry with no parent uses defaults', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].profiles, <String>[]);
      expect(config.entries[0].mode, 'normal');
    });

    test('parses entries with object localPath format', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/app',
                'linux': r'$XDG_CONFIG_HOME/app',
              },
            },
          ],
          'version': 7,
        },
        {
          'HOME': homeDirectory,
          'XDG_CONFIG_HOME': p.join(homeDirectory, '.config'),
        },
      );

      expect(config.entries, hasLength(1));
      expect(config.entries[0].repoPath, '.config/app');
      expect(
        config.entries[0].configuredLocalPath,
        const PlatformStringValue(
          defaultValue: '~/.config/app',
          linux: r'$XDG_CONFIG_HOME/app',
        ),
      );
    });

    test(
      'derives repoPath from default path regardless of platform overrides',
      () async {
        final workspace = await createTemporaryDirectory(
          'dotweave-sync-config-',
        );
        final homeDirectory = p.join(workspace, 'home');

        final config = parseSyncConfig(
          {
            'entries': [
              {
                'kind': 'file',
                'localPath': {
                  'default': '~/.config/tool/settings.json',
                  'mac': '~/Library/Application Support/tool/settings.json',
                },
              },
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        );

        expect(config.entries[0].repoPath, '.config/tool/settings.json');
      },
    );

    test('parses entries with default-only object localPath', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries, hasLength(1));
      expect(config.entries[0].repoPath, '.gitconfig');
    });

    test('resolves localPath using linux platform override', () async {
      forcePlatform('linux');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(homeDirectory, '.config');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/app',
                'linux': r'$XDG_CONFIG_HOME/app',
              },
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory, 'XDG_CONFIG_HOME': xdgConfigHome},
      );

      expect(config.entries[0].localPath, p.join(xdgConfigHome, 'app'));
    });

    test('resolves repoPath using linux platform override', () async {
      forcePlatform('linux');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gnupg/gpg-agent.conf'},
              'repoPath': {
                'default': '.gnupg/gpg-agent.conf',
                'linux': '.gnupg/gpg-agent.linux.conf',
              },
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].repoPath, '.gnupg/gpg-agent.linux.conf');
    });

    test('resolves localPath using WSL override before linux', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(homeDirectory, '.config');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/app',
                'linux': r'$XDG_CONFIG_HOME/app-linux',
                'wsl': r'$XDG_CONFIG_HOME/app-wsl',
              },
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory, 'XDG_CONFIG_HOME': xdgConfigHome},
      );

      expect(config.entries[0].localPath, p.join(xdgConfigHome, 'app-wsl'));
      expect(
        config.entries[0].configuredLocalPath,
        const PlatformStringValue(
          defaultValue: '~/.config/app',
          linux: r'$XDG_CONFIG_HOME/app-linux',
          wsl: r'$XDG_CONFIG_HOME/app-wsl',
        ),
      );
    });

    test('falls back to linux localPath on WSL when wsl is omitted', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(homeDirectory, '.config');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/app',
                'linux': r'$XDG_CONFIG_HOME/app',
              },
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory, 'XDG_CONFIG_HOME': xdgConfigHome},
      );

      expect(config.entries[0].localPath, p.join(xdgConfigHome, 'app'));
    });

    test('resolves repoPath using WSL override before linux', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gnupg/gpg-agent.conf'},
              'repoPath': {
                'default': '.gnupg/gpg-agent.conf',
                'linux': '.gnupg/gpg-agent.linux.conf',
                'wsl': '.gnupg/gpg-agent.wsl.conf',
              },
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].repoPath, '.gnupg/gpg-agent.wsl.conf');
    });

    test('falls back to linux repoPath on WSL when wsl is omitted', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gnupg/gpg-agent.conf'},
              'repoPath': {
                'default': '.gnupg/gpg-agent.conf',
                'linux': '.gnupg/gpg-agent.linux.conf',
              },
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].repoPath, '.gnupg/gpg-agent.linux.conf');
    });

    test('resolves platform-specific modes for the current OS', () async {
      forcePlatform('mac');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal', 'mac': 'secret', 'win': 'ignore'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(
        config.entries[0].configuredMode,
        const PlatformSyncMode(
          defaultValue: 'normal',
          mac: 'secret',
          win: 'ignore',
        ),
      );
      expect(config.entries[0].mode, 'secret');
    });

    test('resolves WSL-specific mode before linux', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal', 'linux': 'ignore', 'wsl': 'secret'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(
        config.entries[0].configuredMode,
        const PlatformSyncMode(
          defaultValue: 'normal',
          linux: 'ignore',
          wsl: 'secret',
        ),
      );
      expect(config.entries[0].mode, 'secret');
    });

    test('falls back to linux mode on WSL when wsl is omitted', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal', 'linux': 'ignore'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].mode, 'ignore');
    });

    test(
      'inherits WSL mode policy from parent when child mode is omitted',
      () async {
        forcePlatform('wsl');
        final workspace = await createTemporaryDirectory(
          'dotweave-sync-config-',
        );
        final homeDirectory = p.join(workspace, 'home');

        final config = parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/zsh'},
                'mode': {
                  'default': 'normal',
                  'linux': 'ignore',
                  'wsl': 'secret',
                },
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/zsh/aliases.zsh'},
              },
            ],
          },
          {'HOME': homeDirectory},
        );

        final child = findEntry(
          config,
          (e) => e.repoPath == '.config/zsh/aliases.zsh',
        );

        expect(
          child?.configuredMode,
          const PlatformSyncMode(
            defaultValue: 'normal',
            linux: 'ignore',
            wsl: 'secret',
          ),
        );
        expect(child?.mode, 'secret');
      },
    );

    test(
      'does not merge parent WSL overrides into explicit child mode',
      () async {
        forcePlatform('wsl');
        final workspace = await createTemporaryDirectory(
          'dotweave-sync-config-',
        );
        final homeDirectory = p.join(workspace, 'home');

        final config = parseSyncConfig(
          {
            'version': 7,
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/zsh'},
                'mode': {
                  'default': 'normal',
                  'linux': 'ignore',
                  'wsl': 'secret',
                },
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/zsh/aliases.zsh'},
                'mode': {'default': 'secret'},
              },
            ],
          },
          {'HOME': homeDirectory},
        );

        final child = findEntry(
          config,
          (e) => e.repoPath == '.config/zsh/aliases.zsh',
        );

        expect(
          child?.configuredMode,
          const PlatformSyncMode(defaultValue: 'secret'),
        );
        expect(child?.mode, 'secret');
      },
    );

    test('rejects string mode format', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'mode': 'secret',
              },
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('Sync configuration is invalid.'),
      );
    });

    test('rejects localPath object missing default field', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'entries': [
              {
                'kind': 'file',
                'localPath': {'linux': '~/.gitconfig'},
              },
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('Sync configuration is invalid.'),
      );
    });

    test('rejects repoPath object missing default field', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'repoPath': {'linux': '.gitconfig'},
              },
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('Sync configuration is invalid.'),
      );
    });

    test('rejects string localPath format', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'entries': [
              {'kind': 'file', 'localPath': '~/.gitconfig'},
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('Sync configuration is invalid.'),
      );
    });

    test('parses entries with permission field', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/id_rsa'},
              'mode': {'default': 'secret'},
              'permission': {'default': '0600'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].permission, 0x180); // 0o600
      expect(config.entries[0].permissionExplicit, true);
      expect(
        config.entries[0].configuredPermission,
        const PlatformPermission(defaultValue: '0600'),
      );
    });

    test('resolves platform-specific permission', () async {
      forcePlatform('mac');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/id_rsa'},
              'permission': {'default': '0600', 'mac': '0400'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].permission, 0x100); // 0o400
      expect(
        config.entries[0].configuredPermission,
        const PlatformPermission(defaultValue: '0600', mac: '0400'),
      );
    });

    test('inherits permission from parent directory entry', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.ssh'},
              'permission': {'default': '0600'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/config'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final child = findEntry(config, (e) => e.repoPath == '.ssh/config');
      expect(child?.permission, 0x180); // 0o600
      expect(child?.permissionExplicit, false);
      expect(
        child?.configuredPermission,
        const PlatformPermission(defaultValue: '0600'),
      );
    });

    test('child explicit permission overrides parent permission', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.ssh'},
              'permission': {'default': '0600'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/id_rsa.pub'},
              'permission': {'default': '0644'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final child = findEntry(config, (e) => e.repoPath == '.ssh/id_rsa.pub');
      expect(child?.permission, 0x1A4); // 0o644
      expect(child?.permissionExplicit, true);
    });

    test('entries without permission have undefined permission', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].permission, isNull);
      expect(config.entries[0].permissionExplicit, false);
      expect(config.entries[0].configuredPermission, isNull);
    });

    test('rejects invalid permission octal strings', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.ssh/id_rsa'},
                'permission': {'default': '600'},
              },
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        throwsDotweaveErrorMatching('Sync configuration is invalid.'),
      );
    });

    test('resolves WSL permission with fallback to linux', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/id_rsa'},
              'permission': {'default': '0644', 'linux': '0600'},
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      expect(config.entries[0].permission, 0x180); // 0o600
    });

    test('inherits WSL permission fallback from parent directories', () async {
      forcePlatform('wsl');
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'version': 7,
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.ssh'},
              'permission': {'default': '0644', 'linux': '0600'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/id_rsa'},
            },
          ],
        },
        {'HOME': homeDirectory},
      );

      final child = findEntry(
        config,
        (entry) => entry.repoPath == '.ssh/id_rsa',
      );
      expect(child?.permission, 0x180); // 0o600
      expect(child?.permissionExplicit, false);
      expect(
        child?.configuredPermission,
        const PlatformPermission(defaultValue: '0644', linux: '0600'),
      );
    });

    test('ignores unsupported platform keys in permission objects (unknown '
        'field)', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      expect(
        () => parseSyncConfig(
          {
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.ssh/id_rsa'},
                'permission': {'default': '0600', 'freebsd': '0600'},
              },
            ],
            'version': 7,
          },
          {'HOME': homeDirectory},
        ),
        returnsNormally,
      );
    });

    test('treats profiles as an allowlist', () async {
      final workspace = await createTemporaryDirectory('dotweave-sync-config-');
      final homeDirectory = p.join(workspace, 'home');

      final config = parseSyncConfig(
        {
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/config'},
              'profiles': ['vivident'],
              'mode': {'default': 'secret'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.npmrc'},
              'profiles': ['default', 'work'],
            },
          ],
          'version': 7,
        },
        {'HOME': homeDirectory},
      );

      // No profiles specified → syncs on all profiles using default namespace
      expect(resolveSyncRule(config, '.gitconfig'), (
        profile: 'default',
        mode: 'normal',
      ));
      expect(resolveSyncRule(config, '.gitconfig', 'vivident'), (
        profile: 'default',
        mode: 'normal',
      ));

      // profiles: ["vivident"] → only vivident
      expect(resolveSyncRule(config, '.ssh/config', 'vivident'), (
        profile: 'vivident',
        mode: 'secret',
      ));
      expect(resolveSyncRule(config, '.ssh/config'), isNull);
      expect(resolveSyncRule(config, '.ssh/config', 'work'), isNull);

      // profiles: ["default", "work"] → default and work only
      expect(resolveSyncRule(config, '.npmrc'), (
        profile: 'default',
        mode: 'normal',
      ));
      expect(resolveSyncRule(config, '.npmrc', 'work'), (
        profile: 'work',
        mode: 'normal',
      ));
      expect(resolveSyncRule(config, '.npmrc', 'vivident'), isNull);
    });
  });
}
