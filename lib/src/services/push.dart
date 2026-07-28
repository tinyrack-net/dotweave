import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/repo_artifact_path.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/repo_format.dart';
import 'package:dotweave/src/services/repository_ignore.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/concurrency.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/git.dart';
import 'package:dotweave/src/util/perf_trace.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/push.ts`: local snapshot -> repository artifact planning
// and the push orchestration that writes the plan to the sync repository.

/// Mirror of the TS `PushRequest` readonly object.
class PushRequest {
  const PushRequest({required this.dryRun, this.profile});

  final bool dryRun;
  final String? profile;
}

/// Mirror of the TS `PushResult` readonly object.
class PushResult {
  const PushResult({
    required this.deletedArtifactCount,
    required this.directoryCount,
    required this.dryRun,
    required this.encryptedFileCount,
    required this.plainFileCount,
    required this.symlinkCount,
  });

  final int deletedArtifactCount;
  final int directoryCount;
  final bool dryRun;
  final int encryptedFileCount;
  final int plainFileCount;
  final int symlinkCount;

  @override
  bool operator ==(Object other) {
    return other is PushResult &&
        other.deletedArtifactCount == deletedArtifactCount &&
        other.directoryCount == directoryCount &&
        other.dryRun == dryRun &&
        other.encryptedFileCount == encryptedFileCount &&
        other.plainFileCount == plainFileCount &&
        other.symlinkCount == symlinkCount;
  }

  @override
  int get hashCode => Object.hash(
    deletedArtifactCount,
    directoryCount,
    dryRun,
    encryptedFileCount,
    plainFileCount,
    symlinkCount,
  );

  @override
  String toString() {
    return 'PushResult(deletedArtifactCount: $deletedArtifactCount, '
        'directoryCount: $directoryCount, dryRun: $dryRun, '
        'encryptedFileCount: $encryptedFileCount, '
        'plainFileCount: $plainFileCount, symlinkCount: $symlinkCount)';
  }
}

/// Mirror of the TS inline `ReturnType<typeof buildPushCounts>` shape carried
/// by [PushPlan.counts].
typedef PushCounts = ({
  int directoryCount,
  int encryptedFileCount,
  int plainFileCount,
  int symlinkCount,
});

/// Mirror of the TS `PushPlan` readonly object.
class PushPlan {
  const PushPlan({
    required this.artifacts,
    required this.counts,
    this.deletedArtifactKeys,
    required this.deletedArtifactCount,
    required this.desiredArtifactKeys,
    required this.existingArtifactKeys,
    this.staleReplacementDirectoryRoots,
    required this.snapshot,
  });

  final List<RepoArtifact> artifacts;
  final PushCounts counts;
  final Set<String>? deletedArtifactKeys;
  final int deletedArtifactCount;
  final Set<String> desiredArtifactKeys;
  final Set<String> existingArtifactKeys;
  final List<String>? staleReplacementDirectoryRoots;
  final Map<String, SnapshotNode> snapshot;
}

PushCounts _buildPushCounts(Map<String, SnapshotNode> snapshot) {
  var directoryCount = 0;
  var encryptedFileCount = 0;
  var plainFileCount = 0;
  var symlinkCount = 0;

  for (final node in snapshot.values) {
    if (node is DirectorySnapshotNode) {
      directoryCount += 1;
      continue;
    }

    if (node is SymlinkSnapshotNode) {
      symlinkCount += 1;
      continue;
    }

    if ((node as FileSnapshotNode).secret) {
      encryptedFileCount += 1;
    } else {
      plainFileCount += 1;
    }
  }

  return (
    directoryCount: directoryCount,
    encryptedFileCount: encryptedFileCount,
    plainFileCount: plainFileCount,
    symlinkCount: symlinkCount,
  );
}

Future<PushPlan> buildPushPlan(
  EffectiveSyncConfig config,
  String syncDirectory, [
  ArtifactOwnershipConfig? ownershipConfig,
]) async {
  final effectiveOwnershipConfig =
      ownershipConfig ?? (entries: config.entries, profiles: config.profiles);
  final snapshot = await tracePhase(
    'pushPlan.localSnapshot',
    () => buildLocalSnapshot(config),
  );
  final artifacts = await tracePhase(
    'pushPlan.buildArtifacts',
    () => buildRepoArtifacts(snapshot, config),
  );
  final artifactKeyPairs = [
    for (final artifact in artifacts)
      (artifact: artifact, key: buildArtifactKey(artifact)),
  ];
  final desiredArtifactKeys = {for (final pair in artifactKeyPairs) pair.key};
  final existingArtifactKeys = await tracePhase(
    'pushPlan.existingKeys',
    () => collectExistingArtifactKeys(
      syncDirectory,
      config,
      effectiveOwnershipConfig,
    ),
  );
  final staleArtifactKeys = [
    for (final key in existingArtifactKeys)
      if (!desiredArtifactKeys.contains(key)) key,
  ];
  final staleArtifactKeySet = Set<String>.of(staleArtifactKeys);
  final replacementPlan = await tracePhase(
    'pushPlan.staleReplacements',
    () => _collectStaleReplacementDirectoryRoots(
      syncDirectory,
      artifacts,
      staleArtifactKeySet,
      effectiveOwnershipConfig,
    ),
  );
  final writableArtifacts = [
    for (final pair in artifactKeyPairs)
      if (!replacementPlan.protectedArtifactKeys.contains(pair.key))
        pair.artifact,
  ];
  final writableArtifactKeys = {
    for (final artifact in writableArtifacts) buildArtifactKey(artifact),
  };
  final deletedArtifactKeys = <String>{
    ...staleArtifactKeys,
    ...replacementPlan.deletedArtifactKeys,
  };

  return PushPlan(
    artifacts: writableArtifacts,
    counts: _buildPushCounts(snapshot),
    deletedArtifactCount: deletedArtifactKeys.length,
    deletedArtifactKeys: deletedArtifactKeys,
    desiredArtifactKeys: writableArtifactKeys,
    existingArtifactKeys: existingArtifactKeys,
    staleReplacementDirectoryRoots: replacementPlan.roots,
    snapshot: snapshot,
  );
}

