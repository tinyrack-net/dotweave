import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/config/xdg.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/path_util.dart';
import 'package:dotweave/src/services/config_file.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/services/sync_paths.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/sync-mode.ts`: sync-mode target resolution and the
// `dotweave mode` set operation on the manifest.

/// Mirror of the TS `SetModeRequest` readonly object.
class SetModeRequest {
  const SetModeRequest({required this.mode, required this.target});

  final SyncMode mode;
  final String target;
}

/// Mirror of the non-exported TS `SyncSetAction` union:
/// `added` | `removed` | `unchanged` | `updated`.
typedef SyncSetAction = String;

/// Mirror of the non-exported TS `SyncSetReason` union: `already-set`.
typedef SyncSetReason = String;

/// Mirror of the TS `SetModeResult` readonly object.
class SetModeResult {
  const SetModeResult({
    required this.action,
    required this.entryRepoPath,
    required this.localPath,
    required this.mode,
    required this.repoPath,
    this.reason,
  });

  final SyncSetAction action;
  final String entryRepoPath;
  final String localPath;
  final SyncMode mode;
  final String repoPath;
  final SyncSetReason? reason;

  @override
  bool operator ==(Object other) {
    return other is SetModeResult &&
        other.action == action &&
        other.entryRepoPath == entryRepoPath &&
        other.localPath == localPath &&
        other.mode == mode &&
        other.repoPath == repoPath &&
        other.reason == reason;
  }

  @override
  int get hashCode =>
      Object.hash(action, entryRepoPath, localPath, mode, repoPath, reason);

  @override
  String toString() {
    return 'SetModeResult(action: $action, entryRepoPath: $entryRepoPath, '
        'localPath: $localPath, mode: $mode, repoPath: $repoPath'
        '${reason == null ? '' : ', reason: $reason'})';
  }
}

/// Mirror of the anonymous object returned by the TS `resolveSetTarget`.
typedef SetModeTarget = ({
  ResolvedSyncConfigEntry entry,
  String localPath,
  String relativePath,
  String repoPath,
  PathStats? stats,
});

/// Optional overrides for [resolveSetTarget] and [setTargetMode], standing in
/// for the vitest module mocks used by `sync-mode.test.ts`.
class SyncModeDependencies {
  const SyncModeDependencies({
    this.buildConfiguredHomeLocalPath,
    this.buildDefaultPlatformMode,
    this.buildRepoPathWithinRoot,
    this.buildSyncConfigDocument,
    this.expandHomePath,
    this.findOwningSyncEntry,
    this.getPathStats,
    this.hasPlatformSpecificModeOverride,
    this.isExplicitLocalPath,
    this.loadWritableSyncConfig,
    this.normalizeSyncRepoPath,
    this.resolveEntryRelativeRepoPath,
    this.tryBuildRepoPathWithinRoot,
    this.tryNormalizeRepoPathInput,
    this.writeValidatedSyncConfig,
  });

  final PlatformStringValue Function(String repoPath)?
  buildConfiguredHomeLocalPath;
  final PlatformSyncMode Function(SyncMode mode)? buildDefaultPlatformMode;
  final String Function(
    String absolutePath,
    String rootPath,
    String description,
  )?
  buildRepoPathWithinRoot;
  final RawSyncConfig Function(ResolvedSyncConfig config)?
  buildSyncConfigDocument;
  final String Function(String value, String? home)? expandHomePath;
  final ResolvedSyncConfigEntry? Function(
    ResolvedSyncConfig config,
    String repoPath,
  )?
  findOwningSyncEntry;
  final Future<PathStats?> Function(String path)? getPathStats;
  final bool Function(PlatformSyncMode configuredMode)?
  hasPlatformSpecificModeOverride;
  final bool Function(String target)? isExplicitLocalPath;
  final Future<WritableSyncConfig> Function()? loadWritableSyncConfig;
  final String Function(String value)? normalizeSyncRepoPath;
  final String? Function(ResolvedSyncConfigEntry entry, String repoPath)?
  resolveEntryRelativeRepoPath;
  final String? Function(
    String absolutePath,
    String rootPath,
    String description,
  )?
  tryBuildRepoPathWithinRoot;
  final String? Function(String value)? tryNormalizeRepoPathInput;
  final Future<void> Function(String syncDirectory, RawSyncConfig config)?
  writeValidatedSyncConfig;
}

