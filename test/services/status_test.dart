import 'dart:typed_data';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/status.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:test/test.dart';

void main() {
  PushPlan createPushPlan({
    List<RepoArtifact> artifacts = const [],
    Set<String> existingArtifactKeys = const {},
    Set<String> desiredArtifactKeys = const {},
  }) {
    return PushPlan(
      artifacts: artifacts,
      counts: (
        directoryCount: 0,
        encryptedFileCount: 0,
        plainFileCount: 0,
        symlinkCount: 0,
      ),
      deletedArtifactCount: 0,
      desiredArtifactKeys: desiredArtifactKeys,
      existingArtifactKeys: existingArtifactKeys,
      snapshot: const {},
    );
  }

  PullPlan createPullPlan({
    List<String> updatedLocalPaths = const [],
    List<String> deletedLocalPaths = const [],
  }) {
    return PullPlan(
      counts: const (
        decryptedFileCount: 0,
        directoryCount: 0,
        plainFileCount: 0,
        symlinkCount: 0,
      ),
      deletedLocalCount: 0,
      deletedLocalPaths: deletedLocalPaths,
      desiredKeys: const {},
      existingKeys: const {},
      materializations: const [],
      updatedLocalPaths: updatedLocalPaths,
    );
  }

  FileRepoArtifact createFileArtifact(String profile, String repoPath) {
    return FileRepoArtifact(
      category: 'plain',
      contents: Uint8List(0),
      executable: false,
      profile: profile,
      repoPath: repoPath,
    );
  }

  late List<String> requireGitRepositoryCalls;

  setUp(() {
    requireGitRepositoryCalls = [];
  });

  StatusDependencies createDependencies({
    required LoadedSyncConfig config,
    required PushPlan pushPlan,
    required PullPlan pullPlan,
    bool isRepoArtifactCurrent = false,
  }) {
    return StatusDependencies(
      buildArtifactKey: (artifact) =>
          '${artifact.profile}/${artifact.repoPath}',
      buildPullPlan: (config, syncDirectory) async => pullPlan,
      buildPullPlanPreview: (plan) => ['pull-preview'],
      buildPullResultFromPlan: (plan, dryRun) => const PullResult(
        decryptedFileCount: 0,
        deletedLocalCount: 0,
        directoryCount: 0,
        dryRun: true,
        plainFileCount: 0,
        symlinkCount: 0,
      ),
      buildPushPlan: (config, syncDirectory, ownershipConfig) async => pushPlan,
      buildPushPlanPreview: (plan) => ['push-preview'],
      buildPushResultFromPlan: (plan, dryRun) => const PushResult(
        deletedArtifactCount: 0,
        directoryCount: 0,
        dryRun: true,
        encryptedFileCount: 0,
        plainFileCount: 0,
        symlinkCount: 0,
      ),
      isRepoArtifactCurrent: (syncDirectory, artifact, ageConfig) async =>
          isRepoArtifactCurrent,
      loadSyncConfig: (syncDirectory, {profile}) async => config,
      requireGitRepository: (syncDirectory) async {
        requireGitRepositoryCalls.add(syncDirectory);
      },
      resolveSyncPaths: () => const SyncPaths(
        configPath: '/tmp/dotweave/manifest.jsonc',
        globalConfigPath: '/tmp/dotweave/global.json',
        homeDirectory: '/tmp/home',
        syncDirectory: '/tmp/dotweave',
      ),
    );
  }

  group('status service', () {
    test('successfully returns status result', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          activeProfile: 'default',
          age: RuntimeAgeConfig(identityFile: 'key.txt', recipients: ['recip']),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [
            ResolvedSyncConfigEntry(
              kind: 'file',
              localPath: '/home/user/.bashrc',
              profiles: ['default'],
              mode: 'normal',
              repoPath: '.bashrc',
              profilesExplicit: true,
              modeExplicit: true,
              permissionExplicit: false,
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.bashrc',
              ),
            ),
          ],
        ),
      );

      final result = await getStatus(
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(
            artifacts: [createFileArtifact('default', '.bashrc')],
            existingArtifactKeys: {},
            desiredArtifactKeys: {'default/.bashrc'},
          ),
          pullPlan: createPullPlan(updatedLocalPaths: ['/home/user/.bashrc']),
        ),
      );

      expect(result.activeProfile, 'default');
      expect(result.entryCount, 1);
      expect(result.push.changes.added, contains('.bashrc'));
      expect(result.pull.changes.updated, contains('/home/user/.bashrc'));
      expect(requireGitRepositoryCalls, ['/tmp/dotweave']);
    });

    test('handles empty active profile', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          age: RuntimeAgeConfig(identityFile: 'key.txt', recipients: []),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [],
        ),
      );

      final result = await getStatus(
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(),
          pullPlan: createPullPlan(),
        ),
      );

      expect(result.activeProfile, isNull);
      expect(result.entryCount, 0);
    });

    test('reports push changes with modified artifacts when artifacts are not '
        'current', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          activeProfile: 'default',
          age: RuntimeAgeConfig(identityFile: 'key.txt', recipients: ['recip']),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [
            ResolvedSyncConfigEntry(
              kind: 'file',
              localPath: '/home/user/.vimrc',
              profiles: ['default'],
              mode: 'normal',
              repoPath: '.vimrc',
              profilesExplicit: true,
              modeExplicit: true,
              permissionExplicit: false,
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.vimrc',
              ),
            ),
          ],
        ),
      );

      final result = await getStatus(
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(
            artifacts: [createFileArtifact('default', '.vimrc')],
            existingArtifactKeys: {'default/.vimrc'},
            desiredArtifactKeys: {'default/.vimrc'},
          ),
          pullPlan: createPullPlan(),
        ),
      );

      expect(result.push.changes.modified, contains('.vimrc'));
      expect(result.push.changes.added, isNot(contains('.vimrc')));
    });

    test(
      'reports push changes with deleted artifacts for stale keys',
      () async {
        final mockConfig = LoadedSyncConfig(
          effectiveConfig: EffectiveSyncConfig(
            version: AppConstants.sync.configVersion,
            activeProfile: 'default',
            age: RuntimeAgeConfig(
              identityFile: 'key.txt',
              recipients: ['recip'],
            ),
            entries: [],
          ),
          fullConfig: ResolvedSyncConfig(
            version: AppConstants.sync.configVersion,
            entries: [],
          ),
        );

        final result = await getStatus(
          dependencies: createDependencies(
            config: mockConfig,
            pushPlan: createPushPlan(
              existingArtifactKeys: {'default/.oldconfig', 'default/.obsolete'},
              desiredArtifactKeys: {},
            ),
            pullPlan: createPullPlan(),
          ),
        );

        expect(result.push.changes.deleted, contains('default/.oldconfig'));
        expect(result.push.changes.deleted, contains('default/.obsolete'));
      },
    );

    test('preserves profile-qualified artifact keys for non-default profile '
        'pruning', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          activeProfile: 'work',
          age: RuntimeAgeConfig(identityFile: 'key.txt', recipients: ['recip']),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [],
        ),
      );

      final result = await getStatus(
        profile: 'work',
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(
            existingArtifactKeys: {'work/.staleconfig'},
            desiredArtifactKeys: {},
          ),
          pullPlan: createPullPlan(),
        ),
      );

      expect(result.push.changes.deleted, ['work/.staleconfig']);
    });

    test('keeps deleted default and work artifacts unambiguous when repo paths '
        'duplicate', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          activeProfile: 'default',
          age: RuntimeAgeConfig(identityFile: 'key.txt', recipients: ['recip']),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [],
        ),
      );

      final result = await getStatus(
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(
            existingArtifactKeys: {'default/.shared', 'work/.shared'},
            desiredArtifactKeys: {},
          ),
          pullPlan: createPullPlan(),
        ),
      );

      expect(result.push.changes.deleted, ['default/.shared', 'work/.shared']);
    });

    test('reports pull changes including deleted local paths', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          activeProfile: 'default',
          age: RuntimeAgeConfig(identityFile: 'key.txt', recipients: ['recip']),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [],
        ),
      );

      final result = await getStatus(
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(),
          pullPlan: createPullPlan(
            deletedLocalPaths: [
              '/home/user/.deprecated',
              '/home/user/.removed',
            ],
          ),
        ),
      );

      expect(result.pull.changes.deleted, contains('/home/user/.deprecated'));
      expect(result.pull.changes.deleted, contains('/home/user/.removed'));
    });

    test('includes recipientCount from effective config age', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          activeProfile: 'default',
          age: RuntimeAgeConfig(
            identityFile: 'key.txt',
            recipients: ['recip1', 'recip2'],
          ),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [],
        ),
      );

      final result = await getStatus(
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(),
          pullPlan: createPullPlan(),
        ),
      );

      expect(result.recipientCount, 2);
    });

    test('returns full config entry metadata (kind, mode, profiles)', () async {
      final mockConfig = LoadedSyncConfig(
        effectiveConfig: EffectiveSyncConfig(
          version: AppConstants.sync.configVersion,
          activeProfile: 'default',
          age: RuntimeAgeConfig(identityFile: 'key.txt', recipients: ['recip']),
          entries: [],
        ),
        fullConfig: ResolvedSyncConfig(
          version: AppConstants.sync.configVersion,
          entries: [
            ResolvedSyncConfigEntry(
              kind: 'file',
              localPath: '/home/user/.bashrc',
              profiles: ['default', 'linux'],
              mode: 'normal',
              repoPath: '.bashrc',
              profilesExplicit: true,
              modeExplicit: true,
              permissionExplicit: false,
              configuredMode: PlatformSyncMode(
                defaultValue: 'normal',
                linux: 'normal',
              ),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.bashrc',
                linux: '~/.bashrc',
              ),
            ),
          ],
        ),
      );

      final result = await getStatus(
        dependencies: createDependencies(
          config: mockConfig,
          pushPlan: createPushPlan(),
          pullPlan: createPullPlan(),
        ),
      );

      expect(
        result.entries[0],
        const StatusEntry(
          kind: 'file',
          localPath: '/home/user/.bashrc',
          profiles: ['default', 'linux'],
          mode: 'normal',
          repoPath: '.bashrc',
        ),
      );
    });
  });
}
