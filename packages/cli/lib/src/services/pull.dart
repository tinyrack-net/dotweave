import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/pull_apply.dart';
import 'package:dotweave/src/services/repo_snapshot.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/concurrency.dart';
import 'package:dotweave/src/util/git.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:dotweave/src/util/perf_trace.dart';

// Mirror of `services/pull.ts`: pull orchestration that turns the repository
// snapshot into per-entry materializations, a PullPlan of updated/deleted
// local paths, and applies the plan batched over non-overlapping entries.

/// Mirror of the TS `PullRequest` readonly object.
class PullRequest {
  const PullRequest({required this.dryRun, this.profile});

  final bool dryRun;
  final String? profile;
}

/// Mirror of the TS `PullResult` readonly object.
class PullResult {
  const PullResult({
    required this.decryptedFileCount,
    required this.deletedLocalCount,
    required this.directoryCount,
    required this.dryRun,
    required this.plainFileCount,
    required this.symlinkCount,
  });

  final int decryptedFileCount;
  final int deletedLocalCount;
  final int directoryCount;
  final bool dryRun;
  final int plainFileCount;
  final int symlinkCount;

  @override
  bool operator ==(Object other) {
    return other is PullResult &&
        other.decryptedFileCount == decryptedFileCount &&
        other.deletedLocalCount == deletedLocalCount &&
        other.directoryCount == directoryCount &&
        other.dryRun == dryRun &&
        other.plainFileCount == plainFileCount &&
        other.symlinkCount == symlinkCount;
  }

  @override
  int get hashCode => Object.hash(
    decryptedFileCount,
    deletedLocalCount,
    directoryCount,
    dryRun,
    plainFileCount,
    symlinkCount,
  );

  @override
  String toString() {
    return 'PullResult(decryptedFileCount: $decryptedFileCount, '
        'deletedLocalCount: $deletedLocalCount, '
        'directoryCount: $directoryCount, dryRun: $dryRun, '
        'plainFileCount: $plainFileCount, symlinkCount: $symlinkCount)';
  }
}

/// Mirror of the TS `PullPlan` readonly object.
class PullPlan {
  const PullPlan({
    required this.counts,
    required this.deletedLocalCount,
    required this.deletedLocalPaths,
    required this.desiredKeys,
    required this.existingKeys,
    required this.materializations,
    required this.updatedLocalPaths,
  });

  final PullCounts counts;
  final int deletedLocalCount;
  final List<String> deletedLocalPaths;
  final Set<String> desiredKeys;
  final Set<String> existingKeys;
  final List<EntryMaterialization?> materializations;
  final List<String> updatedLocalPaths;
}

/// Mirror of the TS `PreparedPull` readonly object.
class PreparedPull {
  const PreparedPull({
    required this.config,
    required this.plan,
    required this.syncDirectory,
  });

  final EffectiveSyncConfig config;
  final PullPlan plan;
  final String syncDirectory;
}

// A field cannot default to a top-level function of the same name -- the
// field shadows it in the initializer -- so the defaults go through aliases.
const _defaultApplyEntryMaterialization = applyEntryMaterialization;
const _defaultBuildEntryMaterialization = buildEntryMaterialization;
const _defaultBuildPullCounts = buildPullCounts;
const _defaultBuildRepositorySnapshot = buildRepositorySnapshot;
const _defaultCollectChangedLocalPaths = collectChangedLocalPaths;
const _defaultCountDeletedLocalNodes = countDeletedLocalNodes;
const _defaultLoadSyncConfig = loadSyncConfig;
const _defaultRequireGitRepository = requireGitRepository;
const _defaultResolveSyncPaths = resolveSyncPaths;

/// Collaborators of the pull orchestration, standing in for the vitest
/// module mocks used by `pull.test.ts`.
///
/// Every field defaults to the real implementation and none is nullable:
/// production overrides nothing and tests supply every field, so an
/// optional-with-fallback field paid for a call pattern nobody used. Making
/// them required-with-default means a test that forgets one fails to compile
/// rather than silently reaching the real filesystem.
class PullDependencies {
  const PullDependencies({
    this.applyEntryMaterialization = _defaultApplyEntryMaterialization,
    this.buildEntryMaterialization = _defaultBuildEntryMaterialization,
    this.buildPullCounts = _defaultBuildPullCounts,
    this.buildRepositorySnapshot = _defaultBuildRepositorySnapshot,
    this.collectChangedLocalPaths = _defaultCollectChangedLocalPaths,
    this.countDeletedLocalNodes = _defaultCountDeletedLocalNodes,
    this.loadSyncConfig = _defaultLoadSyncConfig,
    this.requireGitRepository = _defaultRequireGitRepository,
    this.resolveSyncPaths = _defaultResolveSyncPaths,
  });

