import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/git.dart';

// Mirror of `services/status.ts`: computes both push and pull change previews
// without writing.

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }

  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) {
      return false;
    }
  }

  return true;
}

/// Mirror of the TS `StatusEntry` readonly object.
class StatusEntry {
  const StatusEntry({
    required this.kind,
    required this.localPath,
    required this.profiles,
    required this.mode,
    required this.repoPath,
  });

  final SyncConfigEntryKind kind;
  final String localPath;
  final List<String> profiles;
  final SyncMode mode;
  final String repoPath;

  @override
  bool operator ==(Object other) {
    return other is StatusEntry &&
        other.kind == kind &&
        other.localPath == localPath &&
        _listEquals(other.profiles, profiles) &&
        other.mode == mode &&
        other.repoPath == repoPath;
  }

  @override
  int get hashCode =>
      Object.hash(kind, localPath, Object.hashAll(profiles), mode, repoPath);

  @override
  String toString() {
    return 'StatusEntry(kind: $kind, localPath: $localPath, '
        'profiles: $profiles, mode: $mode, repoPath: $repoPath)';
  }
}

/// Mirror of the TS `PushChanges` readonly object.
class PushChanges {
  const PushChanges({
    required this.added,
    required this.modified,
    required this.deleted,
  });

  final List<String> added;
  final List<String> modified;
  final List<String> deleted;

  @override
  bool operator ==(Object other) {
    return other is PushChanges &&
        _listEquals(other.added, added) &&
        _listEquals(other.modified, modified) &&
        _listEquals(other.deleted, deleted);
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(added),
    Object.hashAll(modified),
    Object.hashAll(deleted),
  );

  @override
  String toString() {
    return 'PushChanges(added: $added, modified: $modified, '
        'deleted: $deleted)';
  }
}

/// Mirror of the TS `PullChanges` readonly object.
class PullChanges {
  const PullChanges({required this.updated, required this.deleted});

  final List<String> updated;
  final List<String> deleted;

  @override
  bool operator ==(Object other) {
    return other is PullChanges &&
        _listEquals(other.updated, updated) &&
        _listEquals(other.deleted, deleted);
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(updated), Object.hashAll(deleted));

  @override
  String toString() {
    return 'PullChanges(updated: $updated, deleted: $deleted)';
  }
}

/// Mirror of the TS inline `pull` section of `StatusResult`
/// (`ReturnType<typeof buildPullResultFromPlan> & { changes, preview }`). The
/// TS spread copies the [PullResult] fields alongside `changes`/`preview`, so
/// the Dart class carries them directly.
class StatusPullSummary {
  StatusPullSummary({
    required PullResult result,
    required this.changes,
    required this.preview,
  }) : decryptedFileCount = result.decryptedFileCount,
       deletedLocalCount = result.deletedLocalCount,
       directoryCount = result.directoryCount,
       dryRun = result.dryRun,
       plainFileCount = result.plainFileCount,
       symlinkCount = result.symlinkCount;

  final int decryptedFileCount;
  final int deletedLocalCount;
  final int directoryCount;
  final bool dryRun;
  final int plainFileCount;
  final int symlinkCount;
  final PullChanges changes;
  final List<String> preview;

  @override
  bool operator ==(Object other) {
    return other is StatusPullSummary &&
        other.decryptedFileCount == decryptedFileCount &&
        other.deletedLocalCount == deletedLocalCount &&
        other.directoryCount == directoryCount &&
        other.dryRun == dryRun &&
        other.plainFileCount == plainFileCount &&
        other.symlinkCount == symlinkCount &&
        other.changes == changes &&
        _listEquals(other.preview, preview);
  }

  @override
  int get hashCode => Object.hash(
    decryptedFileCount,
    deletedLocalCount,
    directoryCount,
    dryRun,
    plainFileCount,
    symlinkCount,
    changes,
    Object.hashAll(preview),
  );
}

/// Mirror of the TS inline `push` section of `StatusResult`
/// (`ReturnType<typeof buildPushResultFromPlan> & { changes, preview }`). The
/// TS spread copies the [PushResult] fields alongside `changes`/`preview`, so
/// the Dart class carries them directly.
class StatusPushSummary {
  StatusPushSummary({
    required PushResult result,
    required this.changes,
    required this.preview,
  }) : deletedArtifactCount = result.deletedArtifactCount,
       directoryCount = result.directoryCount,
       dryRun = result.dryRun,
       encryptedFileCount = result.encryptedFileCount,
       plainFileCount = result.plainFileCount,
       symlinkCount = result.symlinkCount;

