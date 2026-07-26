import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/concurrency.dart';
import 'package:dotweave/src/util/content.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/file_mode.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:dotweave/src/util/perf_trace.dart';
import 'package:dotweave/src/util/posix_chmod.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/pull-apply.ts`: builds per-entry materialization plans
// from the repository snapshot and applies them to the local filesystem with
// atomic staging (mkdtemp + rename) and bottom-up stale-path deletion.

/// Mirror of the TS `EntryMaterialization` discriminated union
/// (`absent` | `file` | `directory`).
sealed class EntryMaterialization {
  const EntryMaterialization();

  Set<String> get desiredKeys;

  /// TS discriminant: `absent`, `file`, or `directory`.
  String get type;
}

/// The `absent` variant of [EntryMaterialization].
final class AbsentEntryMaterialization extends EntryMaterialization {
  const AbsentEntryMaterialization({required this.desiredKeys});

  @override
  final Set<String> desiredKeys;

  @override
  String get type => 'absent';
}

/// The `file` variant of [EntryMaterialization].
final class FileEntryMaterialization extends EntryMaterialization {
  const FileEntryMaterialization({
    required this.desiredKeys,
    required this.node,
  });

  @override
  final Set<String> desiredKeys;

  final FileLikeSnapshotNode node;

  @override
  String get type => 'file';
}

/// The `directory` variant of [EntryMaterialization].
final class DirectoryEntryMaterialization extends EntryMaterialization {
  const DirectoryEntryMaterialization({
    required this.desiredKeys,
    required this.nodes,
  });

  @override
  final Set<String> desiredKeys;

  final Map<String, FileLikeSnapshotNode> nodes;

  @override
  String get type => 'directory';
}

/// Bridges [EffectiveSyncConfig] into the [ResolvedSyncConfig] shape accepted
/// by the sync-query helpers. TS relies on structural typing for this; the
/// queries only read `entries`/`profiles`, which both classes carry.
ResolvedSyncConfig _toResolvedSyncConfig(EffectiveSyncConfig config) {
  return ResolvedSyncConfig(
    entries: config.entries,
    profiles: config.profiles,
    repositoryFormat: config.repositoryFormat,
    version: config.version,
  );
}

Set<String> buildDesiredDirectoryKeys(
  ResolvedSyncConfigEntry entry,
  Map<String, FileLikeSnapshotNode> desiredNodes,
) {
  final desiredDirectoryKeys = <String>{buildDirectoryKey(entry.repoPath)};

  for (final relativePath in desiredNodes.keys) {
    final segments = relativePath.split('/');

    for (var index = 1; index < segments.length; index += 1) {
      desiredDirectoryKeys.add(
        buildDirectoryKey(
          p.posix.joinAll([entry.repoPath, ...segments.sublist(0, index)]),
        ),
      );
    }
  }

  return desiredDirectoryKeys;
}

