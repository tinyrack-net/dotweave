import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/pull_apply.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/sync_fixture.dart';

// Port of `sync.scenarios.test.ts`. The vitest module mocks map onto the
// [PullDependencies] injection seam for the pull plan; the push plan has no
// snapshot seam in Dart, so the mocked `buildLocalSnapshot` return value is
// reproduced with a real on-disk workspace instead.

/// Stand-in for the vitest `buildPullCounts: vi.fn(() => ({}))` mock; Dart's
/// [PullCounts] record cannot be empty, so zeros are the closest equivalent.
PullCounts _emptyPullCounts(List<EntryMaterialization?> materializations) {
  return (
    decryptedFileCount: 0,
    directoryCount: 0,
    plainFileCount: 0,
    symlinkCount: 0,
  );
}

void main() {
  tearDown(cleanUpSyncFixture);

  group('sync scenarios (unit)', () {
    test('handles multi-profile configuration in pull plan', () async {
      final config = EffectiveSyncConfig(
        version: AppConstants.sync.configVersion,
        activeProfile: 'work',
        entries: const [
          ResolvedSyncConfigEntry(
            kind: 'file',
            localPath: '/home/user/.ssh/config',
            repoPath: '.ssh/config',
            profiles: ['work', 'personal'],
            mode: 'normal',
            profilesExplicit: true,
            modeExplicit: true,
            permissionExplicit: false,
            configuredMode: PlatformSyncMode(defaultValue: 'normal'),
            configuredLocalPath: PlatformStringValue(
              defaultValue: '~/.ssh/config',
            ),
          ),
        ],
        age: const RuntimeAgeConfig(
          identityFile: 'id.txt',
          recipients: ['key1'],
        ),
      );

      // The TS mocked `buildEntryMaterialization` returns a bare
      // `{ type: "file", desiredKeys }` object; Dart's
      // [FileEntryMaterialization] requires a node, so the mocked repository
      // snapshot node is reused (it is never applied by `buildPullPlan`).
      final repositoryNode = FileSnapshotNode(
        contents: Uint8List.fromList(utf8.encode('work-ssh')),
        executable: false,
        secret: false,
      );
      var buildRepositorySnapshotCallCount = 0;

      final plan = await buildPullPlan(
        config,
        '/tmp/sync',
        PullDependencies(
          buildRepositorySnapshot: (syncDirectory, config) async {
            buildRepositorySnapshotCallCount += 1;

            return {'.ssh/config': repositoryNode};
          },
          buildEntryMaterialization: (entry, snapshot, config) {
            return FileEntryMaterialization(
              desiredKeys: const {'.ssh/config'},
              node: repositoryNode,
            );
          },
          buildPullCounts: _emptyPullCounts,
          collectChangedLocalPaths: (entry, materialization, config) async {
            return ['/home/user/.ssh/config'];
          },
          // The TS suite leaves `countDeletedLocalNodes` as a bare `vi.fn()`
          // (resolving `undefined`); Dart requires an `int`, so return 0.
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

      expect(plan.updatedLocalPaths, contains('/home/user/.ssh/config'));
      expect(buildRepositorySnapshotCallCount, greaterThanOrEqualTo(1));
    });

    test('handles directory with ignored sub-entry in push plan', () async {
      // The TS test mocks `buildLocalSnapshot` to return only `app` and
      // `app/main.js`; the Dart push plan always takes the real snapshot, so
      // the same shape is created on disk (the ignored `app/node_modules`
      // sub-entry stays absent, matching the mocked snapshot).
      final workspace = await createWorkspace('dotweave-scenarios-');
      final appDirectory = p.join(workspace, 'home', 'user', 'app');

      await Directory(appDirectory).create(recursive: true);
      await File(p.join(appDirectory, 'main.js')).writeAsString('js');

      final config = EffectiveSyncConfig(
        version: AppConstants.sync.configVersion,
        activeProfile: 'default',
        entries: [
          ResolvedSyncConfigEntry(
            kind: 'directory',
            localPath: appDirectory,
            repoPath: 'app',
            profiles: const [],
            mode: 'normal',
            profilesExplicit: false,
            modeExplicit: true,
            permissionExplicit: false,
            configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
            configuredLocalPath: const PlatformStringValue(
              defaultValue: '~/app',
            ),
          ),
          ResolvedSyncConfigEntry(
            kind: 'directory',
            localPath: p.join(appDirectory, 'node_modules'),
            repoPath: 'app/node_modules',
            profiles: const [],
            mode: 'ignore',
            profilesExplicit: false,
            modeExplicit: true,
            permissionExplicit: false,
            configuredMode: const PlatformSyncMode(defaultValue: 'ignore'),
            configuredLocalPath: const PlatformStringValue(
              defaultValue: '~/app/node_modules',
            ),
          ),
        ],
        age: const RuntimeAgeConfig(
          identityFile: 'id.txt',
          recipients: ['key1'],
        ),
      );

      // In actual implementation, buildLocalSnapshot filters out ignored
      // entries.
      final plan = await buildPushPlan(config, p.join(workspace, 'sync'));

      final artifactRepoPaths = [
        for (final artifact in plan.artifacts) artifact.repoPath,
      ];
      expect(artifactRepoPaths, contains('app'));
      expect(artifactRepoPaths, contains('app/main.js'));
      expect(artifactRepoPaths, isNot(contains('app/node_modules')));
    });
  });
}
