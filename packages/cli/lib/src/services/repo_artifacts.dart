import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/collation.dart';
import 'package:dotweave/src/lib/concurrency.dart';
import 'package:dotweave/src/lib/content.dart';
import 'package:dotweave/src/lib/crypto.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/file_mode.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/git.dart';
import 'package:dotweave/src/lib/jsonc.dart';
import 'package:dotweave/src/lib/path_util.dart';
import 'package:dotweave/src/lib/perf_trace.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/repo-artifacts.ts`: the on-disk artifact contract under
// profiles/<profile>/<repoPath>, artifact key building/parsing, ownership
// classification, and artifact writing.

/// Mirror of the TS inline `Pick<ResolvedSyncConfig, "entries" | "profiles">`
/// parameter shape used for ownership decisions. Build one from either a
/// [ResolvedSyncConfig] or an [EffectiveSyncConfig] with
/// `(entries: config.entries, profiles: config.profiles)`.
typedef ArtifactOwnershipConfig = ({
  List<ResolvedSyncConfigEntry> entries,
  List<String>? profiles,
});

/// Mirror of the TS inline return shape of [parseArtifactRelativePath].
typedef ParsedArtifactPath = ({
  String profile,
  String repoPath,
  bool secret,
  bool symlink,
});

const String _physicalProfilesRoot = 'profiles';

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

bool _entryOwnsArtifactProfile(ResolvedSyncConfigEntry entry, String profile) {
  if (entry.profiles.isEmpty) {
    return profile == AppConstants.sync.defaultProfile;
  }

  return entry.profiles.contains(profile);
}

bool _isActiveArtifactRule(SyncRule? rule, String profile) {
  return rule != null && rule.mode != 'ignore' && rule.profile == profile;
}

/// Mirror of the TS `collectArtifactProfiles` union parameter, which is
/// either an entry list picking `profiles` or a config picking
/// `entries`/`profiles`: accepts a `List<ResolvedSyncConfigEntry>`, an
/// [ArtifactOwnershipConfig] record, an [EffectiveSyncConfig], or a
/// [ResolvedSyncConfig].
Set<String> collectArtifactProfiles(Object configOrEntries) {
  final profiles = <String>{};
  profiles.add(AppConstants.sync.defaultProfile);

  final List<ResolvedSyncConfigEntry> entries;
  final List<String> registeredProfiles;

  if (configOrEntries is List<ResolvedSyncConfigEntry>) {
    entries = configOrEntries;
    registeredProfiles = const [];
  } else if (configOrEntries is ArtifactOwnershipConfig) {
    entries = configOrEntries.entries;
    registeredProfiles = configOrEntries.profiles ?? const [];
  } else if (configOrEntries is EffectiveSyncConfig) {
    entries = configOrEntries.entries;
    registeredProfiles = configOrEntries.profiles ?? const [];
  } else if (configOrEntries is ResolvedSyncConfig) {
    entries = configOrEntries.entries;
    registeredProfiles = configOrEntries.profiles ?? const [];
  } else {
    throw ArgumentError.value(
      configOrEntries,
      'configOrEntries',
      'Expected a sync config or a list of sync entries',
    );
  }

  for (final profile in registeredProfiles) {
    profiles.add(profile);
  }

  for (final entry in entries) {
    for (final profile in entry.profiles) {
      profiles.add(profile);
    }
  }

  return profiles;
}

bool _isRawCommittedProfileName(String profile) {
  try {
    return normalizeSyncProfileName(profile) == profile;
  } catch (_) {
    return false;
  }
}

Set<String> _collectRawManifestProfiles(Object? manifest) {
  final profiles = <String>{};

  if (manifest is! Map<String, Object?>) {
    return profiles;
  }

  final registeredProfiles = manifest['profiles'];

  if (registeredProfiles is List<Object?>) {
    for (final profile in registeredProfiles) {
      if (profile is String && _isRawCommittedProfileName(profile)) {
        profiles.add(profile);
      }
    }
  }

  final entries = manifest['entries'];

  if (entries is List<Object?>) {
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) {
        continue;
      }

      final entryProfiles = entry['profiles'];

      if (entryProfiles is! List<Object?>) {
        continue;
      }

      for (final profile in entryProfiles) {
        if (profile is String && _isRawCommittedProfileName(profile)) {
          profiles.add(profile);
        }
      }
    }
  }

  profiles.add(AppConstants.sync.defaultProfile);

  return profiles;
}