EntryMaterialization buildEntryMaterialization(
  ResolvedSyncConfigEntry entry,
  Map<String, SnapshotNode> snapshot,
  EffectiveSyncConfig config,
) {
  final queryConfig = _toResolvedSyncConfig(config);

  if (entry.kind == 'file') {
    final node = snapshot[entry.repoPath];

    if (node == null) {
      return const AbsentEntryMaterialization(desiredKeys: {});
    }

    if (node is! FileLikeSnapshotNode) {
      throw DotweaveError(
        'File sync entry resolves to a directory in the repository.',
        code: 'FILE_ENTRY_RESOLVES_DIRECTORY',
        details: ['Repository path: ${entry.repoPath}'],
        hint:
            "Run 'dotweave push' or fix the repository so this path is "
            'stored as a file.',
      );
    }

    return FileEntryMaterialization(desiredKeys: {entry.repoPath}, node: node);
  }

  final rootNode = snapshot[entry.repoPath];

  if (rootNode != null && rootNode is! DirectorySnapshotNode) {
    throw DotweaveError(
      'Directory sync entry resolves to a file in the repository.',
      code: 'DIRECTORY_ENTRY_RESOLVES_FILE',
      details: ['Repository path: ${entry.repoPath}'],
      hint:
          "Run 'dotweave push' or fix the repository so this path is "
          'stored as a directory.',
    );
  }

  final nodes = <String, FileLikeSnapshotNode>{};
  final desiredKeys = <String>{};
  final childEntryPaths = collectChildEntryPaths(queryConfig, entry);

  for (final MapEntry(key: repoPath, value: node) in snapshot.entries) {
    if (!repoPath.startsWith('${entry.repoPath}/')) {
      continue;
    }

    if (node is! FileLikeSnapshotNode) {
      continue;
    }

    if (childEntryPaths.contains(repoPath)) {
      continue;
    }

    if (!identical(findOwningSyncEntry(queryConfig, repoPath), entry)) {
      continue;
    }

    final relativePath = repoPath.substring(entry.repoPath.length + 1);

    nodes[relativePath] = node;
    desiredKeys.add(repoPath);
  }

  if (rootNode == null && nodes.isEmpty) {
    return AbsentEntryMaterialization(desiredKeys: desiredKeys);
  }

  desiredKeys.add(buildDirectoryKey(entry.repoPath));

  return DirectoryEntryMaterialization(desiredKeys: desiredKeys, nodes: nodes);
}

bool _materializedDirectoryModeMatches(int actualMode, [int? fileMode]) {
  if (!supportsPosixFileModes()) {
    return true;
  }

  if (fileMode == null) {
    return true;
  }

  final maskedActualMode = actualMode & 0x1FF; // 0o777

  return maskedActualMode == (buildSearchableDirectoryMode(fileMode) & 0x1FF);
}

bool _materializedFileModeMatches(
  int actualMode,
  bool executable, [
  int? fileMode,
]) {
  if (!supportsPosixFileModes()) {
    return true;
  }

  final maskedActualMode = actualMode & 0x1FF; // 0o777

  if (fileMode == null) {
    return isExecutableMode(maskedActualMode) == executable;
  }

  return maskedActualMode == (fileMode & 0x1FF);
}

Future<bool> _isMaterializedFileLikeNodeCurrent(
  String targetPath,
  FileLikeSnapshotNode node, [
  int? fileMode,
]) async {
  final stats = await getPathStats(targetPath);

  if (stats == null) {
    return false;
  }

  switch (node) {
    case SymlinkSnapshotNode():
      if (!stats.isSymbolicLink) {
        return false;
      }

      final currentLinkTarget = await readLinkTarget(targetPath);

      return normalizeLinkTarget(currentLinkTarget, p.dirname(targetPath)) ==
          normalizeLinkTarget(node.linkTarget, p.dirname(targetPath));
    case FileSnapshotNode():
      if (!stats.isFile) {
        return false;
      }

      final currentContents = await File(targetPath).readAsBytes();

      return fileContentsEqual(
            node.contents,
            currentContents,
            normalizeTextLineEndings: shouldNormalizeTextLineEndings(),
          ) &&
          _materializedFileModeMatches(stats.mode, node.executable, fileMode);
  }
}

/// Per-directory cache for [_resolveStagingParentDirectory]: within one
/// apply pass thousands of sibling files share a handful of parent
/// directories, and the parents are created before the per-node loop runs,
/// so their resolution is stable for the process lifetime of a pull.
final Map<String, String> _stagingParentCache = <String, String>{};

String _resolveStagingParentDirectory(String targetPath) {
  final parentDirectory = p.dirname(targetPath);

  if (!Platform.isWindows) {
    return parentDirectory;
  }

  return _stagingParentCache[parentDirectory] ??= () {
    try {
      // Mirrors node:fs `realpathSync.native(parentDirectory)`.
      return Directory(parentDirectory).resolveSymbolicLinksSync();
    } on FileSystemException {
      // The directory may not exist yet, or may not be resolvable (a broken
      // link, a permission boundary). The unresolved path is still a usable
      // staging parent, so fall back rather than fail the whole pull.
      return parentDirectory;
    }
  }();
}

