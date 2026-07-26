import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:test/test.dart';

ResolvedSyncConfigEntry makeEntry(
  String repoPath,
  SyncConfigEntryKind kind, {
  String? localPath,
  List<String>? profiles,
  SyncMode? mode,
}) {
  return ResolvedSyncConfigEntry(
    configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
    configuredLocalPath: PlatformStringValue(
      defaultValue: '/home/user/$repoPath',
    ),
    kind: kind,
    localPath: localPath ?? '/home/user/$repoPath',
    profiles: profiles ?? [],
    profilesExplicit: false,
    mode: mode ?? 'normal',
    modeExplicit: false,
    permissionExplicit: false,
    repoPath: repoPath,
  );
}

ResolvedSyncConfig makeConfig(List<ResolvedSyncConfigEntry> entries) {
  return ResolvedSyncConfig(entries: entries, version: 7);
}

void main() {
  group('sync-entry', () {
    group('findOwningSyncEntry', () {
      test('returns undefined for an empty config', () {
        expect(findOwningSyncEntry(makeConfig([]), 'foo'), isNull);
      });

      test('matches an exact file entry', () {
        final entry = makeEntry('.bashrc', 'file');
        expect(
          findOwningSyncEntry(makeConfig([entry]), '.bashrc'),
          same(entry),
        );
      });

      test('matches a directory entry by prefix', () {
        final entry = makeEntry('.config/nvim', 'directory');
        expect(
          findOwningSyncEntry(makeConfig([entry]), '.config/nvim/init.lua'),
          same(entry),
        );
      });

      test('does not match a directory entry for a non-descendant path', () {
        final entry = makeEntry('.config/nvim', 'directory');
        expect(
          findOwningSyncEntry(makeConfig([entry]), '.config/other'),
          isNull,
        );
      });

      test('prefers the longest matching entry (most-specific wins)', () {
        final parent = makeEntry('.config', 'directory');
        final child = makeEntry('.config/nvim', 'directory');
        expect(
          findOwningSyncEntry(
            makeConfig([parent, child]),
            '.config/nvim/init.lua',
          ),
          same(child),
        );
      });

      test('matches a directory entry for its own repo path', () {
        final entry = makeEntry('.config/nvim', 'directory');
        expect(
          findOwningSyncEntry(makeConfig([entry]), '.config/nvim'),
          same(entry),
        );
      });

      test('does not match a file entry for a descendant path', () {
        final entry = makeEntry('.bashrc', 'file');
        expect(
          findOwningSyncEntry(makeConfig([entry]), '.bashrc/extra'),
          isNull,
        );
      });
    });

    group('collectChildEntryPaths', () {
      test('collects children of a directory entry', () {
        final parent = makeEntry('.config', 'directory');
        final child = makeEntry('.config/nvim', 'file');
        final result = collectChildEntryPaths(
          makeConfig([parent, child]),
          '.config',
        );
        expect(result, {'.config/nvim'});
      });

      test('excludes the entry itself', () {
        final entry = makeEntry('.config', 'directory');
        expect(
          collectChildEntryPaths(makeConfig([entry]), '.config'),
          <String>{},
        );
      });

      test('returns empty set for a leaf entry with no children', () {
        final entry = makeEntry('.bashrc', 'file');
        expect(
          collectChildEntryPaths(makeConfig([entry]), '.bashrc'),
          <String>{},
        );
      });

      test('collects local-path shadow paths for platform-specific child repo '
          'paths', () {
        final parent = makeEntry(
          '.config/zsh',
          'directory',
          localPath: '/home/user/.config/zsh',
        );
        final child = makeEntry(
          '.config/zsh/platform.wsl.zsh',
          'file',
          localPath: '/home/user/.config/zsh/platform.zsh',
        );

        expect(collectChildEntryPaths(makeConfig([parent, child]), parent), {
          '.config/zsh/platform.wsl.zsh',
          '.config/zsh/platform.zsh',
        });
      });

      test(
        'does not collect local-path shadow paths for sibling local paths',
        () {
          final parent = makeEntry(
            '.config/zsh',
            'directory',
            localPath: '/home/user/.config/zsh',
          );
          final sibling = makeEntry(
            '.config/zsh-other/platform.wsl.zsh',
            'file',
            localPath: '/home/user/.config/zsh-other/platform.zsh',
          );

          expect(
            collectChildEntryPaths(makeConfig([parent, sibling]), parent),
            <String>{},
          );
        },
      );
    });

    group('resolveEntryRelativeRepoPath', () {
      test(
        'returns empty string for a file entry matching its own repo path',
        () {
          final entry = makeEntry('.bashrc', 'file');
          expect(resolveEntryRelativeRepoPath(entry, '.bashrc'), '');
        },
      );

      test('returns undefined for a file entry with a non-matching path', () {
        final entry = makeEntry('.bashrc', 'file');
        expect(resolveEntryRelativeRepoPath(entry, '.zshrc'), isNull);
      });

      test('returns empty string for a directory entry matching its own repo '
          'path', () {
        final entry = makeEntry('.config/nvim', 'directory');
        expect(resolveEntryRelativeRepoPath(entry, '.config/nvim'), '');
      });

      test('returns the relative suffix for a nested path inside a directory '
          'entry', () {
        final entry = makeEntry('.config/nvim', 'directory');
        expect(
          resolveEntryRelativeRepoPath(entry, '.config/nvim/init.lua'),
          'init.lua',
        );
      });

      test('returns undefined for a non-descendant path', () {
        final entry = makeEntry('.config/nvim', 'directory');
        expect(resolveEntryRelativeRepoPath(entry, '.config/other'), isNull);
      });
    });

    group('resolveSyncRule', () {
      test('returns mode and profile for a matched path', () {
        final entry = makeEntry(
          '.bashrc',
          'file',
          mode: 'normal',
          profiles: ['default'],
        );
        expect(resolveSyncRule(makeConfig([entry]), '.bashrc'), (
          mode: 'normal',
          profile: 'default',
        ));
      });

      test('returns undefined for an unmatched path', () {
        final entry = makeEntry('.bashrc', 'file');
        expect(resolveSyncRule(makeConfig([entry]), '.zshrc'), isNull);
      });

      test('returns undefined when the active profile is not in the entry '
          'profiles', () {
        final entry = makeEntry('.bashrc', 'file', profiles: ['work']);
        expect(
          resolveSyncRule(makeConfig([entry]), '.bashrc', 'personal'),
          isNull,
        );
      });

      test('uses default profile when no active profile is given and entry has '
          'no explicit profiles', () {
        final entry = makeEntry('.bashrc', 'file', profiles: []);
        expect(resolveSyncRule(makeConfig([entry]), '.bashrc'), (
          mode: 'normal',
          profile: 'default',
        ));
      });
    });

    group('resolveSyncMode', () {
      test('returns the mode for a matched path', () {
        final entry = makeEntry('.bashrc', 'file', mode: 'secret');
        expect(resolveSyncMode(makeConfig([entry]), '.bashrc'), 'secret');
      });

      test('returns undefined for an unmatched path', () {
        expect(resolveSyncMode(makeConfig([]), '.bashrc'), isNull);
      });
    });

    group('isIgnoredSyncPath', () {
      test('returns true for an ignored path', () {
        final entry = makeEntry('.bashrc', 'file', mode: 'ignore');
        expect(isIgnoredSyncPath(makeConfig([entry]), '.bashrc'), true);
      });

      test('returns false for a non-ignored path', () {
        final entry = makeEntry('.bashrc', 'file', mode: 'normal');
        expect(isIgnoredSyncPath(makeConfig([entry]), '.bashrc'), false);
      });
    });

    group('isSecretSyncPath', () {
      test('returns true for a secret path', () {
        final entry = makeEntry('.bashrc', 'file', mode: 'secret');
        expect(isSecretSyncPath(makeConfig([entry]), '.bashrc'), true);
      });

      test('returns false for a non-secret path', () {
        final entry = makeEntry('.bashrc', 'file', mode: 'normal');
        expect(isSecretSyncPath(makeConfig([entry]), '.bashrc'), false);
      });
    });

    group('requireManagedSyncMode', () {
      test('returns mode for a managed path', () {
        final entry = makeEntry('.bashrc', 'file', mode: 'normal');
        expect(
          requireManagedSyncMode(makeConfig([entry]), '.bashrc'),
          'normal',
        );
      });

      test(
        'throws DotweaveError with UNMANAGED_SYNC_PATH for an unmanaged path',
        () {
          expect(
            () => requireManagedSyncMode(makeConfig([]), '.bashrc'),
            throwsA(
              isA<DotweaveError>().having(
                (error) => error.message,
                'message',
                'Repository path is not managed by the current sync '
                    'configuration.',
              ),
            ),
          );
        },
      );

      test('includes context in error details when provided', () {
        try {
          requireManagedSyncMode(makeConfig([]), '.bashrc', null, 'push');
        } catch (error) {
          expect(
            error,
            isA<DotweaveError>().having(
              (e) => e.code,
              'code',
              'UNMANAGED_SYNC_PATH',
            ),
          );
          if (error is! DotweaveError) rethrow;
          expect(error.details.any((d) => d.contains('push')), true);
        }
      });
    });

    group('buildDefaultPlatformMode', () {
      test('wraps a mode in platform structure with default key', () {
        expect(
          buildDefaultPlatformMode('normal'),
          const PlatformSyncMode(defaultValue: 'normal'),
        );
      });

      test('wraps secret mode', () {
        expect(
          buildDefaultPlatformMode('secret'),
          const PlatformSyncMode(defaultValue: 'secret'),
        );
      });
    });

    group('hasPlatformSpecificModeOverride', () {
      test('returns false for default-only mode', () {
        expect(
          hasPlatformSpecificModeOverride(
            const PlatformSyncMode(defaultValue: 'normal'),
          ),
          false,
        );
      });

      test('returns true when win override is set', () {
        expect(
          hasPlatformSpecificModeOverride(
            const PlatformSyncMode(defaultValue: 'normal', win: 'ignore'),
          ),
          true,
        );
      });

      test('returns true when mac override is set', () {
        expect(
          hasPlatformSpecificModeOverride(
            const PlatformSyncMode(defaultValue: 'normal', mac: 'secret'),
          ),
          true,
        );
      });

      test('returns true when linux override is set', () {
        expect(
          hasPlatformSpecificModeOverride(
            const PlatformSyncMode(defaultValue: 'normal', linux: 'normal'),
          ),
          true,
        );
      });

      test('returns true when wsl override is set', () {
        expect(
          hasPlatformSpecificModeOverride(
            const PlatformSyncMode(defaultValue: 'normal', wsl: 'normal'),
          ),
          true,
        );
      });
    });

    group('collectAllProfileNames', () {
      test('deduplicates and sorts profile names', () {
        final entries = [
          makeEntry('a', 'file', profiles: ['work', 'personal']),
          makeEntry('b', 'file', profiles: ['personal', 'shared']),
        ];
        expect(collectAllProfileNames(entries), ['personal', 'shared', 'work']);
      });

      test(
        'includes the default profile for entries with no explicit profiles',
        () {
          final entries = [makeEntry('a', 'file', profiles: [])];
          expect(collectAllProfileNames(entries), ['default']);
        },
      );

      test('deduplicates implicit and explicit default profiles', () {
        final entries = [
          makeEntry('a', 'file', profiles: []),
          makeEntry('b', 'file', profiles: ['work']),
          makeEntry('c', 'file', profiles: ['default']),
        ];

        expect(collectAllProfileNames(entries), ['default', 'work']);
      });
    });
  });
}
