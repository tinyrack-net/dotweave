import 'dart:io';

import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/config_file.dart';
import 'package:dotweave/src/services/repo_artifact_path.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/services/sync_paths.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/untrack.ts`: removal of a tracked entry from the
// manifest plus cleanup of its repository artifacts.

/// Mirror of the TS `UntrackRequest` readonly object.
class UntrackRequest {
  const UntrackRequest({required this.target});

  final String target;
}

/// Mirror of the TS `UntrackResult` readonly object.
class UntrackResult {
  const UntrackResult({
    required this.localPath,
    required this.plainArtifactCount,
    required this.repoPath,
    required this.secretArtifactCount,
  });

  final String localPath;
  final int plainArtifactCount;
  final String repoPath;
  final int secretArtifactCount;

  @override
  bool operator ==(Object other) {
    return other is UntrackResult &&
        other.localPath == localPath &&
        other.plainArtifactCount == plainArtifactCount &&
        other.repoPath == repoPath &&
        other.secretArtifactCount == secretArtifactCount;
  }

  @override
  int get hashCode =>
      Object.hash(localPath, plainArtifactCount, repoPath, secretArtifactCount);

  @override
  String toString() {
    return 'UntrackResult(localPath: $localPath, '
        'plainArtifactCount: $plainArtifactCount, repoPath: $repoPath, '
        'secretArtifactCount: $secretArtifactCount)';
  }
}

/// Optional overrides for [untrackTarget], standing in for the vitest module
/// mocks used by `untrack.test.ts`.
class UntrackDependencies {
  const UntrackDependencies({
    this.buildSyncConfigDocument,
    this.loadWritableSyncConfig,
    this.resolveTrackedEntry,
    this.writeValidatedSyncConfig,
  });

  final RawSyncConfig Function(ResolvedSyncConfig config)?
  buildSyncConfigDocument;
  final Future<WritableSyncConfig> Function()? loadWritableSyncConfig;
  final ResolvedSyncConfigEntry? Function(
    String target,
    List<ResolvedSyncConfigEntry> entries,
    String cwd,
    String homeDirectory,
  )?
  resolveTrackedEntry;
  final Future<void> Function(String syncDirectory, RawSyncConfig config)?
  writeValidatedSyncConfig;
}

/// Mirror of the mutable `counts` object threaded through the TS
/// `collectRepoArtifactCounts`.
class _ArtifactCounts {
  int plain = 0;
  int secret = 0;
}

Future<void> _collectRepoArtifactCounts(
  String targetPath,
  _ArtifactCounts counts,
  String relativePath,
) async {
  final stats = await getPathStats(targetPath);

  if (stats == null) {
    return;
  }

  if (stats.isDirectory) {
    counts.plain += 1;

    final entries = await listDirectoryEntries(targetPath);

    for (final entry in entries) {
      await _collectRepoArtifactCounts(
        p.join(targetPath, entry.name),
        counts,
        p.posix.join(relativePath, entry.name),
      );
    }

    return;
  }

  if (isSecretArtifactPath(relativePath)) {
    counts.secret += 1;
  } else {
    counts.plain += 1;
  }
}

Future<({int plainArtifactCount, int secretArtifactCount})>
_collectEntryArtifactCounts(
  String syncDirectory,
  ResolvedSyncConfigEntry entry,
) async {
  final artifactsRoot = syncDirectory;
  final counts = _ArtifactCounts();
  final artifactProfiles = collectArtifactProfiles(
    entries: <ResolvedSyncConfigEntry>[entry],
  );

  for (final profile in artifactProfiles) {
    final plainRelativePath = resolveArtifactRelativePath(
      category: 'plain',
      profile: profile,
      repoPath: entry.repoPath,
    );

    await _collectRepoArtifactCounts(
      p.joinAll([artifactsRoot, ...plainRelativePath.split('/')]),
      counts,
      plainRelativePath,
    );

    if (entry.kind != 'directory') {
      final secretRelativePath = resolveArtifactRelativePath(
        category: 'secret',
        profile: profile,
        repoPath: entry.repoPath,
      );

      await _collectRepoArtifactCounts(
        p.joinAll([artifactsRoot, ...secretRelativePath.split('/')]),
        counts,
        secretRelativePath,
      );

      final symlinkRelativePath = resolveArtifactRelativePath(
        category: 'plain',
        kind: 'symlink',
        profile: profile,
        repoPath: entry.repoPath,
      );

      await _collectRepoArtifactCounts(
        p.joinAll([artifactsRoot, ...symlinkRelativePath.split('/')]),
        counts,
        symlinkRelativePath,
      );
    }
  }

  return (plainArtifactCount: counts.plain, secretArtifactCount: counts.secret);
}