Future<void> _stageAndReplacePath(
  String targetPath,
  FileLikeSnapshotNode node, [
  int? fileMode,
]) async {
  await tracePhase(
    'stage.ensureParent',
    () => Directory(p.dirname(targetPath)).create(recursive: true),
  );
  final stagingDirectory = await tracePhase(
    'stage.createTemp',
    () => Directory(
      _resolveStagingParentDirectory(targetPath),
    ).createTemp('.${p.basename(targetPath)}.dotweave-sync-'),
  );
  final stagedPath = p.join(stagingDirectory.path, p.basename(targetPath));

  try {
    switch (node) {
      case SymlinkSnapshotNode():
        await createSymlink(toNativeLinkTarget(node.linkTarget), stagedPath);
      case FileSnapshotNode():
        // The staged file's parent is the createTemp directory made just
        // above — no need to re-ensure it.
        await tracePhase(
          'stage.writeFileNode',
          () => writeFileNode(
            stagedPath,
            (contents: node.contents, executable: node.executable),
            fileMode: fileMode,
            ensureParent: false,
          ),
        );
    }

    await tracePhase(
      'stage.replaceAtomically',
      () => replacePathAtomically(targetPath, stagedPath),
    );
  } finally {
    await tracePhase(
      'stage.cleanupStaging',
      () => removePath(stagingDirectory.path),
    );
  }
}

Future<void> _stageAndReplaceDirectoryPath(
  String targetPath, [
  int? fileMode,
]) async {
  await Directory(p.dirname(targetPath)).create(recursive: true);
  final stagingDirectory = await Directory(
    _resolveStagingParentDirectory(targetPath),
  ).createTemp('.${p.basename(targetPath)}.dotweave-sync-');

  try {
    // The TS `chmod` is a POSIX-mode no-op on Windows; `posixChmod` must not
    // be called there, so the call is guarded like `writeFileNode`.
    if (fileMode != null && !Platform.isWindows) {
      posixChmod(stagingDirectory.path, buildSearchableDirectoryMode(fileMode));
    }

    await replacePathAtomically(targetPath, stagingDirectory.path);
  } finally {
    await removePath(stagingDirectory.path);
  }
}

Future<void> _ensureMaterializedDirectoryPath(
  String targetPath, [
  int? fileMode,
]) async {
  final stats = await getFollowedPathStats(targetPath);

  if (stats == null) {
    await Directory(targetPath).create(recursive: true);

    // The TS `chmod` is a POSIX-mode no-op on Windows; `posixChmod` must not
    // be called there, so the call is guarded like `writeFileNode`.
    if (fileMode != null && !Platform.isWindows) {
      posixChmod(targetPath, buildSearchableDirectoryMode(fileMode));
    }

    return;
  }

  if (!stats.isDirectory) {
    await _stageAndReplaceDirectoryPath(targetPath, fileMode);
    return;
  }

  if (fileMode != null &&
      !_materializedDirectoryModeMatches(stats.mode, fileMode)) {
    posixChmod(targetPath, buildSearchableDirectoryMode(fileMode));
  }
}