  final int deletedArtifactCount;
  final int directoryCount;
  final bool dryRun;
  final int encryptedFileCount;
  final int plainFileCount;
  final int symlinkCount;
  final PushChanges changes;
  final List<String> preview;

  @override
  bool operator ==(Object other) {
    return other is StatusPushSummary &&
        other.deletedArtifactCount == deletedArtifactCount &&
        other.directoryCount == directoryCount &&
        other.dryRun == dryRun &&
        other.encryptedFileCount == encryptedFileCount &&
        other.plainFileCount == plainFileCount &&
        other.symlinkCount == symlinkCount &&
        other.changes == changes &&
        _listEquals(other.preview, preview);
  }

  @override
  int get hashCode => Object.hash(
    deletedArtifactCount,
    directoryCount,
    dryRun,
    encryptedFileCount,
    plainFileCount,
    symlinkCount,
    changes,
    Object.hashAll(preview),
  );
}

/// Mirror of the TS `StatusResult` readonly object.
class StatusResult {
  const StatusResult({
    this.activeProfile,
    required this.entries,
    required this.entryCount,
    required this.pull,
    required this.push,
    required this.recipientCount,
  });

  final String? activeProfile;
  final List<StatusEntry> entries;
  final int entryCount;
  final StatusPullSummary pull;
  final StatusPushSummary push;
  final int recipientCount;

  @override
  bool operator ==(Object other) {
    return other is StatusResult &&
        other.activeProfile == activeProfile &&
        _listEquals(other.entries, entries) &&
        other.entryCount == entryCount &&
        other.pull == pull &&
        other.push == push &&
        other.recipientCount == recipientCount;
  }

  @override
  int get hashCode => Object.hash(
    activeProfile,
    Object.hashAll(entries),
    entryCount,
    pull,
    push,
    recipientCount,
  );
}

/// Optional overrides for the status orchestration, standing in for the vitest
/// module mocks used by `status.test.ts`.
class StatusDependencies {
  const StatusDependencies({
    this.buildArtifactKey,
    this.buildPullPlan,
    this.buildPullPlanPreview,
    this.buildPullResultFromPlan,
    this.buildPushPlan,
    this.buildPushPlanPreview,
    this.buildPushResultFromPlan,
    this.isRepoArtifactCurrent,
    this.loadSyncConfig,
    this.requireGitRepository,
    this.resolveSyncPaths,
  });

  final String Function(RepoArtifact artifact)? buildArtifactKey;
  final Future<PullPlan> Function(
    EffectiveSyncConfig config,
    String syncDirectory,
  )?
  buildPullPlan;
  final List<String> Function(PullPlan plan)? buildPullPlanPreview;
  final PullResult Function(PullPlan plan, bool dryRun)?
  buildPullResultFromPlan;
  final Future<PushPlan> Function(
    EffectiveSyncConfig config,
    String syncDirectory,
    ArtifactOwnershipConfig? ownershipConfig,
  )?
  buildPushPlan;
  final List<String> Function(PushPlan plan)? buildPushPlanPreview;
  final PushResult Function(PushPlan plan, bool dryRun)?
  buildPushResultFromPlan;
  final Future<bool> Function(
    String syncDirectory,
    RepoArtifact artifact,
    ({String identityFile})? ageConfig,
  )?
  isRepoArtifactCurrent;
  final Future<LoadedSyncConfig> Function(
    String syncDirectory, {
    String? profile,
  })?
  loadSyncConfig;
  final Future<void> Function(String syncDirectory)? requireGitRepository;
  final SyncPaths Function()? resolveSyncPaths;
}

Future<PushChanges> _buildPushChanges(
  PushPlan plan,
  String syncDirectory,
  String identityFile,
  String Function(RepoArtifact artifact) buildArtifactKeyFn,
  Future<bool> Function(
    String syncDirectory,
    RepoArtifact artifact,
    ({String identityFile})? ageConfig,
  )
  isRepoArtifactCurrentFn,
) async {
  final added = <String>[];
  final modified = <String>[];

  for (final artifact in plan.artifacts) {
    final artifactKey = buildArtifactKeyFn(artifact);

    if (await isRepoArtifactCurrentFn(syncDirectory, artifact, (
      identityFile: identityFile,
    ))) {
      continue;
    }

    if (plan.existingArtifactKeys.contains(artifactKey)) {
      modified.add(artifact.repoPath);
    } else {
      added.add(artifact.repoPath);
    }
  }

  final deletedKeys =
      plan.deletedArtifactKeys ??
      {
        for (final key in plan.existingArtifactKeys)
          if (!plan.desiredArtifactKeys.contains(key)) key,
      };
  final deleted = deletedKeys.toList()..sort(compareLocaleLike);

  return PushChanges(
    added: added..sort(compareLocaleLike),
    modified: modified..sort(compareLocaleLike),
    deleted: deleted,
  );
}

