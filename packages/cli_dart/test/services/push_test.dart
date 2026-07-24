import 'dart:typed_data';

import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:test/test.dart';

void main() {
  group('push helpers', () {
    test(
      'builds a stable preview from created and deleted repository artifacts',
      () {
        expect(
          buildPushPlanPreview(
            PushPlan(
              artifacts: [
                const DirectoryRepoArtifact(
                  profile: 'default',
                  repoPath: 'alpha',
                ),
                const SymlinkRepoArtifact(
                  linkTarget: 'value.txt',
                  profile: 'default',
                  repoPath: 'beta',
                ),
                FileRepoArtifact(
                  category: 'secret',
                  contents: Uint8List(0),
                  executable: false,
                  profile: 'default',
                  repoPath: 'gamma',
                ),
                FileRepoArtifact(
                  category: 'plain',
                  contents: Uint8List(0),
                  executable: false,
                  profile: 'default',
                  repoPath: 'delta',
                ),
                FileRepoArtifact(
                  category: 'plain',
                  contents: Uint8List(0),
                  executable: false,
                  profile: 'default',
                  repoPath: 'zeta',
                ),
              ],
              counts: (
                directoryCount: 1,
                encryptedFileCount: 1,
                plainFileCount: 2,
                symlinkCount: 1,
              ),
              deletedArtifactCount: 2,
              desiredArtifactKeys: {
                'alpha',
                'beta',
                'gamma',
                'delta',
                'epsilon',
              },
              existingArtifactKeys: {'alpha', 'stale-a', 'stale-b'},
              snapshot: {
                'zeta': FileSnapshotNode(
                  contents: Uint8List(0),
                  executable: false,
                  secret: false,
                ),
                'alpha': const DirectorySnapshotNode(),
                'beta': const SymlinkSnapshotNode(linkTarget: 'value.txt'),
                'gamma': FileSnapshotNode(
                  contents: Uint8List(0),
                  executable: false,
                  secret: true,
                ),
                'delta': FileSnapshotNode(
                  contents: Uint8List(0),
                  executable: false,
                  secret: false,
                ),
              },
            ),
          ),
          ['alpha', 'beta', 'delta', 'gamma', 'stale-a', 'stale-b'],
        );
      },
    );

    test('builds push results from a completed plan', () {
      expect(
        buildPushResultFromPlan(
          PushPlan(
            artifacts: const [],
            counts: (
              directoryCount: 2,
              encryptedFileCount: 3,
              plainFileCount: 4,
              symlinkCount: 1,
            ),
            deletedArtifactCount: 5,
            desiredArtifactKeys: <String>{},
            existingArtifactKeys: <String>{},
            snapshot: const {},
          ),
          false,
        ),
        const PushResult(
          deletedArtifactCount: 5,
          directoryCount: 2,
          dryRun: false,
          encryptedFileCount: 3,
          plainFileCount: 4,
          symlinkCount: 1,
        ),
      );
    });

    test('preview limits to 6 items maximum', () {
      final snapshot = <String, SnapshotNode>{
        'a1': const DirectorySnapshotNode(),
        'a2': const DirectorySnapshotNode(),
        'a3': const DirectorySnapshotNode(),
        'a4': const DirectorySnapshotNode(),
        'a5': const DirectorySnapshotNode(),
      };
      final existingArtifactKeys = {
        'a1',
        'stale-1',
        'stale-2',
        'stale-3',
        'stale-4',
        'stale-5',
      };
      final desiredArtifactKeys = {'a1', 'a2', 'a3', 'a4', 'a5'};
      final result = buildPushPlanPreview(
        PushPlan(
          artifacts: const [
            DirectoryRepoArtifact(profile: 'default', repoPath: 'a1'),
            DirectoryRepoArtifact(profile: 'default', repoPath: 'a2'),
            DirectoryRepoArtifact(profile: 'default', repoPath: 'a3'),
            DirectoryRepoArtifact(profile: 'default', repoPath: 'a4'),
            DirectoryRepoArtifact(profile: 'default', repoPath: 'a5'),
          ],
          counts: (
            directoryCount: 5,
            encryptedFileCount: 0,
            plainFileCount: 0,
            symlinkCount: 0,
          ),
          deletedArtifactCount: 5,
          desiredArtifactKeys: desiredArtifactKeys,
          existingArtifactKeys: existingArtifactKeys,
          snapshot: snapshot,
        ),
      );
      expect(result.length, lessThanOrEqualTo(6));
      expect(result, ['a1', 'a2', 'a3', 'a4', 'stale-1', 'stale-2']);
    });

    test('preview returns empty array when plan has no changes', () {
      expect(
        buildPushPlanPreview(
          PushPlan(
            artifacts: const [],
            counts: (
              directoryCount: 0,
              encryptedFileCount: 0,
              plainFileCount: 0,
              symlinkCount: 0,
            ),
            deletedArtifactCount: 0,
            desiredArtifactKeys: <String>{},
            existingArtifactKeys: <String>{},
            snapshot: const {},
          ),
        ),
        <String>[],
      );
    });

    test('buildPushResultFromPlan with dryRun=true sets dryRun field', () {
      expect(
        buildPushResultFromPlan(
          PushPlan(
            artifacts: const [],
            counts: (
              directoryCount: 0,
              encryptedFileCount: 0,
              plainFileCount: 0,
              symlinkCount: 0,
            ),
            deletedArtifactCount: 0,
            desiredArtifactKeys: <String>{},
            existingArtifactKeys: <String>{},
            snapshot: const {},
          ),
          true,
        ),
        const PushResult(
          deletedArtifactCount: 0,
          directoryCount: 0,
          dryRun: true,
          encryptedFileCount: 0,
          plainFileCount: 0,
          symlinkCount: 0,
        ),
      );
    });

    test('buildPushPlanPreview sorts keys alphabetically', () {
      expect(
        buildPushPlanPreview(
          PushPlan(
            artifacts: const [
              DirectoryRepoArtifact(profile: 'default', repoPath: 'zeta'),
              DirectoryRepoArtifact(profile: 'default', repoPath: 'alpha'),
              DirectoryRepoArtifact(profile: 'default', repoPath: 'mid'),
            ],
            counts: (
              directoryCount: 3,
              encryptedFileCount: 0,
              plainFileCount: 0,
              symlinkCount: 0,
            ),
            deletedArtifactCount: 0,
            desiredArtifactKeys: {'zeta', 'alpha', 'mid'},
            existingArtifactKeys: {'zeta', 'alpha', 'mid'},
            snapshot: const {
              'zeta': DirectorySnapshotNode(),
              'alpha': DirectorySnapshotNode(),
              'mid': DirectorySnapshotNode(),
            },
          ),
        ),
        ['alpha', 'mid', 'zeta'],
      );
    });

    test('preview shows created keys first then deleted keys', () {
      final result = buildPushPlanPreview(
        PushPlan(
          artifacts: const [
            DirectoryRepoArtifact(profile: 'default', repoPath: 'bravo'),
            DirectoryRepoArtifact(profile: 'default', repoPath: 'charlie'),
          ],
          counts: (
            directoryCount: 2,
            encryptedFileCount: 0,
            plainFileCount: 0,
            symlinkCount: 0,
          ),
          deletedArtifactCount: 2,
          desiredArtifactKeys: {'bravo', 'charlie'},
          existingArtifactKeys: {'bravo', 'charlie', 'stale-x', 'stale-z'},
          snapshot: const {
            'bravo': DirectorySnapshotNode(),
            'charlie': DirectorySnapshotNode(),
          },
        ),
      );
      final lastCreatedIndex = [
        result.indexOf('bravo'),
        result.indexOf('charlie'),
      ].reduce((left, right) => left > right ? left : right);
      final firstDeletedIndex = [
        result.indexOf('stale-x'),
        result.indexOf('stale-z'),
      ].reduce((left, right) => left < right ? left : right);
      expect(lastCreatedIndex, lessThan(firstDeletedIndex));
    });
  });
}
