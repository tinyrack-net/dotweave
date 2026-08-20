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

/// Every repository path [entry] is configured to use, across all platform
/// keys -- not only the one that resolves on this platform.
///
/// Falls back to the platform-resolved [ResolvedSyncConfigEntry.repoPath] when
/// the manifest omits `repoPath`. That case is not a loss of information: the
/// path is then derived from `localPath.default` and is identical on every
/// platform.
///
/// Iterating the raw values rather than [PlatformKey.values] is deliberate.
/// The WSL -> linux -> default fallback can only ever land on one of these five
/// values, and unlike the ownership checks in `services/repo_artifacts.dart`
/// this list is never paired with a per-platform mode, so the platform a value
/// came from does not matter.
///
/// [normalizeSyncRepoPath] can throw, but not from here in production:
/// `parseSyncConfig` normalizes every variant while building the entry, so a
/// malformed value fails there first.
List<String> collectConfiguredRepoPathVariants(ResolvedSyncConfigEntry entry) {
  final configuredRepoPath = entry.configuredRepoPath;

  if (configuredRepoPath == null) {
    return [entry.repoPath];
  }

  final rawValues = <String>{
    configuredRepoPath.defaultValue,
    if (configuredRepoPath.win != null) configuredRepoPath.win!,
    if (configuredRepoPath.mac != null) configuredRepoPath.mac!,
    if (configuredRepoPath.linux != null) configuredRepoPath.linux!,
    if (configuredRepoPath.wsl != null) configuredRepoPath.wsl!,
  };

  return [for (final value in rawValues) normalizeSyncRepoPath(value)];
}

/// The repository path [parent] would assign to [child]'s local file.
///
/// Deliberately reads the platform-resolved `localPath` of both entries and
/// does not enumerate `configuredLocalPath` variants the way
/// [collectConfiguredRepoPathVariants] does for repo paths. The asymmetry is
/// the point: a repository path is shared across machines, so another
/// platform's variant belongs to that platform and must be left alone. A local
/// path is per-machine, so another platform's local name appearing on *this*
/// machine is just an ordinary file the parent should own.
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
///
/// A child claims every repository path it is *configured* to use, not only
/// the one that resolves here. Claiming just the resolved path leaves the
/// other platforms' variants unowned, so a directory parent containing them
/// adopts them: `pull` materializes another machine's artifact into HOME, and
/// `push` overwrites the artifact that machine stored. The child's own `mode`
/// cannot prevent either, because on the parent's side the path belongs to the
/// parent.
Set<String> collectChildEntryPaths(ResolvedSyncConfig config, Object parent) {
  final parentRepoPath = parent is String
      ? parent
      : (parent as ResolvedSyncConfigEntry).repoPath;
  final parentEntry = parent is String
      ? null
      : parent as ResolvedSyncConfigEntry;
  final childPaths = <String>{};

  for (final entry in config.entries) {
    // Guards the variant scan too, not just the local-path shadow below. A
    // parent whose own repoPath varies per platform would otherwise claim its
    // other variants as children of itself and refuse to materialize anything
    // under them.
    if (identical(entry, parentEntry)) {
      continue;
    }

    for (final repoPath in collectConfiguredRepoPathVariants(entry)) {
      // Plain `startsWith`, matching `_matchesEntryPath` above rather than
      // `isPathEqualOrNested`: this set is consumed alongside
      // `findOwningSyncEntry`, and a claim built with a different subtree rule
      // would disagree with it about what the parent owns. `isPathEqualOrNested`
      // also routes through the host path context, which applies Windows
      // case-insensitivity to what are POSIX repository paths.
      if (repoPath != parentRepoPath &&
          repoPath.startsWith('$parentRepoPath/')) {
        childPaths.add(repoPath);
      }
    }

    if (parentEntry == null) {
      continue;
    }

    final localChildRepoPath = _resolveLocalChildRepoPath(parentEntry, entry);

    if (localChildRepoPath != null) {
      childPaths.add(localChildRepoPath);
    }
  }

  return childPaths;
}

/// Whether [repoPath] is one of [claims] or sits underneath one.
///
/// [collectChildEntryPaths] returns the claimed paths themselves, so an exact
/// membership test is enough for the current platform: a directory child's
/// contents are excluded from the parent by [findOwningSyncEntry], which
/// resolves them to the child. Another platform's variant gets no such help --
/// nothing resolves to it here -- so its contents need the subtree test.
bool isClaimedChildPath(Set<String> claims, String repoPath) {
  if (claims.contains(repoPath)) {
    return true;
  }

  for (final claim in claims) {
    if (repoPath.startsWith('$claim/')) {
      return true;
    }
  }

  return false;
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