Future<void> _collectLocalLeafKeys(
  String targetPath,
  String repoPathPrefix,
  Set<String> keys,
  Map<String, String>? keyToLocalPath,
  Set<String> childEntryPaths, [
  String? prefix,
  PathStats? providedStats,
]) async {
  final stats = providedStats ?? await getPathStats(targetPath);

  if (stats == null) {
    return;
  }

  if (!stats.isDirectory) {
    keys.add(repoPathPrefix);
    keyToLocalPath?[repoPathPrefix] = targetPath;

    return;
  }

  final currentRepoPath = prefix == null
      ? repoPathPrefix
      : p.posix.join(repoPathPrefix, prefix);
  final directoryKey = buildDirectoryKey(currentRepoPath);
  keys.add(directoryKey);
  keyToLocalPath?[directoryKey] = targetPath;

  final entries = await listDirectoryEntries(targetPath);

  for (final entry in entries) {
    final absolutePath = p.join(targetPath, entry.name);
    final relativePath = prefix == null ? entry.name : '$prefix/${entry.name}';
    final childStats = await getPathStats(absolutePath);
    final repoPath = p.posix.join(repoPathPrefix, relativePath);

    if (childStats == null) {
      continue;
    }

    if (childEntryPaths.contains(repoPath)) {
      continue;
    }

    if (childStats.isDirectory) {
      // `childStats` was just fetched above for this exact path; thread it
      // through so the recursive call doesn't stat the same path again.
      await _collectLocalLeafKeys(
        absolutePath,
        repoPathPrefix,
        keys,
        keyToLocalPath,
        childEntryPaths,
        relativePath,
        childStats,
      );
      continue;
    }

    keys.add(repoPath);
    keyToLocalPath?[repoPath] = absolutePath;
  }
}

int _buildLocalPathDepth(String localPath) {
  return localPath.split(RegExp(r'[/\\]+')).length;
}

Future<List<String>> collectDeletableLocalKeys(
  Set<String> existingKeys,
  Set<String> desiredKeys,
  Map<String, String> keyToLocalPath,
) async {
  final deletableKeys = <String>[];
  final scheduledLocalPaths = <String>{};

  final isWindows = Platform.isWindows;
  final desiredKeysForComparison = isWindows
      ? {for (final key in desiredKeys) key.toLowerCase()}
      : desiredKeys;

  final staleKeys =
      [
        for (final key in existingKeys)
          if (isWindows
              ? !desiredKeysForComparison.contains(key.toLowerCase())
              : !desiredKeysForComparison.contains(key))
            key,
      ]..sort((left, right) {
        final leftPath = keyToLocalPath[left] ?? '';
        final rightPath = keyToLocalPath[right] ?? '';
        final depthDifference =
            _buildLocalPathDepth(rightPath) - _buildLocalPathDepth(leftPath);

        if (depthDifference != 0) {
          return depthDifference;
        }

        return compareLocaleLike(rightPath, leftPath);
      });

  for (final key in staleKeys) {
    final localPath = keyToLocalPath[key];

    if (localPath == null) {
      continue;
    }

    final stats = await getPathStats(localPath);

    if (stats == null) {
      continue;
    }

    if (!stats.isDirectory) {
      deletableKeys.add(key);
      scheduledLocalPaths.add(localPath);
      continue;
    }

    final entries = await listDirectoryEntries(localPath);
    final canDeleteDirectory = entries.every((entry) {
      return scheduledLocalPaths.contains(p.join(localPath, entry.name));
    });

    if (!canDeleteDirectory) {
      continue;
    }

    deletableKeys.add(key);
    scheduledLocalPaths.add(localPath);
  }

  return deletableKeys;
}

Future<int> countDeletedLocalNodes(
  ResolvedSyncConfigEntry entry,
  Set<String> desiredKeys,
  EffectiveSyncConfig config, [
  Set<String>? existingKeys,
  Map<String, String>? keyToLocalPath,
  Set<String>? deletedKeys,
]) async {
  final effectiveExistingKeys = existingKeys ?? <String>{};
  final queryConfig = _toResolvedSyncConfig(config);
  final rule = resolveSyncRule(
    queryConfig,
    entry.repoPath,
    config.activeProfile,
  );

  if (rule == null || rule.mode == 'ignore') {
    return 0;
  }

  final childEntryPaths = entry.kind == 'directory'
      ? collectChildEntryPaths(queryConfig, entry)
      : <String>{};

  final rootStats = entry.kind == 'directory'
      ? await getFollowedPathStats(entry.localPath)
      : await getPathStats(entry.localPath);

  await _collectLocalLeafKeys(
    entry.localPath,
    entry.repoPath,
    effectiveExistingKeys,
    keyToLocalPath,
    childEntryPaths,
    null,
    rootStats,
  );

  final deletableKeys = await collectDeletableLocalKeys(
    effectiveExistingKeys,
    desiredKeys,
    keyToLocalPath ?? <String, String>{},
  );

  for (final key in deletableKeys) {
    deletedKeys?.add(key);
  }

  return deletableKeys.length;
}