/// Default `execFile` used by [readCommittedProfileRegistry], mirroring the
/// Node `promisify(execFile)` call shape.
Future<GitCommandResult> _execFileAsync(
  String file,
  List<String> args, {
  String? cwd,
}) async {
  final result = await Process.run(
    file,
    args,
    workingDirectory: cwd,
    runInShell: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final stdout = result.stdout as String;
  final stderr = result.stderr as String;

  if (result.exitCode != 0) {
    throw GitExecFileException(
      'Command failed: $file ${args.join(' ')}',
      stderr: stderr,
      stdout: stdout,
    );
  }

  return GitCommandResult(stderr: stderr, stdout: stdout);
}

/// Reads the profile registry from the committed manifest via
/// `git show HEAD:manifest.jsonc`, or `null` when it cannot be read. The
/// optional [dependencies] mirror the module-mock seam used in TS tests.
Future<Set<String>?> readCommittedProfileRegistry(
  String syncDirectory, [
  GitCommandDependencies? dependencies,
]) async {
  final execFileAsync = dependencies?.execFileAsync ?? _execFileAsync;

  try {
    final result = await execFileAsync('git', [
      'show',
      'HEAD:${AppConstants.sync.configFileName}',
    ], cwd: syncDirectory);

    return _collectRawManifestProfiles(parseJsonc(result.stdout));
  } catch (_) {
    return null;
  }
}

List<String> _collectConfiguredRepoPathVariants(ResolvedSyncConfigEntry entry) {
  final configuredRepoPath = entry.configuredRepoPath;

  if (configuredRepoPath == null) {
    return [entry.repoPath];
  }

  // Mirrors `[...new Set(Object.values(entry.configuredRepoPath))]`; the TS
  // object carries its keys in schema order (default, win, mac, linux, wsl).
  final rawValues = <String>{
    configuredRepoPath.defaultValue,
    if (configuredRepoPath.win != null) configuredRepoPath.win!,
    if (configuredRepoPath.mac != null) configuredRepoPath.mac!,
    if (configuredRepoPath.linux != null) configuredRepoPath.linux!,
    if (configuredRepoPath.wsl != null) configuredRepoPath.wsl!,
  };

  return [for (final value in rawValues) normalizeSyncRepoPath(value)];
}

bool _entryOwnsArtifactPath(ResolvedSyncConfigEntry entry, String repoPath) {
  return _collectConfiguredRepoPathVariants(entry).any((candidate) {
    return entry.kind == 'directory'
        ? isPathEqualOrNested(repoPath, candidate)
        : repoPath == candidate;
  });
}

List<({int depth, String repoPath})> _collectEntryRepoPathVariants(
  ResolvedSyncConfigEntry entry,
) {
  return [
    for (final repoPath in _collectConfiguredRepoPathVariants(entry))
      (depth: repoPath.split('/').length, repoPath: repoPath),
  ];
}

const List<PlatformKey> _platformKeys = ['win', 'mac', 'linux', 'wsl'];

SyncMode _resolveConfiguredModeForPlatform(
  PlatformSyncMode configuredMode,
  PlatformKey platformKey,
) {
  if (platformKey == 'wsl') {
    return configuredMode.wsl ??
        configuredMode.linux ??
        configuredMode.defaultValue;
  }

  switch (platformKey) {
    case 'win':
      return configuredMode.win ?? configuredMode.defaultValue;
    case 'mac':
      return configuredMode.mac ?? configuredMode.defaultValue;
    case 'linux':
      return configuredMode.linux ?? configuredMode.defaultValue;
    default:
      return configuredMode.defaultValue;
  }
}

String _resolveConfiguredRepoPathForPlatform(
  ResolvedSyncConfigEntry entry,
  PlatformKey platformKey,
) {
  final configuredRepoPath = entry.configuredRepoPath;

  if (configuredRepoPath == null) {
    return entry.repoPath;
  }

  // `resolvePlatformValue` implements the same lookup the TS code spells out
  // inline (wsl -> wsl ?? linux ?? default; otherwise platform ?? default).
  return normalizeSyncRepoPath(
    resolvePlatformValue(configuredRepoPath, platformKey),
  );
}

bool _entryCompatibleWithArtifact(
  ResolvedSyncConfigEntry entry,
  ParsedArtifactPath artifact,
  String artifactKind,
) {
  return _collectConfiguredRepoPathVariants(entry).any((candidate) {
    if (entry.kind == 'directory') {
      return isPathEqualOrNested(artifact.repoPath, candidate);
    }

    return artifactKind == 'file' && artifact.repoPath == candidate;
  });
}

ResolvedSyncConfigEntry? findNearestArtifactOwningEntry(
  List<ResolvedSyncConfigEntry> entries,
  ParsedArtifactPath artifact,
  String artifactKind,
) {
  ResolvedSyncConfigEntry? nearestEntry;
  var nearestDepth = -1;

  for (final entry in entries) {
    if (!_entryOwnsArtifactProfile(entry, artifact.profile)) {
      continue;
    }

    for (final variant in _collectEntryRepoPathVariants(entry)) {
      if (!isPathEqualOrNested(artifact.repoPath, variant.repoPath)) {
        continue;
      }

      if (variant.depth > nearestDepth) {
        nearestDepth = variant.depth;
        nearestEntry = entry;
      }
    }
  }

  return nearestEntry != null &&
          _entryCompatibleWithArtifact(nearestEntry, artifact, artifactKind)
      ? nearestEntry
      : null;
}

bool nearestEntryOwnsArtifact(
  List<ResolvedSyncConfigEntry> entries,
  ParsedArtifactPath artifact,
  String artifactKind,
) {
  return findNearestArtifactOwningEntry(entries, artifact, artifactKind) !=
      null;
}

bool _activeDirectoryEntryOwnsArtifact(
  List<ResolvedSyncConfigEntry> entries,
  ParsedArtifactPath artifact,
) {
  return entries.any((entry) {
    return entry.kind == 'directory' &&
        entry.mode != 'ignore' &&
        _entryOwnsArtifactProfile(entry, artifact.profile) &&
        _entryOwnsArtifactPath(entry, artifact.repoPath);
  });
}

/// Mirror of the TS `ArtifactOwnershipDisposition` union:
/// `active` | `platform-protected` | `ignored-prunable` | `unowned`.
typedef ArtifactOwnershipDisposition = String;

bool _entryOwnsArtifactForPlatform(
  ResolvedSyncConfigEntry entry,
  ParsedArtifactPath artifact,
  String artifactKind,
  PlatformKey platformKey,
) {
  final repoPath = _resolveConfiguredRepoPathForPlatform(entry, platformKey);

  if (entry.kind == 'directory') {
    return isPathEqualOrNested(artifact.repoPath, repoPath);
  }

  return artifactKind == 'file' && artifact.repoPath == repoPath;
}

bool _artifactHasAlternatePlatformOwner(
  ResolvedSyncConfigEntry entry,
  ParsedArtifactPath artifact,
  String artifactKind,
) {
  return _platformKeys.any((platformKey) {
    final mode = _resolveConfiguredModeForPlatform(
      entry.configuredMode,
      platformKey,
    );

    return mode != 'ignore' &&
        _entryOwnsArtifactForPlatform(
          entry,
          artifact,
          artifactKind,
          platformKey,
        );
  });
}

ArtifactOwnershipDisposition classifyArtifactOwnership(
  EffectiveSyncConfig config,
  ArtifactOwnershipConfig ownershipConfig,
  ParsedArtifactPath artifact,
  String artifactKind,
) {
  final rule = resolveSyncRule(
    _toResolvedSyncConfig(config),
    artifact.repoPath,
    config.activeProfile,
  );
  final active = artifactKind == 'directory'
      ? _activeDirectoryEntryOwnsArtifact(config.entries, artifact)
      : _isActiveArtifactRule(rule, artifact.profile);

  if (active) {
    return 'active';
  }

  final nearestEntry = findNearestArtifactOwningEntry(
    ownershipConfig.entries,
    artifact,
    artifactKind,
  );

  if (nearestEntry == null) {
    return 'unowned';
  }

  final effectiveActiveProfile =
      config.activeProfile ?? AppConstants.sync.defaultProfile;

  if (artifact.profile != effectiveActiveProfile) {
    return 'platform-protected';
  }

  if (nearestEntry.mode == 'ignore') {
    return _artifactHasAlternatePlatformOwner(
          nearestEntry,
          artifact,
          artifactKind,
        )
        ? 'platform-protected'
        : 'ignored-prunable';
  }

  return 'platform-protected';
}

bool entryOwnsArtifact(
  ResolvedSyncConfigEntry entry,
  ParsedArtifactPath artifact,
) {
  return _entryOwnsArtifactProfile(entry, artifact.profile) &&
      _entryOwnsArtifactPath(entry, artifact.repoPath);
}

/// Mirror of the TS `RepoArtifact` discriminated union. The `plain`/`secret`
/// file variants share the [FileRepoArtifact] class discriminated by
/// [RepoArtifact.category].
sealed class RepoArtifact {
  const RepoArtifact();

  /// TS discriminant: `plain` or `secret`.
  String get category;

  /// TS discriminant: `directory`, `file`, or `symlink`.
  String get kind;

  String get profile;
  String get repoPath;
}

/// The `plain`/`directory` variant of [RepoArtifact].
final class DirectoryRepoArtifact extends RepoArtifact {
  const DirectoryRepoArtifact({required this.profile, required this.repoPath});

  @override
  String get category => 'plain';

  @override
  String get kind => 'directory';

  @override
  final String profile;

  @override
  final String repoPath;
}

/// The `file` variants of [RepoArtifact]: [category] is `plain` or `secret`.
final class FileRepoArtifact extends RepoArtifact {
  const FileRepoArtifact({
    required this.category,
    required this.contents,
    required this.executable,
    required this.profile,
    required this.repoPath,
  });

  @override
  final String category;

  @override
  String get kind => 'file';

  final Uint8List contents;
  final bool executable;

  @override
  final String profile;

  @override
  final String repoPath;
}

/// The `plain`/`symlink` variant of [RepoArtifact].
final class SymlinkRepoArtifact extends RepoArtifact {
  const SymlinkRepoArtifact({
    required this.linkTarget,
    required this.profile,
    required this.repoPath,
  });

  @override
  String get category => 'plain';

  @override
  String get kind => 'symlink';

  final String linkTarget;

  @override
  final String profile;

  @override
  final String repoPath;
}

String buildArtifactKey(RepoArtifact artifact) {
  final relativePath = resolveArtifactLogicalPath(
    category: artifact.category,
    kind: artifact.kind,
    profile: artifact.profile,
    repoPath: artifact.repoPath,
  );

  return artifact.kind == 'directory'
      ? buildDirectoryKey(relativePath)
      : relativePath;
}

/// Mirror of the TS `resolveArtifactLogicalPath` whose parameter picks
/// `category`/`profile`/`repoPath` from `RepoArtifact` with an optional
/// `kind`; [kind] is optional accordingly.
String resolveArtifactLogicalPath({
  required String category,
  String? kind,
  required String profile,
  required String repoPath,
}) {
  final profileRelativePath = '$profile/$repoPath';

  if (kind == 'symlink') {
    return '$profileRelativePath${AppConstants.sync.symlinkArtifactSuffix}';
  }

  return category == 'secret'
      ? '$profileRelativePath${AppConstants.sync.secretArtifactSuffix}'
      : profileRelativePath;
}

bool isSecretArtifactPath(String relativePath) {
  return relativePath.endsWith(AppConstants.sync.secretArtifactSuffix);
}

String? stripSecretArtifactSuffix(String relativePath) {
  if (!isSecretArtifactPath(relativePath)) {
    return null;
  }

  return relativePath.substring(
    0,
    relativePath.length - AppConstants.sync.secretArtifactSuffix.length,
  );
}

bool isSymlinkArtifactPath(String relativePath) {
  return relativePath.endsWith(AppConstants.sync.symlinkArtifactSuffix);
}

String? stripSymlinkArtifactSuffix(String relativePath) {
  if (!isSymlinkArtifactPath(relativePath)) {
    return null;
  }

  return relativePath.substring(
    0,
    relativePath.length - AppConstants.sync.symlinkArtifactSuffix.length,
  );
}

void assertStorageSafeRepoPath(String repoPath) {
  if (!hasReservedSyncArtifactSuffixSegment(repoPath)) {
    return;
  }

  throw DotweaveError(
    'Tracked sync paths must not use the reserved suffixes '
    '${AppConstants.sync.secretArtifactSuffix} or '
    '${AppConstants.sync.symlinkArtifactSuffix}.',
    code: 'RESERVED_ARTIFACT_SUFFIX',
    details: ['Repository path: $repoPath'],
    hint:
        'Rename the tracked path so no segment ends with a reserved artifact '
        'suffix.',
  );
}

/// Mirror of the TS `resolveArtifactRelativePath`; see
/// [resolveArtifactLogicalPath] for the parameter shape.
String resolveArtifactRelativePath({
  required String category,
  String? kind,
  required String profile,
  required String repoPath,
}) {
  final logicalPath = resolveArtifactLogicalPath(
    category: category,
    kind: kind,
    profile: profile,
    repoPath: repoPath,
  );

  return '$_physicalProfilesRoot/$logicalPath';
}

({String logicalPath, bool secret, bool symlink}) _stripArtifactSuffix(
  String relativePath,
) {
  final symlink = relativePath.endsWith(
    AppConstants.sync.symlinkArtifactSuffix,
  );
  final secret =
      !symlink && relativePath.endsWith(AppConstants.sync.secretArtifactSuffix);
  final suffixLength = symlink
      ? AppConstants.sync.symlinkArtifactSuffix.length
      : secret
      ? AppConstants.sync.secretArtifactSuffix.length
      : 0;

  return (
    logicalPath: suffixLength == 0
        ? relativePath
        : relativePath.substring(0, relativePath.length - suffixLength),
    secret: secret,
    symlink: symlink,
  );
}

ParsedArtifactPath parseArtifactRelativePath(String relativePath) {
  final stripped = _stripArtifactSuffix(relativePath);
  final segments = stripped.logicalPath.split('/');

  if (segments.length < 3 || segments[0] != _physicalProfilesRoot) {
    throw DotweaveError(
      'Repository artifact path is invalid.',
      code: 'INVALID_REPO_ENTRY',
      details: ['Repository path: $relativePath'],
    );
  }

  final profile = segments[1];
  final repoPathSegments = segments.sublist(2);
  final normalizedProfile = normalizeSyncProfileName(
    profile,
    'Repository artifact profile',
  );

  return (
    profile: normalizedProfile,
    repoPath: repoPathSegments.join('/'),
    secret: stripped.secret,
    symlink: stripped.symlink,
  );
}

ParsedArtifactPath _parseArtifactLogicalPath(String relativePath) {
  final stripped = _stripArtifactSuffix(relativePath);
  final segments = stripped.logicalPath.split('/');

  if (segments.length < 2) {
    throw DotweaveError(
      'Repository artifact key is invalid.',
      code: 'INVALID_REPO_ENTRY',
      details: ['Artifact key: $relativePath'],
    );
  }

  final profile = segments[0];
  final repoPathSegments = segments.sublist(1);

  return (
    profile: normalizeSyncProfileName(profile, 'Repository artifact profile'),
    repoPath: repoPathSegments.join('/'),
    secret: stripped.secret,
    symlink: stripped.symlink,
  );
}

Future<List<RepoArtifact>> buildRepoArtifacts(
  Map<String, SnapshotNode> snapshot,
  EffectiveSyncConfig config,
) async {
  final artifacts = <RepoArtifact>[];
  final seenArtifactKeys = <String>{};
  final queryConfig = _toResolvedSyncConfig(config);

  void addArtifact(RepoArtifact artifact) {
    final key = buildArtifactKey(artifact);

    if (seenArtifactKeys.contains(key)) {
      throw DotweaveError(
        'Duplicate repository artifact was generated.',
        code: 'DUPLICATE_REPO_ARTIFACT',
        details: ['Artifact key: $key'],
      );
    }

    seenArtifactKeys.add(key);
    artifacts.add(artifact);
  }

  for (final repoPath in [...snapshot.keys]..sort(compareLocaleLike)) {
    assertStorageSafeRepoPath(repoPath);
    final node = snapshot[repoPath];
    final owningEntry = findOwningSyncEntry(queryConfig, repoPath);
    final resolvedRule = resolveSyncRule(
      queryConfig,
      repoPath,
      config.activeProfile,
    );

    if (node == null || owningEntry == null || resolvedRule == null) {
      continue;
    }

    if (node is DirectorySnapshotNode) {
      addArtifact(
        DirectoryRepoArtifact(
          profile: resolvedRule.profile,
          repoPath: repoPath,
        ),
      );
      continue;
    }

    if (node is SymlinkSnapshotNode) {
      addArtifact(
        SymlinkRepoArtifact(
          linkTarget: node.linkTarget,
          profile: resolvedRule.profile,
          repoPath: repoPath,
        ),
      );
      continue;
    }

    final fileNode = node as FileSnapshotNode;

    if (!fileNode.secret) {
      addArtifact(
        FileRepoArtifact(
          category: 'plain',
          contents: fileNode.contents,
          executable: fileNode.executable,
          profile: resolvedRule.profile,
          repoPath: repoPath,
        ),
      );
      continue;
    }

    addArtifact(
      FileRepoArtifact(
        category: 'secret',
        contents: fileNode.contents,
        executable: fileNode.executable,
        profile: resolvedRule.profile,
        repoPath: repoPath,
      ),
    );
  }

  return artifacts;
}

Future<void> collectArtifactLeafKeys(
  String rootDirectory,
  Set<String> keys, [
  String? prefix,
  void Function(String key)? onKey,
  bool includeEmptyDirectories = false,
  PathStats? providedStats,
]) async {
  // Callers that already stat'd `rootDirectory` (e.g. to decide whether to
  // call this function at all) can pass that result through instead of
  // paying for a second, identical stat call here.
  final rootStats = providedStats ?? await getPathStats(rootDirectory);

  if (rootStats == null) {
    return;
  }

  if (!rootStats.isDirectory) {
    if (prefix != null) {
      keys.add(prefix);
      onKey?.call(prefix);
    }

    return;
  }

  final entries = await listDirectoryEntries(rootDirectory);

  if (entries.isEmpty && prefix != null && includeEmptyDirectories) {
    final key = buildDirectoryKey(prefix);

    keys.add(key);
    onKey?.call(key);
  }

  for (final entry in entries) {
    final absolutePath = p.join(rootDirectory, entry.name);
    final relativePath = prefix == null ? entry.name : '$prefix/${entry.name}';

    // The preceding directory listing already reports whether this entry is
    // a directory, so no stat call is needed here purely to learn the type.
    if (entry.isDirectory) {
      await collectArtifactLeafKeys(
        absolutePath,
        keys,
        relativePath,
        onKey,
        includeEmptyDirectories,
      );
      continue;
    }

    keys.add(relativePath);
    onKey?.call(relativePath);
  }
}

Future<Set<String>> collectExistingArtifactKeys(
  String syncDirectory,
  EffectiveSyncConfig config, [
  ArtifactOwnershipConfig? ownershipConfig,
]) async {
  final effectiveOwnershipConfig =
      ownershipConfig ?? (entries: config.entries, profiles: config.profiles);
  final keys = <String>{};
  final artifactProfiles = collectArtifactProfiles(effectiveOwnershipConfig);
  final profilesDirectory = p.join(syncDirectory, _physicalProfilesRoot);

  final committedProfiles = await readCommittedProfileRegistry(syncDirectory);

  if (committedProfiles != null) {
    for (final profile in committedProfiles) {
      artifactProfiles.add(profile);
    }
  }

  if ((await getPathStats(profilesDirectory))?.isDirectory == true) {
    for (final entry in await listDirectoryEntries(profilesDirectory)) {
      try {
        if ((await getPathStats(
              p.join(profilesDirectory, entry.name),
            ))?.isDirectory ??
            false) {
          artifactProfiles.add(normalizeSyncProfileName(entry.name));
        }
      } catch (_) {
        // Invalid profile directory names are external repository contents,
        // not owned artifacts to delete.
      }
    }
  }

  await Future.wait([
    for (final profile in artifactProfiles)
      () async {
        await collectArtifactLeafKeys(
          p.join(profilesDirectory, profile),
          keys,
          profile,
          null,
          true,
        );
        keys.remove(buildDirectoryKey(profile));
      }(),
  ]);

  for (final key in [...keys]) {
    if (key.startsWith('__dir__:')) {
      continue;
    }

    final isDirectoryKey = key.endsWith('/');
    final artifact = _parseArtifactLogicalPath(
      isDirectoryKey ? key.substring(0, key.length - 1) : key,
    );
    final ownership = classifyArtifactOwnership(
      config,
      effectiveOwnershipConfig,
      artifact,
      isDirectoryKey ? 'directory' : 'file',
    );

    if (ownership == 'platform-protected') {
      keys.remove(key);
    }
  }

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

    if (rule == null || rule.mode == 'ignore') {
      continue;
    }

    final relativePath = resolveArtifactRelativePath(
      category: 'plain',
      profile: rule.profile,
      repoPath: entry.repoPath,
    );
    final logicalPath = resolveArtifactLogicalPath(
      category: 'plain',
      profile: rule.profile,
      repoPath: entry.repoPath,
    );
    final path = p.joinAll([syncDirectory, ...relativePath.split('/')]);

    if ((await getPathStats(path))?.isDirectory ?? false) {
      keys.add(buildDirectoryKey(logicalPath));
    }
  }

  return keys;
}