  final Future<void> Function(
    ResolvedSyncConfigEntry entry,
    EntryMaterialization materialization,
    EffectiveSyncConfig config,
  )
  applyEntryMaterialization;
  final EntryMaterialization Function(
    ResolvedSyncConfigEntry entry,
    Map<String, SnapshotNode> snapshot,
    EffectiveSyncConfig config,
  )
  buildEntryMaterialization;
  final PullCounts Function(List<EntryMaterialization?> materializations)
  buildPullCounts;
  final Future<Map<String, SnapshotNode>> Function(
    String syncDirectory,
    EffectiveSyncConfig config,
  )
  buildRepositorySnapshot;
  final Future<List<String>> Function(
    ResolvedSyncConfigEntry entry,
    EntryMaterialization materialization,
    EffectiveSyncConfig? config,
  )
  collectChangedLocalPaths;
  final Future<int> Function(
    ResolvedSyncConfigEntry entry,
    Set<String> desiredKeys,
    EffectiveSyncConfig config,
    Set<String>? existingKeys,
    Map<String, String>? keyToLocalPath,
    Set<String>? deletedKeys,
  )
  countDeletedLocalNodes;
  final Future<LoadedSyncConfig> Function(
    String syncDirectory, {
    String? profile,
  })
  loadSyncConfig;
  final Future<void> Function(String syncDirectory) requireGitRepository;
  final SyncPaths Function() resolveSyncPaths;
}

List<String> _buildDeletedLocalPaths(
  Set<String> deletedKeys,
  Map<String, String> keyToLocalPath,
) {
  return [
    for (final key in deletedKeys)
      if (keyToLocalPath[key] != null) keyToLocalPath[key]!,
  ]..sort(compareLocaleLike);
}

Future<List<String>> _buildUpdatedLocalPaths(
  EffectiveSyncConfig config,
  List<EntryMaterialization?> materializations,
  Future<List<String>> Function(
    ResolvedSyncConfigEntry entry,
    EntryMaterialization materialization,
    EffectiveSyncConfig? config,
  )
  collectChangedLocalPathsFn,
) async {
  final changedLocalPaths = <String>{};

  for (var index = 0; index < config.entries.length; index += 1) {
    final entry = config.entries[index];
    final materialization = index < materializations.length
        ? materializations[index]
        : null;

    if (materialization == null) {
      continue;
    }

    final childEntryLocalPaths = entry.kind != 'directory'
        ? const <String>[]
        : [
            for (final candidate in config.entries)
              if (!identical(candidate, entry) &&
                  isPathEqualOrNested(candidate.localPath, entry.localPath))
                candidate.localPath,
          ];

    for (final path in await collectChangedLocalPathsFn(
      entry,
      materialization,
      config,
    )) {
      if (childEntryLocalPaths.any((childPath) {
        return isPathEqualOrNested(path, childPath);
      })) {
        continue;
      }

      changedLocalPaths.add(path);
    }
  }

  return [...changedLocalPaths]..sort(compareLocaleLike);
}

Future<PullPlan> buildPullPlan(
  EffectiveSyncConfig config,
  String syncDirectory, [
  PullDependencies dependencies = const PullDependencies(),
]) async {
  final Future<int> Function(
    ResolvedSyncConfigEntry entry,
    Set<String> desiredKeys,
    EffectiveSyncConfig config,
    Set<String>? existingKeys,
    Map<String, String>? keyToLocalPath,
    Set<String>? deletedKeys,
  )
  effectiveCountDeletedLocalNodes = dependencies.countDeletedLocalNodes;
  final Future<List<String>> Function(
    ResolvedSyncConfigEntry entry,
    EntryMaterialization materialization,
    EffectiveSyncConfig? config,
  )
  effectiveCollectChangedLocalPaths = dependencies.collectChangedLocalPaths;

  final snapshot = await tracePhase(
    'plan.repoSnapshot',
    () => dependencies.buildRepositorySnapshot(syncDirectory, config),
  );
  final materializations = await tracePhase(
    'plan.materializations',
    () async => <EntryMaterialization?>[
      for (final entry in config.entries)
        entry.mode == 'ignore'
            ? null
            : dependencies.buildEntryMaterialization(entry, snapshot, config),
    ],
  );

  var deletedLocalCount = 0;
  final existingKeys = <String>{};
  final keyToLocalPath = <String, String>{};
  final deletedKeys = <String>{};

  for (var index = 0; index < config.entries.length; index += 1) {
    final entry = config.entries[index];
    final materialization = index < materializations.length
        ? materializations[index]
        : null;

    if (materialization == null) {
      continue;
    }

    final entryExistingKeys = <String>{};
    final entryKeyToLocalPath = <String, String>{};

    deletedLocalCount += await tracePhase(
      'plan.countDeletedWalk',
      () => effectiveCountDeletedLocalNodes(
        entry,
        materialization.desiredKeys,
        config,
        entryExistingKeys,
        entryKeyToLocalPath,
        deletedKeys,
      ),
    );

    for (final key in entryExistingKeys) {
      existingKeys.add(key);
    }

    for (final MapEntry(key: key, value: localPath)
        in entryKeyToLocalPath.entries) {
      keyToLocalPath[key] = localPath;
    }
  }

  final desiredKeys = <String>{
    for (final materialization in materializations)
      if (materialization != null) ...materialization.desiredKeys,
  };
  final deletedLocalPaths = _buildDeletedLocalPaths(
    deletedKeys,
    keyToLocalPath,
  );
  final deletedLocalPathSet = Set<String>.of(deletedLocalPaths);
  final updatedLocalPaths = [
    for (final path in await tracePhase(
      'plan.collectChangedPaths',
      () => _buildUpdatedLocalPaths(
        config,
        materializations,
        effectiveCollectChangedLocalPaths,
      ),
    ))
      if (!deletedLocalPathSet.contains(path)) path,
  ];

  return PullPlan(
    counts: dependencies.buildPullCounts(materializations),
    deletedLocalCount: deletedLocalCount,
    deletedLocalPaths: deletedLocalPaths,
    desiredKeys: desiredKeys,
    existingKeys: existingKeys,
    materializations: materializations,
    updatedLocalPaths: updatedLocalPaths,
  );
}