PullChanges _buildPullChanges(PullPlan plan) {
  return PullChanges(
    updated: [...plan.updatedLocalPaths],
    deleted: [...plan.deletedLocalPaths],
  );
}

Future<StatusResult> getStatus({
  String? profile,
  StatusDependencies dependencies = const StatusDependencies(),
}) async {
  final effectiveResolveSyncPaths =
      dependencies.resolveSyncPaths ?? resolveSyncPaths;
  final effectiveRequireGitRepository =
      dependencies.requireGitRepository ?? requireGitRepository;
  final effectiveLoadSyncConfig = dependencies.loadSyncConfig ?? loadSyncConfig;
  final Future<PushPlan> Function(
    EffectiveSyncConfig config,
    String syncDirectory,
    ArtifactOwnershipConfig? ownershipConfig,
  )
  effectiveBuildPushPlan = dependencies.buildPushPlan ?? buildPushPlan;
  final Future<PullPlan> Function(
    EffectiveSyncConfig config,
    String syncDirectory,
  )
  effectiveBuildPullPlan = dependencies.buildPullPlan ?? buildPullPlan;
  final effectiveBuildArtifactKey =
      dependencies.buildArtifactKey ?? buildArtifactKey;
  final Future<bool> Function(
    String syncDirectory,
    RepoArtifact artifact,
    ({String identityFile})? ageConfig,
  )
  effectiveIsRepoArtifactCurrent =
      dependencies.isRepoArtifactCurrent ?? isRepoArtifactCurrent;
  final effectiveBuildPushResultFromPlan =
      dependencies.buildPushResultFromPlan ?? buildPushResultFromPlan;
  final effectiveBuildPullResultFromPlan =
      dependencies.buildPullResultFromPlan ?? buildPullResultFromPlan;
  final effectiveBuildPushPlanPreview =
      dependencies.buildPushPlanPreview ?? buildPushPlanPreview;
  final effectiveBuildPullPlanPreview =
      dependencies.buildPullPlanPreview ?? buildPullPlanPreview;

  final syncDirectory = effectiveResolveSyncPaths().syncDirectory;

  await effectiveRequireGitRepository(syncDirectory);

  final loaded = await effectiveLoadSyncConfig(syncDirectory, profile: profile);
  final effectiveConfig = loaded.effectiveConfig;
  final fullConfig = loaded.fullConfig;
  final pushPlan = await effectiveBuildPushPlan(
    effectiveConfig,
    syncDirectory,
    (entries: fullConfig.entries, profiles: fullConfig.profiles),
  );
  final pullPlan = await effectiveBuildPullPlan(effectiveConfig, syncDirectory);
  final pushChanges = await _buildPushChanges(
    pushPlan,
    syncDirectory,
    effectiveConfig.age.identityFile,
    effectiveBuildArtifactKey,
    effectiveIsRepoArtifactCurrent,
  );

  return StatusResult(
    activeProfile: effectiveConfig.activeProfile,
    entries: [
      for (final entry in fullConfig.entries)
        StatusEntry(
          kind: entry.kind,
          localPath: entry.localPath,
          profiles: entry.profiles,
          mode: entry.mode,
          repoPath: entry.repoPath,
        ),
    ],
    entryCount: fullConfig.entries.length,
    pull: StatusPullSummary(
      result: effectiveBuildPullResultFromPlan(pullPlan, true),
      changes: _buildPullChanges(pullPlan),
      preview: effectiveBuildPullPlanPreview(pullPlan),
    ),
    push: StatusPushSummary(
      result: effectiveBuildPushResultFromPlan(pushPlan, true),
      changes: pushChanges,
      preview: effectiveBuildPushPlanPreview(pushPlan),
    ),
    recipientCount: effectiveConfig.age.recipients.length,
  );
}