/// Mirror of the TS `AgeWriteConfig` readonly object. [RuntimeAgeConfig]
/// carries exactly the same fields, so callers pass `config.age` directly.
typedef AgeWriteConfig = RuntimeAgeConfig;

bool _fileModeMatches(int actualMode, bool executable) {
  if (!supportsPosixFileModes()) {
    return true;
  }

  return isExecutableMode(actualMode) == executable;
}

Future<bool> _isSecretArtifactUnchanged(
  String artifactPath,
  Uint8List plaintext,
  String identityFile,
) async {
  final String existingCiphertext;

  try {
    existingCiphertext = await File(artifactPath).readAsString();
  } catch (_) {
    return false;
  }

  try {
    final existingPlaintext = await decryptSecretFile(
      existingCiphertext,
      identityFile,
    );

    return fileContentsEqual(
      existingPlaintext,
      plaintext,
      normalizeTextLineEndings: shouldNormalizeTextLineEndings(),
    );
  } catch (_) {
    return false;
  }
}

/// Mirror of the TS `isRepoArtifactCurrent`; [ageConfig] mirrors the
/// `Pick<AgeWriteConfig, "identityFile">` parameter shape.
Future<bool> isRepoArtifactCurrent(
  String rootDirectory,
  RepoArtifact artifact, [
  ({String identityFile})? ageConfig,
]) async {
  final relativePath = resolveArtifactRelativePath(
    category: artifact.category,
    kind: artifact.kind,
    profile: artifact.profile,
    repoPath: artifact.repoPath,
  );
  final artifactPath = p.joinAll([rootDirectory, ...relativePath.split('/')]);
  final stats = await getPathStats(artifactPath);

  if (artifact is DirectoryRepoArtifact) {
    return stats?.isDirectory ?? false;
  }

  if (artifact is SymlinkRepoArtifact) {
    // Symlinks are stored as regular metadata files whose contents are the
    // POSIX-normalized link target. A legacy physical symlink (stats is a
    // symlink, not a regular file) is treated as not current so the next push
    // rewrites it to the portable format.
    if (stats == null || !stats.isFile) {
      return false;
    }

    final storedTarget = await File(artifactPath).readAsString();

    return storedTarget == toPosixLinkTarget(artifact.linkTarget);
  }

  final fileArtifact = artifact as FileRepoArtifact;

  if (stats == null || !stats.isFile) {
    return false;
  }

  if (!_fileModeMatches(stats.mode, fileArtifact.executable)) {
    return false;
  }

  if (fileArtifact.category == 'secret') {
    if (ageConfig == null) {
      return false;
    }

    return _isSecretArtifactUnchanged(
      artifactPath,
      fileArtifact.contents,
      ageConfig.identityFile,
    );
  }

  final existingContents = await File(artifactPath).readAsBytes();

  return fileContentsEqual(
    existingContents,
    fileArtifact.contents,
    normalizeTextLineEndings: shouldNormalizeTextLineEndings(),
  );
}