List<String> buildPullPlanPreview(PullPlan plan) {
  return [
    ...plan.updatedLocalPaths.take(4),
    ...plan.deletedLocalPaths.take(4),
  ].take(6).toList();
}

PullResult buildPullResultFromPlan(PullPlan plan, bool dryRun) {
  return PullResult(
    decryptedFileCount: plan.counts.decryptedFileCount,
    deletedLocalCount: plan.deletedLocalCount,
    directoryCount: plan.counts.directoryCount,
    dryRun: dryRun,
    plainFileCount: plan.counts.plainFileCount,
    symlinkCount: plan.counts.symlinkCount,
  );
}

Future<PullResult> pullChanges(
  PullRequest request, [
  PullDependencies dependencies = const PullDependencies(),
]) async {
  final prepared = await preparePull(request, dependencies);

  if (!request.dryRun) {
    await applyPullPlan(prepared.config, prepared.plan, dependencies);
  }

  return buildPullResultFromPlan(prepared.plan, request.dryRun);
}

Future<PreparedPull> preparePull(
  PullRequest request, [
  PullDependencies dependencies = const PullDependencies(),
]) async {
  final syncDirectory = dependencies.resolveSyncPaths().syncDirectory;

  await dependencies.requireGitRepository(syncDirectory);

  final config = (await dependencies.loadSyncConfig(
    syncDirectory,
    profile: request.profile,
  )).effectiveConfig;
  final plan = await tracePhase(
    'prepare.buildPullPlan',
    () => buildPullPlan(config, syncDirectory, dependencies),
  );
  dumpPerfTrace('preparePull');

  return PreparedPull(config: config, plan: plan, syncDirectory: syncDirectory);
}

List<List<int>> _buildApplyPullPlanBatches(
  EffectiveSyncConfig config,
  PullPlan plan,
) {
  final batches = <List<int>>[];

  for (var index = 0; index < config.entries.length; index += 1) {
    final entry = config.entries[index];
    final materialization = index < plan.materializations.length
        ? plan.materializations[index]
        : null;

    if (materialization == null) {
      continue;
    }

    List<int>? assignedBatch;

    for (final batch in batches) {
      final overlapsBatch = batch.any((batchIndex) {
        final batchEntry = config.entries[batchIndex];

        return doPathsOverlap(entry.localPath, batchEntry.localPath);
      });

      if (!overlapsBatch) {
        assignedBatch = batch;
        break;
      }
    }

    if (assignedBatch == null) {
      assignedBatch = [];
      batches.add(assignedBatch);
    }

    assignedBatch.add(index);
  }

  return batches;
}

Future<void> applyPullPlan(
  EffectiveSyncConfig config,
  PullPlan plan, [
  PullDependencies dependencies = const PullDependencies(),
]) async {
  for (final batch in _buildApplyPullPlanBatches(config, plan)) {
    await limitConcurrency<int, void>(
      AppConstants.sync.defaultConcurrency,
      batch,
      (index, _) async {
        final entry = config.entries[index];
        final materialization = index < plan.materializations.length
            ? plan.materializations[index]
            : null;

        if (materialization == null) {
          return;
        }

        await dependencies.applyEntryMaterialization(
          entry,
          materialization,
          config,
        );
      },
    );
  }

  dumpPerfTrace('applyPullPlan');
}
