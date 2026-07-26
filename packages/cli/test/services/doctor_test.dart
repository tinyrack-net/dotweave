import 'dart:typed_data';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/services/doctor.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:test/test.dart';

/// Stands in for the vitest `vi.hoisted` mock registry used by
/// `doctor.test.ts`: mutable seams plus recorded calls for the spied
/// functions.
class MockedDoctorSeams {
  MockedDoctorSeams();

  final List<String> loadSyncConfigCalls = [];
  final List<String> pathExistsCalls = [];

  Future<Map<String, SnapshotNode>> Function(
    String syncDirectory,
    EffectiveSyncConfig config,
  )
  buildRepositorySnapshot = (syncDirectory, config) =>
      throw StateError('buildRepositorySnapshot was not mocked');
  Future<void> Function(String directory) verifyIsGitRepository = (directory) =>
      throw StateError('verifyIsGitRepository was not mocked');
  Future<LoadedSyncConfig> Function(String syncDirectory) loadSyncConfig =
      (syncDirectory) => throw StateError('loadSyncConfig was not mocked');
  Future<bool> Function(String path) pathExists = (path) =>
      throw StateError('pathExists was not mocked');
  SyncPaths Function() resolveSyncPaths = () => const SyncPaths(
    configPath: '/tmp/dotweave/manifest.jsonc',
    globalConfigPath: '/tmp/home/.config/dotweave/settings.jsonc',
    homeDirectory: '/tmp/home',
    syncDirectory: '/tmp/dotweave',
  );

  DoctorDependencies get dependencies {
    return DoctorDependencies(
      buildRepositorySnapshot: (syncDirectory, config) =>
          buildRepositorySnapshot(syncDirectory, config),
      loadSyncConfig: (syncDirectory) {
        loadSyncConfigCalls.add(syncDirectory);
        return loadSyncConfig(syncDirectory);
      },
      pathExists: (path) {
        pathExistsCalls.add(path);
        return pathExists(path);
      },
      resolveSyncPaths: () => resolveSyncPaths(),
      verifyIsGitRepository: (directory) => verifyIsGitRepository(directory),
    );
  }
}

LoadedSyncConfig createLoadedConfig({
  String? activeProfile,
  List<String>? entryKinds,
  required List<String> entryLocalPaths,
  List<String>? entryModes,
  String? identityFile,
  int? recipientCount,
}) {
  final resolvedIdentityFile = identityFile ?? '/tmp/dotweave/keys.txt';
  final entries = [
    for (var index = 0; index < entryLocalPaths.length; index += 1)
      ResolvedSyncConfigEntry(
        configuredLocalPath: PlatformStringValue(
          defaultValue: entryLocalPaths[index],
        ),
        configuredMode: PlatformSyncMode(
          defaultValue: entryModes?[index] ?? 'normal',
        ),
        kind: entryKinds?[index] ?? 'file',
        localPath: entryLocalPaths[index],
        mode: entryModes?[index] ?? 'normal',
        modeExplicit: false,
        permissionExplicit: false,
        profiles: const [],
        profilesExplicit: false,
        repoPath: '.config/item-$index',
      ),
  ];

  return LoadedSyncConfig(
    effectiveConfig: EffectiveSyncConfig(
      activeProfile: activeProfile,
      age: RuntimeAgeConfig(
        identityFile: resolvedIdentityFile,
        recipients: [
          for (var index = 0; index < (recipientCount ?? 1); index += 1)
            'age1recipient$index',
        ],
      ),
      entries: entries,
      version: 7,
    ),
    fullConfig: ResolvedSyncConfig(entries: entries, version: 7),
  );
}

FileSnapshotNode fileSnapshotNode() {
  return FileSnapshotNode(
    contents: Uint8List(0),
    executable: false,
    secret: false,
  );
}