Future<List<String>> collectChangedLocalPaths(
  ResolvedSyncConfigEntry entry,
  EntryMaterialization materialization, [
  EffectiveSyncConfig? config,
]) async {
  if (materialization is AbsentEntryMaterialization) {
    if (config == null) {
      return [];
    }

    final existingKeys = <String>{};
    final keyToLocalPath = <String, String>{};
    final deletedKeys = <String>{};
    await countDeletedLocalNodes(
      entry,
      materialization.desiredKeys,
      config,
      existingKeys,
      keyToLocalPath,
      deletedKeys,
    );

    return [
      for (final key in deletedKeys)
        if (keyToLocalPath[key] != null) keyToLocalPath[key]!,
    ]..sort(compareLocaleLike);
  }

  if (materialization is FileEntryMaterialization) {
    return await _isMaterializedFileLikeNodeCurrent(
          entry.localPath,
          materialization.node,
          entry.permission,
        )
        ? []
        : [entry.localPath];
  }

  final directoryMaterialization =
      materialization as DirectoryEntryMaterialization;
  final changedLocalPaths = <String>[];
  final rootStats = await getFollowedPathStats(entry.localPath);

  if (rootStats == null || !rootStats.isDirectory) {
    changedLocalPaths.add(entry.localPath);
  } else if (!_materializedDirectoryModeMatches(
    rootStats.mode,
    entry.permission,
  )) {
    changedLocalPaths.add(entry.localPath);
  }

  for (final relativePath in [
    ...directoryMaterialization.nodes.keys,
  ]..sort(compareLocaleLike)) {
    final node = directoryMaterialization.nodes[relativePath];

    if (node == null) {
      continue;
    }

    final targetPath = p.joinAll([entry.localPath, ...relativePath.split('/')]);

    if (!await _isMaterializedFileLikeNodeCurrent(
      targetPath,
      node,
      entry.permission,
    )) {
      changedLocalPaths.add(targetPath);
    }
  }

  if (config != null) {
    final existingKeys = <String>{};
    final keyToLocalPath = <String, String>{};
    final deletedKeys = <String>{};
    await countDeletedLocalNodes(
      entry,
      directoryMaterialization.desiredKeys,
      config,
      existingKeys,
      keyToLocalPath,
      deletedKeys,
    );

    for (final key in deletedKeys) {
      final localPath = keyToLocalPath[key];

      if (localPath != null) {
        changedLocalPaths.add(localPath);
      }
    }
  }

  return [
    ...{...changedLocalPaths},
  ]..sort(compareLocaleLike);
}

/// Mirror of the TS `buildPullCounts` inline return object.
typedef PullCounts = ({
  int decryptedFileCount,
  int directoryCount,
  int plainFileCount,
  int symlinkCount,
});

PullCounts buildPullCounts(List<EntryMaterialization?> materializations) {
  var decryptedFileCount = 0;
  var directoryCount = 0;
  var plainFileCount = 0;
  var symlinkCount = 0;

  for (final materialization in materializations) {
    if (materialization == null) {
      continue;
    }

    if (materialization is FileEntryMaterialization) {
      switch (materialization.node) {
        case SymlinkSnapshotNode():
          symlinkCount += 1;
        case FileSnapshotNode(secret: true):
          decryptedFileCount += 1;
        case FileSnapshotNode():
          plainFileCount += 1;
      }

      continue;
    }

    if (materialization is! DirectoryEntryMaterialization) {
      continue;
    }

    directoryCount += 1;

    for (final node in materialization.nodes.values) {
      switch (node) {
        case SymlinkSnapshotNode():
          symlinkCount += 1;
        case FileSnapshotNode(secret: true):
          decryptedFileCount += 1;
        case FileSnapshotNode():
          plainFileCount += 1;
      }
    }
  }

  return (
    decryptedFileCount: decryptedFileCount,
    directoryCount: directoryCount,
    plainFileCount: plainFileCount,
    symlinkCount: symlinkCount,
  );
}