List<String> buildPushPlanPreview(PushPlan plan) {
  final createdOrUpdated = {
    for (final artifact in plan.artifacts) artifact.repoPath,
  }.toList()..sort(compareLocaleLike);
  final deletedArtifactKeys =
      plan.deletedArtifactKeys ??
      {
        for (final key in plan.existingArtifactKeys)
          if (!plan.desiredArtifactKeys.contains(key)) key,
      };
  final deleted = deletedArtifactKeys.toList()..sort(compareLocaleLike);

  return [...createdOrUpdated.take(4), ...deleted.take(4)].take(6).toList();
}

PushResult buildPushResultFromPlan(PushPlan plan, bool dryRun) {
  return PushResult(
    deletedArtifactCount: plan.deletedArtifactCount,
    directoryCount: plan.counts.directoryCount,
    dryRun: dryRun,
    encryptedFileCount: plan.counts.encryptedFileCount,
    plainFileCount: plan.counts.plainFileCount,
    symlinkCount: plan.counts.symlinkCount,
  );
}

Future<
  ({
    Set<String> deletedArtifactKeys,
    Set<String> protectedArtifactKeys,
    List<String> roots,
  })
>
_collectStaleReplacementDirectoryRoots(
  String syncDirectory,
  List<RepoArtifact> artifacts,
  Set<String> staleArtifactKeys,
  ArtifactOwnershipConfig ownershipConfig,
) async {
  final roots = <String>[];
  final deletedArtifactKeys = <String>{};
  final protectedArtifactKeys = <String>{};

  for (final artifact in artifacts) {
    if (artifact.kind == 'directory') {
      continue;
    }

    final relativePath = resolveArtifactRelativePath(
      category: artifact.category,
      kind: artifact.kind,
      profile: artifact.profile,
      repoPath: artifact.repoPath,
    );
    final logicalPath = resolveArtifactLogicalPath(
      category: artifact.category,
      kind: artifact.kind,
      profile: artifact.profile,
      repoPath: artifact.repoPath,
    );
    final artifactPath = p.joinAll([syncDirectory, ...relativePath.split('/')]);
    final stats = await getPathStats(artifactPath);

    if (stats?.isDirectory != true) {
      continue;
    }

    final parsedRoot = parseArtifactRelativePath(relativePath);
    final inactiveDirectoryOwner = nearestEntryOwnsArtifact(
      ownershipConfig.entries,
      parsedRoot,
      'directory',
    );

    if (inactiveDirectoryOwner) {
      protectedArtifactKeys.add(buildArtifactKey(artifact));
      continue;
    }

    final leafKeys = <String>{};
    await collectArtifactLeafKeys(
      artifactPath,
      leafKeys,
      logicalPath,
      null,
      true,
      stats,
    );

    if (leafKeys.isEmpty) {
      roots.add(relativePath);
      deletedArtifactKeys.add('$logicalPath/');
      continue;
    }

    if (leafKeys.every((leafKey) => staleArtifactKeys.contains(leafKey))) {
      roots.add(relativePath);
      continue;
    }

    protectedArtifactKeys.add(buildArtifactKey(artifact));
  }

  return (
    deletedArtifactKeys: deletedArtifactKeys,
    protectedArtifactKeys: protectedArtifactKeys,
    roots: roots,
  );
}

Future<PushResult> pushChanges(PushRequest request) async {
  final syncDirectory = resolveSyncPaths().syncDirectory;

  await requireGitRepository(syncDirectory);

  final loaded = await loadSyncConfig(syncDirectory, profile: request.profile);
  final config = loaded.effectiveConfig;
  final fullConfig = loaded.fullConfig;

  // Bring the repository up to the current on-disk format (e.g. convert legacy
  // physical symlinks to metadata files) before planning, so the plan reflects
  // the migrated state. Skipped on dry-run since it writes to the repository.
  if (!request.dryRun) {
    await ensureRepositoryFormat(syncDirectory, fullConfig);
  }

  final plan = await buildPushPlan(config, syncDirectory, (
    entries: fullConfig.entries,
    profiles: fullConfig.profiles,
  ));

  if (!request.dryRun) {
    await ensureManagedSecretArtifactIgnoreRules(syncDirectory);

    await limitConcurrency<String, void>(
      AppConstants.sync.defaultConcurrency,
      plan.staleReplacementDirectoryRoots ?? const [],
      (relativePath, _) async {
        await removePathAtomically(
          p.joinAll([syncDirectory, ...relativePath.split('/')]),
        );
      },
    );

    await limitConcurrency<String, void>(
      AppConstants.sync.defaultConcurrency,
      [
        for (final key in plan.existingArtifactKeys)
          if (!plan.desiredArtifactKeys.contains(key)) key,
      ],
      (staleKey, _) async {
        final relativePath = staleKey.endsWith('/')
            ? staleKey.substring(0, staleKey.length - 1)
            : staleKey;

        await removePathAtomically(
          p.joinAll([syncDirectory, 'profiles', ...relativePath.split('/')]),
        );
      },
    );

    await writeArtifactsToDirectory(syncDirectory, plan.artifacts, config.age);
  }

  return buildPushResultFromPlan(plan, request.dryRun);
}
