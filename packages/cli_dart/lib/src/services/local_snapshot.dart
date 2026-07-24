import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/file_mode.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/path_util.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/local-snapshot.ts`: walks the tracked local paths into
// an in-memory snapshot map keyed by repository path.

/// Mirror of the TS `SnapshotNode` discriminated union
/// (`directory` | `file` | `symlink`).
sealed class SnapshotNode {
  const SnapshotNode();

  /// TS discriminant: `directory`, `file`, or `symlink`.
  String get type;
}

/// The `directory` variant of [SnapshotNode].
final class DirectorySnapshotNode extends SnapshotNode {
  const DirectorySnapshotNode();

  @override
  String get type => 'directory';
}

/// Mirror of the TS `FileLikeSnapshotNode` extract
/// (`file` | `symlink` variants of [SnapshotNode]).
sealed class FileLikeSnapshotNode extends SnapshotNode {
  const FileLikeSnapshotNode();
}

/// Mirror of the TS `FileSnapshotNode` extract (the `file` variant).
final class FileSnapshotNode extends FileLikeSnapshotNode {
  const FileSnapshotNode({
    required this.executable,
    required this.secret,
    required this.contents,
  });

  final bool executable;
  final bool secret;
  final Uint8List contents;

  @override
  String get type => 'file';
}

/// The `symlink` variant of [SnapshotNode].
final class SymlinkSnapshotNode extends FileLikeSnapshotNode {
  const SymlinkSnapshotNode({required this.linkTarget});

  final String linkTarget;

  @override
  String get type => 'symlink';
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

bool _resolveSnapshotExecutable(
  EffectiveSyncConfig config,
  String repoPath,
  int filesystemMode,
) {
  final entry = findOwningSyncEntry(_toResolvedSyncConfig(config), repoPath);

  return isExecutableMode(entry?.permission ?? filesystemMode);
}

void addSnapshotNode(
  Map<String, SnapshotNode> snapshot,
  String repoPath,
  SnapshotNode node,
) {
  if (snapshot.containsKey(repoPath)) {
    throw DotweaveError('Duplicate sync path generated for $repoPath');
  }

  snapshot[repoPath] = node;
}

Future<void> _addLocalNode(
  Map<String, SnapshotNode> snapshot,
  EffectiveSyncConfig config,
  String repoPath,
  String path,
  PathStats stats,
) async {
  assertStorageSafeRepoPath(repoPath);
  final mode = requireManagedSyncMode(
    _toResolvedSyncConfig(config),
    repoPath,
    config.activeProfile,
  );

  if (mode == 'ignore') {
    return;
  }

  if (stats.isDirectory) {
    throw DotweaveError(
      'Expected a file-like path but found a directory: $path',
    );
  }

  if (stats.isSymbolicLink) {
    if (mode == 'secret') {
      throw DotweaveError(
        'Secret sync paths must be regular files, not symlinks: $repoPath',
      );
    }

    addSnapshotNode(
      snapshot,
      repoPath,
      SymlinkSnapshotNode(
        linkTarget: toPosixLinkTarget(await readLinkTarget(path)),
      ),
    );

    return;
  }

  if (!stats.isFile) {
    throw DotweaveError('Unsupported filesystem entry: $path');
  }

  addSnapshotNode(
    snapshot,
    repoPath,
    FileSnapshotNode(
      contents: await File(path).readAsBytes(),
      executable: _resolveSnapshotExecutable(config, repoPath, stats.mode),
      secret: mode == 'secret',
    ),
  );
}

Future<void> _walkLocalDirectory(
  Map<String, SnapshotNode> snapshot,
  EffectiveSyncConfig config,
  String localDirectory,
  String repoPathPrefix,
  Set<String> childEntryPaths,
) async {
  final entries = await listDirectoryEntries(localDirectory);

  for (final entry in entries) {
    final localPath = p.join(localDirectory, entry.name);
    final repoPath = p.posix.join(repoPathPrefix, entry.name);

    if (childEntryPaths.contains(repoPath)) {
      continue;
    }

    if (entry.isDirectory) {
      assertStorageSafeRepoPath(repoPath);
      await _walkLocalDirectory(
        snapshot,
        config,
        localPath,
        repoPath,
        childEntryPaths,
      );
      continue;
    }

    if (entry.isSymbolicLink) {
      // The directory listing already told us this node is a symlink, which
      // is exactly what `getPathStats` would report (a symlink's `mode` is
      // always `0` and is never read), so no extra stat call is needed here.
      await _addLocalNode(
        snapshot,
        config,
        repoPath,
        localPath,
        const PathStats(
          isFile: false,
          isDirectory: false,
          isSymbolicLink: true,
          mode: 0,
        ),
      );
      continue;
    }

    // Files (and any other node kind) still need a stat call: `mode` is not
    // available from the directory listing.
    final stats = (await getPathStats(localPath))!;

    await _addLocalNode(snapshot, config, repoPath, localPath, stats);
  }
}

Future<Map<String, SnapshotNode>> buildLocalSnapshot(
  EffectiveSyncConfig config,
) async {
  final snapshot = <String, SnapshotNode>{};
  final queryConfig = _toResolvedSyncConfig(config);

  for (final entry in config.entries) {
    final stats = await getPathStats(entry.localPath);

    if (stats == null) {
      continue;
    }

    final entryMode = requireManagedSyncMode(
      queryConfig,
      entry.repoPath,
      config.activeProfile,
    );

    if (entry.kind == 'file') {
      if (entryMode == 'ignore') {
        continue;
      }

      if (stats.isDirectory) {
        throw DotweaveError(
          'Sync entry ${entry.repoPath} expects a file, but found a '
          'directory: ${entry.localPath}',
        );
      }

      await _addLocalNode(
        snapshot,
        config,
        entry.repoPath,
        entry.localPath,
        stats,
      );
      continue;
    }

    if (!stats.isDirectory) {
      throw DotweaveError(
        'Sync entry ${entry.repoPath} expects a directory: ${entry.localPath}',
      );
    }

    final childEntryPaths = Set<String>.of(
      collectChildEntryPaths(queryConfig, entry),
    );

    if (entryMode == 'ignore') {
      continue;
    }

    await _walkLocalDirectory(
      snapshot,
      config,
      entry.localPath,
      entry.repoPath,
      childEntryPaths,
    );
    addSnapshotNode(snapshot, entry.repoPath, const DirectorySnapshotNode());
  }

  return snapshot;
}