Future<void> writeArtifactsToDirectory(
  String rootDirectory,
  List<RepoArtifact> artifacts, [
  AgeWriteConfig? ageConfig,
]) async {
  await Directory(rootDirectory).create(recursive: true);

  final artifactPaths = [
    for (final artifact in artifacts)
      p.joinAll([
        rootDirectory,
        ...resolveArtifactRelativePath(
          category: artifact.category,
          kind: artifact.kind,
          profile: artifact.profile,
          repoPath: artifact.repoPath,
        ).split('/'),
      ]),
  ];

  // Create every unique parent directory once up front (a 10k-file tree has
  // only a handful of distinct parents) instead of a per-file recursive
  // mkdir inside writeFileNode. Final trees are identical: any parent in
  // this set was created by writeFileNode before this hoist whenever any
  // artifact under it was written.
  final parentDirectories = <String>{
    for (var index = 0; index < artifacts.length; index += 1)
      if (artifacts[index] is! DirectoryRepoArtifact)
        p.dirname(artifactPaths[index]),
  };

  for (final directory in parentDirectories.toList()..sort()) {
    await Directory(directory).create(recursive: true);
  }

  await limitConcurrency<int, void>(
    AppConstants.sync.defaultConcurrency,
    [for (var index = 0; index < artifacts.length; index += 1) index],
    (index, _) async {
      final artifact = artifacts[index];
      final artifactPath = artifactPaths[index];

      if (await tracePhase(
        'push.currencyCheck',
        () => isRepoArtifactCurrent(
          rootDirectory,
          artifact,
          ageConfig == null ? null : (identityFile: ageConfig.identityFile),
        ),
      )) {
        return;
      }

      if (artifact is DirectoryRepoArtifact) {
        await Directory(artifactPath).create(recursive: true);
        return;
      }

      if (artifact is SymlinkRepoArtifact) {
        // Store the link as a regular metadata file (POSIX-normalized target)
        // so git versions it as an ordinary blob on every platform, instead of
        // a physical symlink/junction that git cannot portably track.
        await writeFileNode(artifactPath, (
          contents: toPosixLinkTarget(artifact.linkTarget),
          executable: false,
        ), ensureParent: false);
        return;
      }

      final fileArtifact = artifact as FileRepoArtifact;

      if (fileArtifact.category == 'secret' && ageConfig != null) {
        final encrypted = await encryptSecretFile(
          fileArtifact.contents,
          ageConfig.recipients,
        );

        await writeFileNode(artifactPath, (
          contents: encrypted,
          executable: fileArtifact.executable,
        ), ensureParent: false);
        return;
      }

      await tracePhase(
        'push.writeFileNode',
        () => writeFileNode(artifactPath, (
          contents: fileArtifact.contents,
          executable: fileArtifact.executable,
        ), ensureParent: false),
      );
    },
  );

  dumpPerfTrace('writeArtifactsToDirectory');
}
