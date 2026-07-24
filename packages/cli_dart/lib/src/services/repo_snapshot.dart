import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/crypto.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/file_mode.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/path_util.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/repo-snapshot.ts`: walks the repository artifact trees
// under profiles/<profile> into an in-memory snapshot map keyed by repository
// path. The TS `RepositorySnapshotConfig` alias of `EffectiveSyncConfig` is
// unexported, so the Dart port uses [EffectiveSyncConfig] directly.

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

bool _isActiveStorageProfile(
  String storageProfile,
  EffectiveSyncConfig config,
  String repoPath,
) {
  final rule = resolveSyncRule(
    _toResolvedSyncConfig(config),
    repoPath,
    config.activeProfile,
  );

  if (rule == null || rule.mode == 'ignore') {
    return false;
  }

  return rule.profile == storageProfile;
}

bool _resolveSnapshotExecutable(
  EffectiveSyncConfig config,
  String repoPath,
  int artifactMode,
) {
  final entry = findOwningSyncEntry(_toResolvedSyncConfig(config), repoPath);

  return isExecutableMode(entry?.permission ?? artifactMode);
}

Future<void> _readArtifactLeaf(
  String absolutePath,
  String storagePath,
  EffectiveSyncConfig config,
  Map<String, SnapshotNode> snapshot, [
  PathStats? providedStats,
]) async {
  final artifact = parseArtifactRelativePath(storagePath);

  if (!_isActiveStorageProfile(artifact.profile, config, artifact.repoPath)) {
    return;
  }

  assertStorageSafeRepoPath(artifact.repoPath);
  final queryConfig = _toResolvedSyncConfig(config);
  final rule = resolveSyncRule(
    queryConfig,
    artifact.repoPath,
    config.activeProfile,
  );

  if (rule == null) {
    throw DotweaveError(
      'Repository path is not managed by the current sync configuration.',
      code: 'UNMANAGED_SYNC_PATH',
      details: [
        'Repository path: ${artifact.repoPath}',
        'Context: $storagePath',
      ],
      hint:
          'Add the parent path to dotweave, or remove stray artifacts from '
          'the sync directory.',
    );
  }

  if (rule.profile != artifact.profile) {
    throw DotweaveError(
      'Repository artifact is stored under the wrong profile directory.',
      code: 'REPO_PROFILE_MISMATCH',
      details: [
        'Repository path: ${artifact.repoPath}',
        'Stored profile: ${artifact.profile}',
        'Expected profile: ${rule.profile}',
      ],
    );
  }

  if (rule.mode == 'ignore') {
    return;
  }

  // The walker already learned this path is not a directory (that's how it
  // routed here instead of recursing), so reuse its stat result instead of
  // re-deriving the same type/mode with a second full stat call.
  final stats = providedStats ?? (await getPathStats(absolutePath))!;

  if (artifact.secret) {
    if (rule.mode != 'secret') {
      throw DotweaveError(
        'Plain sync path is stored as a secret artifact in the repository.',
        code: 'PLAIN_STORED_SECRET',
        details: ['Repository path: $storagePath'],
      );
    }

    if (!stats.isFile) {
      throw DotweaveError(
        'Secret repository artifacts must be regular files, not symlinks.',
        code: 'SECRET_ARTIFACT_SYMLINK',
        details: ['Repository path: $storagePath'],
      );
    }

    final Uint8List contents;

    try {
      contents = await decryptSecretFile(
        await File(absolutePath).readAsString(),
        config.age.identityFile,
      );
    } on Object catch (error) {
      throw wrapUnknownError(
        'Failed to decrypt a secret repository artifact.',
        error,
        code: 'SECRET_ARTIFACT_DECRYPT_FAILED',
        details: [
          'Repository path: $storagePath',
          'Identity file: ${config.age.identityFile}',
        ],
      );
    }

    addSnapshotNode(
      snapshot,
      artifact.repoPath,
      FileSnapshotNode(
        contents: contents,
        executable: _resolveSnapshotExecutable(
          config,
          artifact.repoPath,
          stats.mode,
        ),
        secret: true,
      ),
    );

    return;
  }

  final mode = requireManagedSyncMode(
    queryConfig,
    artifact.repoPath,
    config.activeProfile,
    storagePath,
  );

  if (artifact.symlink) {
    if (mode == 'secret') {
      throw DotweaveError(
        'Secret sync path is stored as a plain artifact in the repository.',
        code: 'SECRET_STORED_PLAIN',
        details: ['Repository path: $storagePath'],
      );
    }

    if (!stats.isFile) {
      throw DotweaveError(
        'Symlink repository artifacts must be regular metadata files.',
        code: 'SYMLINK_ARTIFACT_NOT_FILE',
        details: ['Repository path: $storagePath'],
      );
    }

    addSnapshotNode(
      snapshot,
      artifact.repoPath,
      SymlinkSnapshotNode(
        linkTarget: toPosixLinkTarget(await File(absolutePath).readAsString()),
      ),
    );

    return;
  }

  if (stats.isSymbolicLink) {
    // Repository format 0 compatibility: symlinks stored as physical links
    // (pre-.dotweave.symlink). Still read them so format-0 repositories keep
    // working; `migrations/repo_format_v1.dart` rewrites them to the portable
    // metadata-file format on the next push.
    //
    // REMOVAL: when AppConstants.sync.minSupportedRepositoryFormat is raised
    // to 1, delete this branch together with repo_format_v1.dart and its
    // registry entry; format-0 repositories are then refused with
    // REPO_FORMAT_TOO_OLD.
    if (mode == 'secret') {
      throw DotweaveError(
        'Secret sync path is stored as a plain artifact in the repository.',
        code: 'SECRET_STORED_PLAIN',
        details: ['Repository path: $storagePath'],
      );
    }

    addSnapshotNode(
      snapshot,
      artifact.repoPath,
      SymlinkSnapshotNode(
        linkTarget: toPosixLinkTarget(await readLinkTarget(absolutePath)),
      ),
    );

    return;
  }

  if (!stats.isFile) {
    throw DotweaveError(
      'Repository contains an unsupported plain artifact type.',
      code: 'UNSUPPORTED_REPO_ENTRY',
      details: ['Repository path: $storagePath'],
    );
  }

  if (mode == 'secret') {
    throw DotweaveError(
      'Secret sync path is stored as a plain artifact in the repository.',
      code: 'SECRET_STORED_PLAIN',
      details: ['Repository path: $storagePath'],
    );
  }

  addSnapshotNode(
    snapshot,
    artifact.repoPath,
    FileSnapshotNode(
      contents: await File(absolutePath).readAsBytes(),
      executable: _resolveSnapshotExecutable(
        config,
        artifact.repoPath,
        stats.mode,
      ),
      secret: false,
    ),
  );
}

Future<void> _walkArtifactTree(
  String rootDirectory,
  EffectiveSyncConfig config,
  Map<String, SnapshotNode> snapshot, [
  String prefix = '',
]) async {
  final entries = await listDirectoryEntries(rootDirectory);

  for (final entry in entries) {
    final absolutePath = p.join(rootDirectory, entry.name);
    final storagePath = prefix == '' ? entry.name : '$prefix/${entry.name}';

    // The directory listing already tells us whether this entry is a
    // directory, so recursing needs no stat call at all here.
    if (entry.isDirectory) {
      await _walkArtifactTree(absolutePath, config, snapshot, storagePath);
      continue;
    }

    // Non-directories still need one stat call (for `mode`), but that result
    // is now threaded into `_readArtifactLeaf` so it doesn't re-derive the
    // same type/mode with a second full stat call on the same path.
    final stats = (await getPathStats(absolutePath))!;

    await _readArtifactLeaf(absolutePath, storagePath, config, snapshot, stats);
  }
}

Future<Map<String, SnapshotNode>> buildRepositorySnapshot(
  String syncDirectory,
  EffectiveSyncConfig config,
) async {
  final snapshot = <String, SnapshotNode>{};
  final artifactProfiles = collectArtifactProfiles(config);
  final committedProfiles = await readCommittedProfileRegistry(syncDirectory);

  if (committedProfiles != null) {
    for (final profile in committedProfiles) {
      artifactProfiles.add(profile);
    }
  }

  await Future.wait([
    for (final profile in artifactProfiles)
      () async {
        final profileDirectory = p.join(syncDirectory, 'profiles', profile);
        final profileStats = await getPathStats(profileDirectory);

        if (profileStats?.isDirectory ?? false) {
          await _walkArtifactTree(
            profileDirectory,
            config,
            snapshot,
            'profiles/$profile',
          );
        }
      }(),
  ]);

  final queryConfig = _toResolvedSyncConfig(config);

  for (final entry in config.entries) {
    if (entry.kind != 'directory') {
      continue;
    }

    final rule = resolveSyncRule(
      queryConfig,
      entry.repoPath,
      config.activeProfile,
    );

    if (rule == null) {
      continue;
    }

    final hasTrackedChildren = snapshot.keys.any((repoPath) {
      return repoPath.startsWith('${entry.repoPath}/');
    });
    final expectedPath = p.joinAll([
      syncDirectory,
      ...resolveArtifactRelativePath(
        category: 'plain',
        profile: rule.profile,
        repoPath: entry.repoPath,
      ).split('/'),
    ]);
    final expectedStats = await getPathStats(expectedPath);

    if (expectedStats != null && !expectedStats.isDirectory) {
      throw DotweaveError(
        'Directory sync entry is not stored as a directory in the repository.',
        code: 'DIRECTORY_ENTRY_NOT_DIRECTORY',
        details: ['Repository path: ${entry.repoPath}'],
      );
    }

    if ((expectedStats?.isDirectory ?? false) &&
        (rule.mode != 'ignore' || hasTrackedChildren)) {
      addSnapshotNode(snapshot, entry.repoPath, const DirectorySnapshotNode());
    }
  }

  return snapshot;
}