Future<void> _pruneEmptyParentDirectories(
  String startPath,
  String rootPath,
) async {
  var currentPath = startPath;

  while (isPathEqualOrNested(currentPath, rootPath) &&
      currentPath != rootPath) {
    final stats = await getPathStats(currentPath);

    if (stats == null) {
      currentPath = p.dirname(currentPath);
      continue;
    }

    if (!stats.isDirectory) {
      break;
    }

    final entries = await listDirectoryEntries(currentPath);

    if (entries.isNotEmpty) {
      break;
    }

    try {
      await Directory(currentPath).delete(recursive: true);
    } on PathNotFoundException {
      // Mirrors node:fs `rm` with `force: true`: missing paths are ignored.
    }
    currentPath = p.dirname(currentPath);
  }
}

Future<void> _removeTrackedEntryArtifacts(
  String syncDirectory,
  ResolvedSyncConfigEntry entry,
) async {
  final artifactsRoot = syncDirectory;
  final artifactProfiles = collectArtifactProfiles(
    entries: <ResolvedSyncConfigEntry>[entry],
  );

  for (final profile in artifactProfiles) {
    final plainPath = p.joinAll([
      artifactsRoot,
      ...resolveArtifactRelativePath(
        category: 'plain',
        profile: profile,
        repoPath: entry.repoPath,
      ).split('/'),
    ]);

    await removePathAtomically(plainPath);
    await _pruneEmptyParentDirectories(p.dirname(plainPath), artifactsRoot);

    if (entry.kind != 'directory') {
      final secretPath = p.joinAll([
        artifactsRoot,
        ...resolveArtifactRelativePath(
          category: 'secret',
          profile: profile,
          repoPath: entry.repoPath,
        ).split('/'),
      ]);

      await removePathAtomically(secretPath);
      await _pruneEmptyParentDirectories(p.dirname(secretPath), artifactsRoot);

      final symlinkPath = p.joinAll([
        artifactsRoot,
        ...resolveArtifactRelativePath(
          category: 'plain',
          kind: 'symlink',
          profile: profile,
          repoPath: entry.repoPath,
        ).split('/'),
      ]);

      await removePathAtomically(symlinkPath);
      await _pruneEmptyParentDirectories(p.dirname(symlinkPath), artifactsRoot);
    }
  }
}

Future<UntrackResult> untrackTarget(
  UntrackRequest request,
  String cwd, [
  UntrackDependencies dependencies = const UntrackDependencies(),
]) async {
  final effectiveLoadWritableSyncConfig =
      dependencies.loadWritableSyncConfig ?? loadWritableSyncConfig;
  final effectiveResolveTrackedEntry =
      dependencies.resolveTrackedEntry ?? resolveTrackedEntry;
  final effectiveBuildSyncConfigDocument =
      dependencies.buildSyncConfigDocument ?? buildSyncConfigDocument;
  final effectiveWriteValidatedSyncConfig =
      dependencies.writeValidatedSyncConfig ?? writeValidatedSyncConfig;

  final target = request.target.trim();

  if (target.isEmpty) {
    throw DotweaveError('Target path is required.');
  }

  final writable = await effectiveLoadWritableSyncConfig();
  final config = writable.config;
  final context = writable.context;
  final syncDirectory = writable.syncDirectory;
  final entry = effectiveResolveTrackedEntry(
    target,
    config.entries,
    cwd,
    context.homeDirectory,
  );

  if (entry == null) {
    throw DotweaveError('No tracked sync entry matches: $target');
  }

  final counts = await _collectEntryArtifactCounts(syncDirectory, entry);
  final nextConfig = effectiveBuildSyncConfigDocument(
    ResolvedSyncConfig(
      age: config.age,
      entries: [
        for (final configEntry in config.entries)
          if (configEntry.repoPath != entry.repoPath) configEntry,
      ],
      profiles: config.profiles,
      repositoryFormat: config.repositoryFormat,
      version: config.version,
    ),
  );

  await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);
  await _removeTrackedEntryArtifacts(syncDirectory, entry);

  return UntrackResult(
    localPath: entry.localPath,
    plainArtifactCount: counts.plainArtifactCount,
    repoPath: entry.repoPath,
    secretArtifactCount: counts.secretArtifactCount,
  );
}