void main() {
  group('sync doctor', () {
    test('returns an immediate git failure when the sync directory is not a '
        'repository', () async {
      final mocked = MockedDoctorSeams();
      mocked.verifyIsGitRepository = (directory) async {
        // Mirrors the TS `mockRejectedValueOnce("not-a-repo")` string
        // rejection. The raw String is the point: it is deliberately not
        // "error-like", which is the branch of `_isErrorLike` under test here
        // (an Exception would surface its own message instead of the generic
        // fallback). Production code cannot throw this, hence the ignore.
        // ignore: only_throw_errors
        throw 'not-a-repo';
      };

      final result = await runDoctorChecks(mocked.dependencies);

      expect(
        result,
        const DoctorResult(
          checks: [
            DoctorCheck(
              checkId: 'git',
              detail: 'Git repository check failed.',
              level: 'fail',
            ),
          ],
          hasFailures: true,
          hasWarnings: false,
        ),
      );
      expect(mocked.loadSyncConfigCalls, isEmpty);
    });

    test(
      'returns a configuration failure after a successful repository check',
      () async {
        final mocked = MockedDoctorSeams();
        mocked.verifyIsGitRepository = (directory) async {};
        mocked.loadSyncConfig = (syncDirectory) async {
          throw Exception('config is invalid');
        };

        final result = await runDoctorChecks(mocked.dependencies);

        expect(
          result,
          const DoctorResult(
            checks: [
              DoctorCheck(
                checkId: 'git',
                detail: 'Sync directory is a git repository.',
                level: 'ok',
              ),
              DoctorCheck(
                checkId: 'config',
                detail: 'config is invalid',
                level: 'fail',
              ),
            ],
            hasFailures: true,
            hasWarnings: false,
          ),
        );
      },
    );

    test(
      'preserves config failure details and hint text in doctor output',
      () async {
        final mocked = MockedDoctorSeams();
        mocked.verifyIsGitRepository = (directory) async {};
        mocked.loadSyncConfig = (syncDirectory) async {
          throw DotweaveError(
            'Sync configuration is invalid.',
            details: ['age: Unrecognized key(s) in object: "identityFile"'],
          );
        };

        final result = await runDoctorChecks(mocked.dependencies);

        expect(
          result.checks,
          contains(
            const DoctorCheck(
              checkId: 'config',
              detail:
                  'Sync configuration is invalid.\n'
                  'age: Unrecognized key(s) in object: "identityFile"',
              level: 'fail',
            ),
          ),
        );
      },
    );

    test('reports details and treats missing paths as healthy when they are '
        'absent in the current sync state', () async {
      final mocked = MockedDoctorSeams();
      mocked.verifyIsGitRepository = (directory) async {};
      mocked.loadSyncConfig = (syncDirectory) async {
        return createLoadedConfig(
          entryLocalPaths: ['/tmp/home/.ssh/id_ed25519'],
        );
      };
      mocked.buildRepositorySnapshot = (syncDirectory, config) async {
        return <String, SnapshotNode>{};
      };
      mocked.pathExists = (path) async {
        return path != '/tmp/dotweave/keys.txt' &&
            path != '/tmp/home/.ssh/id_ed25519';
      };

      final result = await runDoctorChecks(mocked.dependencies);

      expect(result.hasFailures, true);
      expect(result.hasWarnings, false);
      expect(result.checks, const [
        DoctorCheck(
          checkId: 'git',
          detail: 'Sync directory is a git repository.',
          level: 'ok',
        ),
        DoctorCheck(
          checkId: 'config',
          detail: 'Loaded config with 1 entries and 1 recipients.',
          level: 'ok',
        ),
        DoctorCheck(
          checkId: 'profiles',
          detail: 'No active profile configured.',
          level: 'ok',
        ),
        DoctorCheck(
          checkId: 'age',
          detail: 'Age identity file is missing: /tmp/dotweave/keys.txt',
          level: 'fail',
        ),
        DoctorCheck(
          checkId: 'entries',
          detail: 'Tracked 1 sync entries.',
          level: 'ok',
        ),
        DoctorCheck(
          checkId: 'local-paths',
          detail:
              'All missing local paths are healthy for the current sync '
              'state (1 entry).',
          level: 'ok',
        ),
      ]);
      expect(mocked.pathExistsCalls, contains('/tmp/dotweave/keys.txt'));
      expect(mocked.pathExistsCalls, contains('/tmp/home/.ssh/id_ed25519'));
    });

    test('reports batch progress while treating multiple missing paths as '
        'healthy when nothing should be materialized', () async {
      final mocked = MockedDoctorSeams();
      mocked.verifyIsGitRepository = (directory) async {};
      mocked.loadSyncConfig = (syncDirectory) async {
        return createLoadedConfig(
          activeProfile: 'work',
          entryLocalPaths: [
            for (var index = 0; index < 98; index += 1) '/tmp/present-$index',
            '/tmp/missing-a',
            '/tmp/missing-b',
          ],
          recipientCount: 2,
        );
      };
      mocked.buildRepositorySnapshot = (syncDirectory, config) async {
        return <String, SnapshotNode>{};
      };
      mocked.pathExists = (path) async {
        return path != '/tmp/missing-a' && path != '/tmp/missing-b';
      };

      final result = await runDoctorChecks(mocked.dependencies);

      expect(result.hasFailures, false);
      expect(result.hasWarnings, false);
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'profiles',
            detail: 'Active profile: work.',
            level: 'ok',
          ),
        ),
      );
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'age',
            detail: 'Age identity file exists at /tmp/dotweave/keys.txt.',
            level: 'ok',
          ),
        ),
      );
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'entries',
            detail: 'Tracked 100 sync entries.',
            level: 'ok',
          ),
        ),
      );
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'local-paths',
            detail:
                'All missing local paths are healthy for the current sync '
                'state (2 entries).',
            level: 'ok',
          ),
        ),
      );
    });

    test('warns when no entries are configured and still reports healthy local '
        'paths', () async {
      final mocked = MockedDoctorSeams();
      mocked.verifyIsGitRepository = (directory) async {};
      mocked.loadSyncConfig = (syncDirectory) async {
        return createLoadedConfig(entryLocalPaths: []);
      };
      mocked.buildRepositorySnapshot = (syncDirectory, config) async {
        return <String, SnapshotNode>{};
      };
      mocked.pathExists = (path) async => true;

      final result = await runDoctorChecks(mocked.dependencies);

      expect(result.hasFailures, false);
      expect(result.hasWarnings, true);
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'entries',
            detail: 'No sync entries are configured yet.',
            level: 'warn',
          ),
        ),
      );
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'local-paths',
            detail: 'All tracked local paths currently exist.',
            level: 'ok',
          ),
        ),
      );
      expect(mocked.pathExistsCalls, hasLength(1));
    });

    test('does not warn when missing local paths are already materializable '
        'from the sync state', () async {
      final mocked = MockedDoctorSeams();
      mocked.verifyIsGitRepository = (directory) async {};
      mocked.loadSyncConfig = (syncDirectory) async {
        return createLoadedConfig(entryLocalPaths: ['/tmp/home/.gitconfig']);
      };
      mocked.buildRepositorySnapshot = (syncDirectory, config) async {
        return <String, SnapshotNode>{'.config/item-0': fileSnapshotNode()};
      };
      mocked.pathExists = (path) async {
        return path == '/tmp/dotweave/keys.txt';
      };

      final result = await runDoctorChecks(mocked.dependencies);

      expect(result.hasWarnings, false);
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'local-paths',
            detail:
                'All missing local paths are healthy for the current sync '
                'state (1 entry).',
            level: 'ok',
          ),
        ),
      );
    });

    test(
      'skips ignore-mode entries when checking missing local paths',
      () async {
        final mocked = MockedDoctorSeams();
        mocked.verifyIsGitRepository = (directory) async {};
        mocked.loadSyncConfig = (syncDirectory) async {
          return createLoadedConfig(
            entryLocalPaths: ['/tmp/missing-ignore', '/tmp/missing-normal'],
            entryModes: ['ignore', 'normal'],
          );
        };
        mocked.buildRepositorySnapshot = (syncDirectory, config) async {
          return <String, SnapshotNode>{};
        };
        mocked.pathExists = (path) async {
          return path == '/tmp/dotweave/keys.txt';
        };

        final result = await runDoctorChecks(mocked.dependencies);

        expect(
          result.checks,
          contains(
            const DoctorCheck(
              checkId: 'local-paths',
              detail:
                  'All missing local paths are healthy for the current sync '
                  'state (1 entry).',
              level: 'ok',
            ),
          ),
        );
        expect(mocked.pathExistsCalls, isNot(contains('/tmp/missing-ignore')));
        expect(mocked.pathExistsCalls, contains('/tmp/missing-normal'));
      },
    );

    test('treats missing directory entries as healthy when the current sync '
        'state materializes nothing', () async {
      final mocked = MockedDoctorSeams();
      mocked.verifyIsGitRepository = (directory) async {};
      mocked.loadSyncConfig = (syncDirectory) async {
        return createLoadedConfig(
          entryKinds: ['directory'],
          entryLocalPaths: ['/tmp/home/.config/myapp'],
        );
      };
      mocked.buildRepositorySnapshot = (syncDirectory, config) async {
        return <String, SnapshotNode>{};
      };
      mocked.pathExists = (path) async {
        return path == '/tmp/dotweave/keys.txt';
      };

      final result = await runDoctorChecks(mocked.dependencies);

      expect(result.hasWarnings, false);
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'local-paths',
            detail:
                'All missing local paths are healthy for the current sync '
                'state (1 entry).',
            level: 'ok',
          ),
        ),
      );
    });

    test('fails the local-paths check when repository materialization is '
        'inconsistent', () async {
      final mocked = MockedDoctorSeams();
      mocked.verifyIsGitRepository = (directory) async {};
      mocked.loadSyncConfig = (syncDirectory) async {
        return createLoadedConfig(entryLocalPaths: ['/tmp/home/.gitconfig']);
      };
      mocked.buildRepositorySnapshot = (syncDirectory, config) async {
        return <String, SnapshotNode>{
          '.config/item-0': const DirectorySnapshotNode(),
        };
      };
      mocked.pathExists = (path) async {
        return path == '/tmp/dotweave/keys.txt';
      };

      final result = await runDoctorChecks(mocked.dependencies);

      expect(result.hasFailures, true);
      expect(
        result.checks,
        contains(
          const DoctorCheck(
            checkId: 'local-paths',
            detail:
                'File sync entry resolves to a directory in the '
                'repository.\nRepository path: .config/item-0\n'
                "→ Run 'dotweave push' or fix the repository so this path "
                'is stored as a file.',
            level: 'fail',
          ),
        ),
      );
    });
  });
}