Future<void> _reconcileMaterializedDirectoryPath(
  ResolvedSyncConfigEntry entry,
  Set<String> desiredKeys,
  Map<String, FileLikeSnapshotNode> desiredNodes,
  EffectiveSyncConfig config, [
  int? fileMode,
]) async {
  final desiredRootKey = buildDirectoryKey(entry.repoPath);
  final desiredRootExists = desiredKeys.contains(desiredRootKey);

  if (desiredRootExists) {
    await _ensureMaterializedDirectoryPath(entry.localPath, fileMode);
  }

  final desiredDirectoryKeys = desiredRootExists
      ? buildDesiredDirectoryKeys(entry, desiredNodes)
      : <String>{};

  await limitConcurrency<String, void>(
    AppConstants.sync.defaultConcurrency,
    [...desiredDirectoryKeys]..sort(compareLocaleLike),
    (directoryKey, _) async {
      if (directoryKey == desiredRootKey) {
        return;
      }

      final relativePath = directoryKey.substring(
        entry.repoPath.length + 1,
        directoryKey.length - 1,
      );
      await _ensureMaterializedDirectoryPath(
        p.joinAll([entry.localPath, ...relativePath.split('/')]),
        fileMode,
      );
    },
  );

  await limitConcurrency<String, void>(
    AppConstants.sync.defaultConcurrency,
    [...desiredNodes.keys]..sort(compareLocaleLike),
    (relativePath, _) async {
      final node = desiredNodes[relativePath];

      if (node == null) {
        return;
      }

      final targetNodePath = p.joinAll([
        entry.localPath,
        ...relativePath.split('/'),
      ]);

      if (await tracePhase(
        'reconcile.currencyCheck',
        () =>
            _isMaterializedFileLikeNodeCurrent(targetNodePath, node, fileMode),
      )) {
        return;
      }

      await _stageAndReplacePath(targetNodePath, node, fileMode);
    },
  );

  final existingKeys = <String>{};
  final keyToLocalPath = <String, String>{};
  await tracePhase(
    'reconcile.countDeletedWalk',
    () => countDeletedLocalNodes(
      entry,
      desiredKeys,
      config,
      existingKeys,
      keyToLocalPath,
    ),
  );

  final deletableKeys = await collectDeletableLocalKeys(
    existingKeys,
    desiredKeys,
    keyToLocalPath,
  );

  for (final key in deletableKeys) {
    final localPath = keyToLocalPath[key];

    if (localPath == null) {
      continue;
    }

    await removePathAtomically(localPath);
  }
}

Future<void> applyEntryMaterialization(
  ResolvedSyncConfigEntry entry,
  EntryMaterialization materialization,
  EffectiveSyncConfig config,
) async {
  final rule = resolveSyncRule(
    _toResolvedSyncConfig(config),
    entry.repoPath,
    config.activeProfile,
  );

  if (rule == null || rule.mode == 'ignore') {
    return;
  }

  switch (materialization) {
    case AbsentEntryMaterialization():
      if (entry.kind == 'directory') {
        await _reconcileMaterializedDirectoryPath(
          entry,
          materialization.desiredKeys,
          {},
          config,
          entry.permission,
        );

        return;
      }

      await removePathAtomically(entry.localPath);
    case FileEntryMaterialization():
      await _stageAndReplacePath(
        entry.localPath,
        materialization.node,
        entry.permission,
      );
    case DirectoryEntryMaterialization():
      await _reconcileMaterializedDirectoryPath(
        entry,
        materialization.desiredKeys,
        materialization.nodes,
        config,
        entry.permission,
      );
  }
}
