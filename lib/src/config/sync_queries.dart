import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:path/path.dart' as p;

// Mirror of `config/sync-queries.ts`.

// ---------------------------------------------------------------------------
// Entry lookup
// ---------------------------------------------------------------------------

/// Result shape of [resolveSyncRule], mirroring the TS inline
/// `{ mode: SyncMode; profile: string }` return type.
typedef SyncRule = ({SyncMode mode, String profile});

bool _matchesEntryPath(ResolvedSyncConfigEntry entry, String repoPath) {
  return entry.repoPath == repoPath ||
      (entry.kind == 'directory' && repoPath.startsWith('${entry.repoPath}/'));
}

ResolvedSyncConfigEntry? findOwningSyncEntry(
  ResolvedSyncConfig config,
  String repoPath,
) {
  ResolvedSyncConfigEntry? best;

  for (final entry in config.entries) {
    if (_matchesEntryPath(entry, repoPath) &&
        (best == null || entry.repoPath.length > best.repoPath.length)) {
      best = entry;
    }
  }

  return best;
}

bool _isNestedRelativePath(String path) {
  return path != '' &&
      !p.isAbsolute(path) &&
      path != '..' &&
      !path.startsWith('../') &&
      !path.startsWith(r'..\');
}

String? _resolveLocalChildRepoPath(
  ResolvedSyncConfigEntry parent,
  ResolvedSyncConfigEntry child,
) {
  if (parent.kind != 'directory') {
    return null;
  }

  final String relativeLocalPath;

  try {
    relativeLocalPath = p.relative(child.localPath, from: parent.localPath);
  } on p.PathException {
    // node:path `relative` returns the absolute target when no relative path
    // exists (e.g. across Windows drives), which fails the nested check
    // below; package:path throws instead.
    return null;
  }

  if (!_isNestedRelativePath(relativeLocalPath)) {
    return null;
  }

  return p.posix.normalize(
    p.posix.join(parent.repoPath, relativeLocalPath.replaceAll(r'\', '/')),
  );
}

/// The `parent` argument mirrors the TS `ChildEntryParent` union: either a
/// repo path [String] or a [ResolvedSyncConfigEntry].
Set<String> collectChildEntryPaths(ResolvedSyncConfig config, Object parent) {
  final parentRepoPath = parent is String
      ? parent
      : (parent as ResolvedSyncConfigEntry).repoPath;
  final parentEntry = parent is String
      ? null
      : parent as ResolvedSyncConfigEntry;
  final childPaths = <String>{};

  for (final entry in config.entries) {
    if (entry.repoPath != parentRepoPath &&
        entry.repoPath.startsWith('$parentRepoPath/')) {
      childPaths.add(entry.repoPath);
    }

    if (parentEntry == null || identical(entry, parentEntry)) {
      continue;
    }

    final localChildRepoPath = _resolveLocalChildRepoPath(parentEntry, entry);

    if (localChildRepoPath != null) {
      childPaths.add(localChildRepoPath);
    }
  }

  return childPaths;
}

String? resolveEntryRelativeRepoPath(
  ResolvedSyncConfigEntry entry,
  String repoPath,
) {
  if (entry.kind == 'file') {
    return repoPath == entry.repoPath ? '' : null;
  }

  if (repoPath == entry.repoPath) {
    return '';
  }

  if (!repoPath.startsWith('${entry.repoPath}/')) {
    return null;
  }

  return repoPath.substring(entry.repoPath.length + 1);
}

// ---------------------------------------------------------------------------
// Mode / rule resolution
// ---------------------------------------------------------------------------

String? _resolveProfileForEntry(
  ResolvedSyncConfigEntry entry,
  String? activeProfile,
) {
  if (entry.profiles.isEmpty) {
    return AppConstants.sync.defaultProfile;
  }

  final effective =
      activeProfile != null && activeProfile != AppConstants.sync.defaultProfile
      ? activeProfile
      : AppConstants.sync.defaultProfile;

  return entry.profiles.contains(effective) ? effective : null;
}

SyncRule? resolveSyncRule(
  ResolvedSyncConfig config,
  String repoPath, [
  String? activeProfile,
]) {
  final entry = findOwningSyncEntry(config, repoPath);

  if (entry == null) {
    return null;
  }

  final profile = _resolveProfileForEntry(entry, activeProfile);

  if (profile == null) {
    return null;
  }

  return (mode: entry.mode, profile: profile);
}

SyncMode? resolveSyncMode(
  ResolvedSyncConfig config,
  String repoPath, [
  String? activeProfile,
]) {
  return resolveSyncRule(config, repoPath, activeProfile)?.mode;
}

bool isIgnoredSyncPath(ResolvedSyncConfig config, String repoPath) {
  return resolveSyncMode(config, repoPath) == 'ignore';
}

bool isSecretSyncPath(ResolvedSyncConfig config, String repoPath) {
  return resolveSyncMode(config, repoPath) == 'secret';
}

SyncMode requireManagedSyncMode(
  ResolvedSyncConfig config,
  String repoPath, [
  String? activeProfile,
  String? context,
]) {
  final mode = resolveSyncMode(config, repoPath, activeProfile);

  if (mode == null) {
    throw DotweaveError(
      'Repository path is not managed by the current sync configuration.',
      code: 'UNMANAGED_SYNC_PATH',
      details: [
        'Repository path: $repoPath',
        if (context != null) 'Context: $context',
      ],
      hint:
          'Add the parent path to dotweave, or remove stray artifacts from '
          'the sync directory.',
    );
  }

  return mode;
}

// ---------------------------------------------------------------------------
// Profile collection
// ---------------------------------------------------------------------------

PlatformSyncMode buildDefaultPlatformMode(SyncMode mode) {
  return PlatformSyncMode(defaultValue: mode);
}

bool hasPlatformSpecificModeOverride(PlatformSyncMode configuredMode) {
  return configuredMode.win != null ||
      configuredMode.mac != null ||
      configuredMode.linux != null ||
      configuredMode.wsl != null;
}

List<String> collectAllProfileNames(List<ResolvedSyncConfigEntry> entries) {
  final profiles = <String>{};

  for (final entry in entries) {
    if (entry.profiles.isEmpty) {
      profiles.add(AppConstants.sync.defaultProfile);
      continue;
    }

    for (final profile in entry.profiles) {
      profiles.add(profile);
    }
  }

  return [...profiles]..sort(compareLocaleLike);
}
