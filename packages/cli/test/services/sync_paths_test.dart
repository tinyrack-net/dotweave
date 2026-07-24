import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/sync_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Mirrors node:path `resolve` using the platform-native path context.
String resolvePath(String first, [String? second]) {
  return p.normalize(p.joinAll([p.current, first, ?second]));
}

ResolvedSyncConfigEntry trackedEntry({
  PlatformStringValue configuredLocalPath = const PlatformStringValue(
    defaultValue: '~/.gitconfig',
  ),
  String localPath = '/tmp/home/.gitconfig',
  String repoPath = '.gitconfig',
}) {
  return ResolvedSyncConfigEntry(
    configuredLocalPath: configuredLocalPath,
    configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
    kind: 'file',
    localPath: localPath,
    mode: 'normal',
    modeExplicit: false,
    permissionExplicit: false,
    profiles: const [],
    profilesExplicit: false,
    repoPath: repoPath,
  );
}

void main() {
  group('path helpers', () {
    test('builds repository paths within a root', () {
      expect(
        buildRepoPathWithinRoot(
          resolvePath('/tmp/home', '.config/tool/settings.json'),
          resolvePath('/tmp/home'),
          'Sync target',
        ),
        '.config/tool/settings.json',
      );
      expect(
        buildConfiguredHomeLocalPath('.config/tool/settings.json'),
        equals(
          const PlatformStringValue(
            defaultValue: '~/.config/tool/settings.json',
          ),
        ),
      );
    });

    test('rejects root and out-of-root repository paths', () {
      expect(
        () {
          buildRepoPathWithinRoot(
            resolvePath('/tmp/home'),
            resolvePath('/tmp/home'),
            'Sync target',
          );
        },
        throwsA(
          predicate(
            (error) => error.toString().contains(RegExp('root directory')),
          ),
        ),
      );
      expect(
        () {
          buildRepoPathWithinRoot(
            resolvePath('/tmp/elsewhere'),
            resolvePath('/tmp/home'),
            'Sync target',
          );
        },
        throwsA(
          predicate(
            (error) => error.toString().contains(
              RegExp('must stay inside the configured home root'),
            ),
          ),
        ),
      );
    });

    test('returns undefined from tolerant helpers for invalid inputs', () {
      expect(
        tryBuildRepoPathWithinRoot(
          resolvePath('/tmp/elsewhere'),
          resolvePath('/tmp/home'),
          'Sync target',
        ),
        isNull,
      );
      expect(tryNormalizeRepoPathInput('../bundle'), isNull);
    });

    test(
      'resolves tracked entries by repository path for non-explicit targets',
      () {
        final entry = trackedEntry(
          configuredLocalPath: const PlatformStringValue(
            defaultValue: '~/.config/tool/settings.json',
          ),
          localPath: '/tmp/home/.config/tool/settings.json',
          repoPath: '.config/tool/settings.json',
        );

        expect(
          resolveTrackedEntry(
            '.config/tool/settings.json',
            [entry],
            '/tmp/cwd',
            '/tmp/home',
          ),
          equals(entry),
        );
      },
    );

    test('resolves tracked entries by expanded local path', () {
      final entry = trackedEntry(
        localPath: resolvePath('/tmp/home', 'bundle'),
        repoPath: 'bundle',
      );

      expect(
        resolveTrackedEntry('~/bundle', [entry], '/tmp/cwd', '/tmp/home'),
        equals(entry),
      );
      expect(
        resolveTrackedEntry('./bundle', [entry], '/tmp/home', '/tmp/home'),
        equals(entry),
      );
    });

    test(
      'rejects ambiguous tracked entries for the same explicit local path',
      () {
        expect(
          () {
            resolveTrackedEntry(
              '/tmp/home/.gitconfig',
              [
                trackedEntry(
                  localPath: resolvePath('/tmp/home/.gitconfig'),
                  repoPath: '.gitconfig',
                ),
                trackedEntry(
                  localPath: resolvePath('/tmp/home/.gitconfig'),
                  repoPath: '.gitconfig-work',
                ),
              ],
              '/tmp/cwd',
              '/tmp/home',
            );
          },
          throwsA(
            predicate(
              (error) => error.toString().contains(
                RegExp('Multiple tracked sync entries match'),
              ),
            ),
          ),
        );
      },
    );

    test('resolves tracked entries by relative cwd path', () {
      final entry = trackedEntry(
        localPath: resolvePath('/tmp/home', 'bundle'),
        repoPath: 'bundle',
      );

      expect(
        resolveTrackedEntry('bundle', [entry], '/tmp/home', '/tmp/home'),
        equals(entry),
      );
    });

    test('returns undefined when no entries match the target', () {
      expect(
        resolveTrackedEntry(
          'nonexistent',
          [trackedEntry(repoPath: '.gitconfig')],
          '/tmp/cwd',
          '/tmp/home',
        ),
        isNull,
      );
    });

    test('handles tryNormalizeRepoPathInput for valid paths', () {
      expect(tryNormalizeRepoPathInput('config/app'), 'config/app');
    });

    test('handles tryNormalizeRepoPathInput for absolute paths', () {
      expect(tryNormalizeRepoPathInput('/absolute/path'), isNull);
    });
  });
}
