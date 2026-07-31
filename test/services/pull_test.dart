import 'dart:typed_data';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/pull_apply.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:test/test.dart';

PullCounts zeroPullCounts(List<EntryMaterialization?> materializations) {
  return (
    decryptedFileCount: 0,
    directoryCount: 0,
    plainFileCount: 0,
    symlinkCount: 0,
  );
}

void main() {
  ResolvedSyncConfigEntry createTestEntry(
    SyncConfigEntryKind kind,
    String localPath,
    String repoPath,
    SyncMode mode, [
    int? permission,
  ]) {
    return ResolvedSyncConfigEntry(
      configuredLocalPath: PlatformStringValue(defaultValue: localPath),
      configuredMode: PlatformSyncMode(defaultValue: mode),
      kind: kind,
      localPath: localPath,
      mode: mode,
      modeExplicit: true,
      permission: permission,
      permissionExplicit: permission != null,
      profiles: const [],
      profilesExplicit: false,
      repoPath: repoPath,
    );
  }

  EffectiveSyncConfig createTestConfig([
    List<ResolvedSyncConfigEntry> entries = const [],
  ]) {
    return EffectiveSyncConfig(
      version: 7,
      entries: entries,
      age: const RuntimeAgeConfig(
        identityFile: '/tmp/dotweave/keys.txt',
        recipients: ['age1recipient'],
      ),
    );
  }

  group('pull helpers', () {
    test('builds a stable preview from desired and deleted local paths', () {
      expect(
        buildPullPlanPreview(
          const PullPlan(
            counts: (
              decryptedFileCount: 1,
              directoryCount: 1,
              plainFileCount: 2,
              symlinkCount: 0,
            ),
            deletedLocalCount: 2,
            deletedLocalPaths: ['/tmp/obsolete-a', '/tmp/obsolete-b'],
            desiredKeys: {
              'zeta/file.txt',
              'alpha/file.txt',
              'beta/file.txt',
              'gamma/file.txt',
              'delta/file.txt',
            },
            existingKeys: {'alpha/file.txt', 'obsolete-a', 'obsolete-b'},
            materializations: [],
            updatedLocalPaths: [
              '/tmp/alpha/file.txt',
              '/tmp/beta/file.txt',
              '/tmp/delta/file.txt',
              '/tmp/gamma/file.txt',
              '/tmp/zeta/file.txt',
            ],
          ),
        ),
        [
          '/tmp/alpha/file.txt',
          '/tmp/beta/file.txt',
          '/tmp/delta/file.txt',
          '/tmp/gamma/file.txt',
          '/tmp/obsolete-a',
          '/tmp/obsolete-b',
        ],
      );
    });

    test('builds pull results from a completed plan', () {
      expect(
        buildPullResultFromPlan(
          const PullPlan(
            counts: (
              decryptedFileCount: 3,
              directoryCount: 1,
              plainFileCount: 2,
              symlinkCount: 0,
            ),
            deletedLocalCount: 4,
            deletedLocalPaths: [],
            desiredKeys: {},
            existingKeys: {},
            materializations: [],
            updatedLocalPaths: [],
          ),
          true,
        ),
        const PullResult(
          decryptedFileCount: 3,
          deletedLocalCount: 4,
          directoryCount: 1,
          dryRun: true,
          plainFileCount: 2,
          symlinkCount: 0,
        ),
      );
    });
  });

  group('pull planning', () {
    test('skips ignore-mode entries while planning materializations', () async {
      const materialization = AbsentEntryMaterialization(
        desiredKeys: {'.config/app'},
      );
      final buildEntryMaterializationCalls =
          <
            ({
              ResolvedSyncConfigEntry entry,
              Map<String, SnapshotNode> snapshot,
              EffectiveSyncConfig config,
            })
          >[];
      final countDeletedLocalNodesCalls =
          <
            ({
              ResolvedSyncConfigEntry entry,
              Set<String> desiredKeys,
              EffectiveSyncConfig config,
              Set<String>? existingKeys,
              Map<String, String>? keyToLocalPath,
              Set<String>? deletedKeys,
            })
          >[];

      final config = createTestConfig([
        createTestEntry(
          'directory',
          '/tmp/home/.config/app',
          '.config/app',
          'normal',
        ),
        createTestEntry(
          'directory',
          '/tmp/home/.config/app/node_modules',
          '.config/app/node_modules',
          'ignore',
        ),
      ]);

      final plan = await buildPullPlan(
        config,
        '/tmp/dotweave',
        PullDependencies(
          buildEntryMaterialization: (entry, snapshot, config) {
            buildEntryMaterializationCalls.add((
              entry: entry,
              snapshot: snapshot,
              config: config,
            ));
            return materialization;
          },
          buildPullCounts: zeroPullCounts,
          buildRepositorySnapshot: (syncDirectory, config) async => {},
          collectChangedLocalPaths: (entry, materialization, config) async =>
              [],
          countDeletedLocalNodes:
              (
                entry,
                desiredKeys,
                config,
                existingKeys,
                keyToLocalPath,
                deletedKeys,
              ) async {
                countDeletedLocalNodesCalls.add((
                  entry: entry,
                  desiredKeys: desiredKeys,
                  config: config,
                  existingKeys: existingKeys,
                  keyToLocalPath: keyToLocalPath,
                  deletedKeys: deletedKeys,
                ));
                return 0;
              },
        ),
      );

      expect(buildEntryMaterializationCalls, hasLength(1));
      expect(
        buildEntryMaterializationCalls.single.entry,
        same(config.entries[0]),
      );
      expect(
        buildEntryMaterializationCalls.single.snapshot,
        isA<Map<String, SnapshotNode>>(),
      );
      expect(buildEntryMaterializationCalls.single.config, same(config));
      expect(countDeletedLocalNodesCalls, hasLength(1));
      expect(countDeletedLocalNodesCalls.single.entry, same(config.entries[0]));
      expect(countDeletedLocalNodesCalls.single.desiredKeys, {'.config/app'});
      expect(countDeletedLocalNodesCalls.single.config, same(config));
      expect(countDeletedLocalNodesCalls.single.existingKeys, <String>{});
      expect(
        countDeletedLocalNodesCalls.single.keyToLocalPath,
        <String, String>{},
      );
      expect(countDeletedLocalNodesCalls.single.deletedKeys, <String>{});
      expect(plan.materializations, equals([materialization, null]));
      expect(plan.desiredKeys, {'.config/app'});
      expect(plan.updatedLocalPaths, isEmpty);
      expect(plan.deletedLocalPaths, isEmpty);
    });

    test(
      'does not report child entry paths as parent directory updates',
      () async {
        final materializationQueue = <EntryMaterialization>[
          const DirectoryEntryMaterialization(
            desiredKeys: {'.config/zsh/.zshenv', '.config/zsh/secrets.zsh'},
            nodes: {},
          ),
          FileEntryMaterialization(
            desiredKeys: const {'.config/zsh/secrets.zsh'},
            node: FileSnapshotNode(
              contents: Uint8List(0),
              executable: false,
              secret: true,
            ),
          ),
        ];
        final changedLocalPathsQueue = <List<String>>[
          [
            '/tmp/home/.config/zsh/.zshenv',
            '/tmp/home/.config/zsh/secrets.zsh',
          ],
          [],
        ];

        final config = createTestConfig([
          createTestEntry(
            'directory',
            '/tmp/home/.config/zsh',
            '.config/zsh',
            'normal',
          ),
          createTestEntry(
            'file',
            '/tmp/home/.config/zsh/secrets.zsh',
            '.config/zsh/secrets.zsh',
            'secret',
            0x180, // 0o600
          ),
        ]);

        final plan = await buildPullPlan(
          config,
          '/tmp/dotweave',
          PullDependencies(
            buildEntryMaterialization: (entry, snapshot, config) =>
                materializationQueue.removeAt(0),
            buildPullCounts: zeroPullCounts,
            buildRepositorySnapshot: (syncDirectory, config) async => {},
            collectChangedLocalPaths: (entry, materialization, config) async =>
                changedLocalPathsQueue.removeAt(0),
            countDeletedLocalNodes:
                (
                  entry,
                  desiredKeys,
                  config,
                  existingKeys,
                  keyToLocalPath,
                  deletedKeys,
                ) async => 0,
          ),
        );

        expect(plan.updatedLocalPaths, ['/tmp/home/.config/zsh/.zshenv']);
      },
    );

    test('does not report deleted local paths as repository updates', () async {
      final config = createTestConfig([
        createTestEntry(
          'directory',
          '/tmp/home/.config/app',
          '.config/app',
          'normal',
        ),
      ]);

      final plan = await buildPullPlan(
        config,
        '/tmp/dotweave',
        PullDependencies(
          buildEntryMaterialization: (entry, snapshot, config) =>
              const DirectoryEntryMaterialization(
                desiredKeys: {'.config/app/', '.config/app/config.json'},
                nodes: {},
              ),
          buildPullCounts: zeroPullCounts,
          buildRepositorySnapshot: (syncDirectory, config) async => {},
          collectChangedLocalPaths: (entry, materialization, config) async => [
            '/tmp/home/.config/app/cache.json',
            '/tmp/home/.config/app/config.json',
          ],
          countDeletedLocalNodes:
              (
                entry,
                desiredKeys,
                config,
                existingKeys,
                keyToLocalPath,
                deletedKeys,
              ) async {
                existingKeys?.add('.config/app/');
                existingKeys?.add('.config/app/config.json');
                existingKeys?.add('.config/app/cache.json');
                keyToLocalPath?['.config/app/cache.json'] =
                    '/tmp/home/.config/app/cache.json';
                deletedKeys?.add('.config/app/cache.json');
                return 1;
              },
        ),
      );

      expect(plan.updatedLocalPaths, ['/tmp/home/.config/app/config.json']);
      expect(plan.deletedLocalPaths, ['/tmp/home/.config/app/cache.json']);
    });

    test('does not apply ignore-mode entries during pull', () async {
      final config = createTestConfig([
        createTestEntry(
          'directory',
          '/tmp/home/.config/app',
          '.config/app',
          'normal',
        ),
        createTestEntry(
          'directory',
          '/tmp/home/.config/app/node_modules',
          '.config/app/node_modules',
          'ignore',
        ),
      ]);

      const materialization = AbsentEntryMaterialization(
        desiredKeys: {'.config/app'},
      );
      final applyEntryMaterializationCalls =
          <
            ({
              ResolvedSyncConfigEntry entry,
              EntryMaterialization materialization,
              EffectiveSyncConfig config,
            })
          >[];

      await pullChanges(
        const PullRequest(dryRun: false),
        PullDependencies(
          applyEntryMaterialization: (entry, materialization, config) async {
            applyEntryMaterializationCalls.add((
              entry: entry,
              materialization: materialization,
              config: config,
            ));
          },
          buildEntryMaterialization: (entry, snapshot, config) =>
              materialization,
          buildPullCounts: zeroPullCounts,
          buildRepositorySnapshot: (syncDirectory, config) async => {},
          collectChangedLocalPaths: (entry, materialization, config) async =>
              [],
          countDeletedLocalNodes:
              (
                entry,
                desiredKeys,
                config,
                existingKeys,
                keyToLocalPath,
                deletedKeys,
              ) async => 0,
          loadSyncConfig: (syncDirectory, {profile}) async => LoadedSyncConfig(
            effectiveConfig: config,
            fullConfig: ResolvedSyncConfig(
              entries: config.entries,
              version: config.version,
            ),
          ),
          requireGitRepository: (syncDirectory) async {},
          resolveSyncPaths: () => const SyncPaths(
            configPath: '/tmp/dotweave/dotweave.jsonc',
            globalConfigPath: '/tmp/dotweave/global.json',
            homeDirectory: '/tmp/home',
            syncDirectory: '/tmp/dotweave',
          ),
        ),
      );

      expect(applyEntryMaterializationCalls, hasLength(1));
      expect(
        applyEntryMaterializationCalls.single.entry,
        same(config.entries[0]),
      );
      expect(
        applyEntryMaterializationCalls.single.materialization,
        same(materialization),
      );
      expect(applyEntryMaterializationCalls.single.config, same(config));
    });

    test('does not apply overlapping local paths concurrently', () async {
      final config = createTestConfig([
        createTestEntry(
          'directory',
          '/tmp/home/.config/zsh',
          '.config/zsh',
          'normal',
        ),
        createTestEntry(
          'file',
          '/tmp/home/.config/zsh/secrets.zsh',
          '.config/zsh/secrets.zsh',
          'secret',
          0x180, // 0o600
        ),
        createTestEntry(
          'file',
          '/tmp/home/.gitconfig',
          '.gitconfig',
          'normal',
          0x1A4, // 0o644
        ),
      ]);
      final plan = PullPlan(
        counts: const (
          decryptedFileCount: 1,
          directoryCount: 1,
          plainFileCount: 1,
          symlinkCount: 0,
        ),
        deletedLocalCount: 0,
        deletedLocalPaths: const [],
        desiredKeys: const {},
        existingKeys: const {},
        materializations: [
          const DirectoryEntryMaterialization(
            desiredKeys: {'.config/zsh/', '.config/zsh/.zshrc'},
            nodes: {},
          ),
          FileEntryMaterialization(
            desiredKeys: const {'.config/zsh/secrets.zsh'},
            node: FileSnapshotNode(
              contents: Uint8List(0),
              executable: false,
              secret: true,
            ),
          ),
          FileEntryMaterialization(
            desiredKeys: const {'.gitconfig'},
            node: FileSnapshotNode(
              contents: Uint8List(0),
              executable: false,
              secret: false,
            ),
          ),
        ],
        updatedLocalPaths: const [],
      );
      final activeLocalPaths = <String>[];
      var overlapped = false;
      var applyEntryMaterializationCallCount = 0;

      await applyPullPlan(
        config,
        plan,
        PullDependencies(
          applyEntryMaterialization: (entry, materialization, config) async {
            applyEntryMaterializationCallCount += 1;

            if (activeLocalPaths.any((activeLocalPath) {
              return doPathsOverlap(entry.localPath, activeLocalPath);
            })) {
              overlapped = true;
            }

            activeLocalPaths.add(entry.localPath);
            await Future<void>.delayed(const Duration(milliseconds: 10));
            activeLocalPaths.remove(entry.localPath);
          },
        ),
      );

      expect(overlapped, isFalse);
      expect(applyEntryMaterializationCallCount, 3);
    });
  });

  group('pull --with-git', () {
    PullDependencies gitDeps({
      required List<String> pulled,
      required bool hasRemote,
    }) {
      return PullDependencies(
        buildPullCounts: zeroPullCounts,
        buildRepositorySnapshot: (syncDirectory, config) async => {},
        hasGitRemote: (directory) async => hasRemote,
        pullFromRemote: (directory) async => pulled.add(directory),
        loadSyncConfig: (syncDirectory, {profile}) async => LoadedSyncConfig(
          effectiveConfig: createTestConfig(),
          fullConfig: const ResolvedSyncConfig(entries: [], version: 7),
        ),
        requireGitRepository: (syncDirectory) async {},
        resolveSyncPaths: () => const SyncPaths(
          configPath: '/tmp/dotweave/dotweave.jsonc',
          globalConfigPath: '/tmp/dotweave/global.json',
          homeDirectory: '/tmp/home',
          syncDirectory: '/tmp/dotweave',
        ),
      );
    }

    test('pulls from the remote before snapshotting when enabled', () async {
      final pulled = <String>[];

      await preparePull(
        const PullRequest(dryRun: false, withGit: true),
        gitDeps(pulled: pulled, hasRemote: true),
      );

      expect(pulled, ['/tmp/dotweave']);
    });

    test('does not touch the remote when the flag is off', () async {
      final pulled = <String>[];

      await preparePull(
        const PullRequest(dryRun: false),
        gitDeps(pulled: pulled, hasRemote: true),
      );

      expect(pulled, isEmpty);
    });

    test('skips the remote pull on a dry run', () async {
      final pulled = <String>[];

      await preparePull(
        const PullRequest(dryRun: true, withGit: true),
        gitDeps(pulled: pulled, hasRemote: true),
      );

      expect(pulled, isEmpty);
    });

    test('fails when no remote is configured', () async {
      await expectLater(
        preparePull(
          const PullRequest(dryRun: false, withGit: true),
          gitDeps(pulled: [], hasRemote: false),
        ),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.code,
            'code',
            'SYNC_PULL_NO_REMOTE',
          ),
        ),
      );
    });
  });
}