/// Mirrors node:path `resolve` using the platform-native path context.
String _resolvePath(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

PlatformStringValue _buildDefaultConfiguredRepoPath(
  String repoPath,
  String Function(String value) normalizeSyncRepoPathFn,
) {
  return PlatformStringValue(defaultValue: normalizeSyncRepoPathFn(repoPath));
}

String _computeLocalPath(
  ResolvedSyncConfigEntry entry,
  String repoPath,
  String? Function(ResolvedSyncConfigEntry entry, String repoPath)
  resolveEntryRelativeRepoPathFn,
) {
  final relativePath = resolveEntryRelativeRepoPathFn(entry, repoPath);
  if (relativePath == null || relativePath == '') {
    return entry.localPath;
  }
  return p.joinAll([entry.localPath, ...relativePath.split('/')]);
}

String? _resolveRelativeLocalPath(String rootPath, String targetPath) {
  final String relativePath;

  try {
    relativePath = p.relative(targetPath, from: rootPath);
  } on p.PathException {
    // node:path `relative` returns the absolute target when no relative path
    // exists (e.g. across Windows drives), which fails the checks below;
    // package:path throws instead.
    return null;
  }

  // node:path `relative` returns '' for identical paths; package:path
  // returns '.'.
  if (relativePath == '' || relativePath == '.') {
    return '';
  }

  if (p.isAbsolute(relativePath) ||
      relativePath.startsWith('..') ||
      relativePath == '..') {
    return null;
  }

  return relativePath.replaceAll(r'\', '/');
}

ResolvedSyncConfigEntry? _findOwningLocalEntry(
  ResolvedSyncConfig config,
  String localPath,
) {
  ResolvedSyncConfigEntry? best;

  for (final entry in config.entries) {
    if (entry.kind != 'directory') {
      continue;
    }

    final relativeLocalPath = _resolveRelativeLocalPath(
      entry.localPath,
      localPath,
    );

    if (relativeLocalPath == null ||
        relativeLocalPath == '' ||
        (best != null && entry.localPath.length <= best.localPath.length)) {
      continue;
    }

    best = entry;
  }

  return best;
}

Future<SetModeTarget> resolveSetTarget(
  String target,
  ResolvedSyncConfig config,
  String cwd,
  String homeDirectory, [
  SyncModeDependencies dependencies = const SyncModeDependencies(),
]) async {
  final effectiveIsExplicitLocalPath =
      dependencies.isExplicitLocalPath ?? isExplicitLocalPath;
  final effectiveExpandHomePath = dependencies.expandHomePath ?? expandHomePath;
  final effectiveBuildRepoPathWithinRoot =
      dependencies.buildRepoPathWithinRoot ?? buildRepoPathWithinRoot;
  final effectiveTryBuildRepoPathWithinRoot =
      dependencies.tryBuildRepoPathWithinRoot ?? tryBuildRepoPathWithinRoot;
  final effectiveTryNormalizeRepoPathInput =
      dependencies.tryNormalizeRepoPathInput ?? tryNormalizeRepoPathInput;
  final effectiveGetPathStats = dependencies.getPathStats ?? getPathStats;
  final effectiveFindOwningSyncEntry =
      dependencies.findOwningSyncEntry ?? findOwningSyncEntry;
  final effectiveResolveEntryRelativeRepoPath =
      dependencies.resolveEntryRelativeRepoPath ?? resolveEntryRelativeRepoPath;

  final trimmedTarget = target.trim();

  if (trimmedTarget.isEmpty) {
    throw DotweaveError(
      'Target path is required.',
      code: 'TARGET_REQUIRED',
      hint:
          'Pass a tracked path, for example '
          "'dotweave mode ~/.ssh/id_ed25519 secret'.",
    );
  }

  final explicit = effectiveIsExplicitLocalPath(trimmedTarget);
  final localTargetPath = _resolvePath([
    cwd,
    effectiveExpandHomePath(trimmedTarget, homeDirectory),
  ]);
  final localRepoPath = explicit
      ? effectiveBuildRepoPathWithinRoot(
          localTargetPath,
          homeDirectory,
          'Sync set target',
        )
      : effectiveTryBuildRepoPathWithinRoot(
          localTargetPath,
          homeDirectory,
          'Sync set target',
        );

  // Phase 1: Try resolving as a local path
  if (localRepoPath != null) {
    final localStats = await effectiveGetPathStats(localTargetPath);

    if (explicit && localStats == null) {
      throw DotweaveError(
        'Sync set target does not exist.',
        code: 'TARGET_NOT_FOUND',
        details: ['Target: $localTargetPath'],
        hint:
            'Use an existing local path, or pass a repository path inside a '
            'tracked directory.',
      );
    }

    ResolvedSyncConfigEntry? exactEntry;
    for (final e in config.entries) {
      if (e.repoPath == localRepoPath) {
        exactEntry = e;
        break;
      }
    }

    if (exactEntry != null) {
      final localPath = _computeLocalPath(
        exactEntry,
        localRepoPath,
        effectiveResolveEntryRelativeRepoPath,
      );

      return (
        entry: exactEntry,
        localPath: localPath,
        relativePath: '',
        repoPath: localRepoPath,
        stats: localPath == localTargetPath
            ? localStats
            : await effectiveGetPathStats(localPath),
      );
    }

    final parentEntry = effectiveFindOwningSyncEntry(config, localRepoPath);

    if (parentEntry?.kind == 'directory') {
      final relativePath = effectiveResolveEntryRelativeRepoPath(
        parentEntry!,
        localRepoPath,
      );

      if (relativePath != null) {
        final localPath = _computeLocalPath(
          parentEntry,
          localRepoPath,
          effectiveResolveEntryRelativeRepoPath,
        );

        return (
          entry: parentEntry,
          localPath: localPath,
          relativePath: relativePath,
          repoPath: localRepoPath,
          stats: localPath == localTargetPath
              ? localStats
              : await effectiveGetPathStats(localPath),
        );
      }
    }

    ResolvedSyncConfigEntry? exactLocalEntry;
    for (final entry in config.entries) {
      if (entry.localPath == localTargetPath) {
        exactLocalEntry = entry;
        break;
      }
    }

    if (exactLocalEntry != null) {
      return (
        entry: exactLocalEntry,
        localPath: localTargetPath,
        relativePath: '',
        repoPath: exactLocalEntry.repoPath,
        stats: localStats,
      );
    }

    final localParentEntry = _findOwningLocalEntry(config, localTargetPath);

    if (localParentEntry != null) {
      final relativePath = _resolveRelativeLocalPath(
        localParentEntry.localPath,
        localTargetPath,
      );

      if (relativePath != null && relativePath != '') {
        return (
          entry: localParentEntry,
          localPath: localTargetPath,
          relativePath: relativePath,
          repoPath: p.posix.join(localParentEntry.repoPath, relativePath),
          stats: localStats,
        );
      }
    }

    if (explicit) {
      throw DotweaveError(
        'Local set target is not inside a tracked directory entry.',
        code: 'TARGET_NOT_TRACKED',
        details: ['Target: $trimmedTarget'],
        hint:
            "Track the parent directory first with 'dotweave track', then "
            "use 'dotweave mode' on the child path.",
      );
    }
  }

  // Phase 2: Fallback to repo path resolution
  final repoPath = effectiveTryNormalizeRepoPathInput(trimmedTarget);

  if (repoPath == null) {
    throw DotweaveError(
      'Sync set target is not a valid local or repository path.',
      code: 'INVALID_SET_TARGET',
      details: ['Target: $trimmedTarget'],
      hint:
          'Use an absolute path, a cwd-relative path, or a repository path '
          "like '.config/tool/file.json'.",
    );
  }

  ResolvedSyncConfigEntry? exactEntry;
  for (final e in config.entries) {
    if (e.repoPath == repoPath) {
      exactEntry = e;
      break;
    }
  }

  if (exactEntry != null) {
    final localPath = _computeLocalPath(
      exactEntry,
      repoPath,
      effectiveResolveEntryRelativeRepoPath,
    );

    return (
      entry: exactEntry,
      localPath: localPath,
      relativePath: '',
      repoPath: repoPath,
      stats: await effectiveGetPathStats(localPath),
    );
  }

  final entry = effectiveFindOwningSyncEntry(config, repoPath);
  final relativePath = entry?.kind == 'directory'
      ? effectiveResolveEntryRelativeRepoPath(entry!, repoPath)
      : null;

  if (entry == null || relativePath == null) {
    throw DotweaveError(
      'Repository set target is not inside a tracked directory entry.',
      code: 'TARGET_NOT_TRACKED',
      details: ['Target: $trimmedTarget'],
      hint:
          'Use a repository path under an existing tracked directory, or '
          "track it first with 'dotweave track'.",
    );
  }

  final localPath = _computeLocalPath(
    entry,
    repoPath,
    effectiveResolveEntryRelativeRepoPath,
  );

  return (
    entry: entry,
    localPath: localPath,
    relativePath: relativePath,
    repoPath: repoPath,
    stats: await effectiveGetPathStats(localPath),
  );
}

Future<SetModeResult> setTargetMode(
  SetModeRequest request,
  String cwd, [
  SyncModeDependencies dependencies = const SyncModeDependencies(),
]) async {
  final effectiveLoadWritableSyncConfig =
      dependencies.loadWritableSyncConfig ?? loadWritableSyncConfig;
  final effectiveBuildDefaultPlatformMode =
      dependencies.buildDefaultPlatformMode ?? buildDefaultPlatformMode;
  final effectiveHasPlatformSpecificModeOverride =
      dependencies.hasPlatformSpecificModeOverride ??
      hasPlatformSpecificModeOverride;
  final effectiveBuildSyncConfigDocument =
      dependencies.buildSyncConfigDocument ?? buildSyncConfigDocument;
  final effectiveWriteValidatedSyncConfig =
      dependencies.writeValidatedSyncConfig ?? writeValidatedSyncConfig;
  final effectiveBuildConfiguredHomeLocalPath =
      dependencies.buildConfiguredHomeLocalPath ?? buildConfiguredHomeLocalPath;
  final effectiveNormalizeSyncRepoPath =
      dependencies.normalizeSyncRepoPath ?? normalizeSyncRepoPath;

  final writable = await effectiveLoadWritableSyncConfig();
  final config = writable.config;
  final context = writable.context;
  final syncDirectory = writable.syncDirectory;
  final target = await resolveSetTarget(
    request.target,
    config,
    cwd,
    context.homeDirectory,
    dependencies,
  );

  SetModeResult buildResult(SyncSetAction action, {SyncSetReason? reason}) {
    return SetModeResult(
      action: action,
      entryRepoPath: target.entry.repoPath,
      localPath: target.localPath,
      mode: request.mode,
      repoPath: target.repoPath,
      reason: reason,
    );
  }

  if (target.relativePath == '') {
    final nextConfiguredMode = effectiveBuildDefaultPlatformMode(request.mode);
    final action =
        target.entry.mode == request.mode &&
            target.entry.configuredMode.defaultValue == request.mode &&
            !effectiveHasPlatformSpecificModeOverride(
              target.entry.configuredMode,
            )
        ? 'unchanged'
        : 'updated';
    final nextConfig = effectiveBuildSyncConfigDocument(
      ResolvedSyncConfig(
        age: config.age,
        entries: [
          for (final entry in config.entries)
            if (entry.repoPath != target.entry.repoPath)
              entry
            else
              ResolvedSyncConfigEntry(
                configuredMode: nextConfiguredMode,
                configuredLocalPath: entry.configuredLocalPath,
                configuredPermission: entry.configuredPermission,
                configuredRepoPath: entry.configuredRepoPath,
                kind: entry.kind,
                localPath: entry.localPath,
                profiles: entry.profiles,
                profilesExplicit: entry.profilesExplicit,
                mode: request.mode,
                modeExplicit: entry.modeExplicit,
                permission: entry.permission,
                permissionExplicit: entry.permissionExplicit,
                repoPath: entry.repoPath,
              ),
        ],
        profiles: config.profiles,
        repositoryFormat: config.repositoryFormat,
        version: config.version,
      ),
    );

    if (action != 'unchanged') {
      await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);
    }

    return buildResult(action);
  }

  final childKind = (target.stats?.isDirectory ?? false) ? 'directory' : 'file';
  final childRepoPath = target.repoPath;
  final childLocalRelativePath = _resolveRelativeLocalPath(
    context.homeDirectory,
    target.localPath,
  );

  if (childLocalRelativePath == null || childLocalRelativePath == '') {
    throw DotweaveError(
      'Sync set target must stay inside the configured home root.',
      code: 'TARGET_OUTSIDE_ROOT',
      details: [
        'Target: ${target.localPath}',
        'Allowed root: ${context.homeDirectory}',
      ],
      hint: 'Use a path inside ${context.homeDirectory}.',
    );
  }

  final childConfiguredLocalPath = effectiveBuildConfiguredHomeLocalPath(
    childLocalRelativePath,
  );
  final childConfiguredRepoPath = childRepoPath == childLocalRelativePath
      ? null
      : childRepoPath;

  ResolvedSyncConfigEntry? existingChild;
  for (final e in config.entries) {
    if (e.repoPath == childRepoPath) {
      existingChild = e;
      break;
    }
  }

  if (existingChild != null) {
    if (existingChild.mode == request.mode &&
        existingChild.configuredMode.defaultValue == request.mode &&
        !effectiveHasPlatformSpecificModeOverride(
          existingChild.configuredMode,
        )) {
      return buildResult('unchanged', reason: 'already-set');
    }

    final nextConfiguredMode = effectiveBuildDefaultPlatformMode(request.mode);

    final nextConfig = effectiveBuildSyncConfigDocument(
      ResolvedSyncConfig(
        age: config.age,
        entries: [
          for (final entry in config.entries)
            if (entry.repoPath != childRepoPath)
              entry
            else
              ResolvedSyncConfigEntry(
                configuredMode: nextConfiguredMode,
                configuredLocalPath: entry.configuredLocalPath,
                configuredPermission: entry.configuredPermission,
                configuredRepoPath: entry.configuredRepoPath,
                kind: entry.kind,
                localPath: entry.localPath,
                profiles: entry.profiles,
                profilesExplicit: entry.profilesExplicit,
                mode: request.mode,
                modeExplicit: entry.modeExplicit,
                permission: entry.permission,
                permissionExplicit: entry.permissionExplicit,
                repoPath: entry.repoPath,
              ),
        ],
        profiles: config.profiles,
        repositoryFormat: config.repositoryFormat,
        version: config.version,
      ),
    );

    await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);

    return buildResult('updated');
  }

  if (request.mode == target.entry.mode) {
    return buildResult('unchanged');
  }

  final newEntry = ResolvedSyncConfigEntry(
    configuredLocalPath: childConfiguredLocalPath,
    kind: childKind,
    localPath: target.localPath,
    configuredRepoPath: childConfiguredRepoPath == null
        ? null
        : _buildDefaultConfiguredRepoPath(
            childConfiguredRepoPath,
            effectiveNormalizeSyncRepoPath,
          ),
    profiles: [],
    profilesExplicit: false,
    mode: request.mode,
    modeExplicit: true,
    configuredMode: effectiveBuildDefaultPlatformMode(request.mode),
    permissionExplicit: false,
    repoPath: childRepoPath,
  );

  final nextConfig = effectiveBuildSyncConfigDocument(
    ResolvedSyncConfig(
      age: config.age,
      entries: [...config.entries, newEntry],
      profiles: config.profiles,
      repositoryFormat: config.repositoryFormat,
      version: config.version,
    ),
  );

  await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);

  return buildResult('added');
}
