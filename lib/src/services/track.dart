import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/identity_file.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/config/sync_queries.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/config/xdg.dart';
import 'package:dotweave/src/services/config_file.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/services/sync_mode.dart';
import 'package:dotweave/src/services/sync_paths.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/file_mode.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/track.ts`: adding tracked files/directories to the
// manifest, including platform-scoped local/repo/mode/permission values and
// re-track updates of already-tracked entries.

/// Mirror of the TS `Partial<PlatformStringValue>` inline shape used by
/// [TrackRequest]: every field is optional (`null` means absent).
class PartialPlatformStringValue {
  const PartialPlatformStringValue({
    this.defaultValue,
    this.win,
    this.mac,
    this.linux,
    this.wsl,
  });

  final String? defaultValue;
  final String? win;
  final String? mac;
  final String? linux;
  final String? wsl;
}

/// Mirror of the inline TS union `SyncMode | Partial<PlatformSyncMode>` used
/// by [TrackRequest.mode].
sealed class TrackModeRequest {
  const TrackModeRequest();
}

/// The `SyncMode` arm of [TrackModeRequest]: a plain mode string.
class TrackModeValue extends TrackModeRequest {
  const TrackModeValue(this.value);

  final SyncMode value;
}

/// Mirror of the TS `Partial<PlatformSyncMode>` shape (`null` means absent),
/// which is also the second arm of [TrackModeRequest].
class PartialPlatformSyncMode extends TrackModeRequest {
  const PartialPlatformSyncMode({
    this.defaultValue,
    this.win,
    this.mac,
    this.linux,
    this.wsl,
  });

  final SyncMode? defaultValue;
  final SyncMode? win;
  final SyncMode? mac;
  final SyncMode? linux;
  final SyncMode? wsl;
}

/// Mirror of the TS `TrackRequest` readonly object.
class TrackRequest {
  const TrackRequest({
    this.kind,
    this.localPathOverrides,
    this.profiles,
    this.mode,
    this.permission,
    this.repoPath,
    required this.target,
  });

  final SyncConfigEntryKind? kind;
  final PartialPlatformStringValue? localPathOverrides;
  final List<String>? profiles;
  final TrackModeRequest? mode;
  final PlatformPermission? permission;
  final PartialPlatformStringValue? repoPath;
  final String target;
}

/// Mirror of the TS `TrackResult` readonly object.
class TrackResult {
  const TrackResult({
    required this.alreadyTracked,
    required this.changed,
    required this.configuredLocalPath,
    required this.configuredMode,
    required this.kind,
    required this.localPath,
    required this.profiles,
    required this.mode,
    this.permission,
    this.configuredPermission,
    this.configuredRepoPath,
    required this.repoPath,
  });

  final bool alreadyTracked;
  final bool changed;
  final PlatformStringValue configuredLocalPath;
  final PlatformSyncMode configuredMode;
  final SyncConfigEntryKind kind;
  final String localPath;
  final List<String> profiles;
  final SyncMode mode;
  final int? permission;
  final PlatformPermission? configuredPermission;
  final PlatformStringValue? configuredRepoPath;
  final String repoPath;
}

// A field cannot default to a top-level function of the same name -- the
// field shadows it in the initializer -- so the defaults go through aliases.
const _defaultBuildConfiguredHomeLocalPath = buildConfiguredHomeLocalPath;
const _defaultBuildDefaultPlatformMode = buildDefaultPlatformMode;
const _defaultBuildRepoPathWithinRoot = buildRepoPathWithinRoot;
const _defaultBuildSyncConfigDocument = buildSyncConfigDocument;
const _defaultDoPathsOverlap = doPathsOverlap;
const _defaultGetPathStats = getPathStats;
const _defaultLoadWritableSyncConfig = loadWritableSyncConfig;
const _defaultNormalizeSyncProfileName = normalizeSyncProfileName;
const _defaultNormalizeSyncRepoPath = normalizeSyncRepoPath;
const _defaultResolveDefaultIdentityFile = resolveDefaultIdentityFile;
const _defaultResolveDotweaveHomeDirectoryFromEnv =
    resolveDotweaveHomeDirectoryFromEnv;
const _defaultWriteValidatedSyncConfig = writeValidatedSyncConfig;

/// Collaborators of [trackTarget], standing in for the vitest module
/// mocks used by `track.test.ts`.
///
/// Every field defaults to the real implementation and none is nullable:
/// production overrides nothing and tests supply every field, so an
/// optional-with-fallback field paid for a call pattern nobody used. Making
/// them required-with-default means a test that forgets one fails to compile
/// rather than silently reaching the real filesystem.
class TrackDependencies {
  const TrackDependencies({
    this.buildConfiguredHomeLocalPath = _defaultBuildConfiguredHomeLocalPath,
    this.buildDefaultPlatformMode = _defaultBuildDefaultPlatformMode,
    this.buildRepoPathWithinRoot = _defaultBuildRepoPathWithinRoot,
    this.buildSyncConfigDocument = _defaultBuildSyncConfigDocument,
    this.doPathsOverlap = _defaultDoPathsOverlap,
    this.getPathStats = _defaultGetPathStats,
    this.loadWritableSyncConfig = _defaultLoadWritableSyncConfig,
    this.normalizeSyncProfileName = _defaultNormalizeSyncProfileName,
    this.normalizeSyncRepoPath = _defaultNormalizeSyncRepoPath,
    this.resolveDefaultIdentityFile = _defaultResolveDefaultIdentityFile,
    this.resolveDotweaveHomeDirectoryFromEnv =
        _defaultResolveDotweaveHomeDirectoryFromEnv,
    this.writeValidatedSyncConfig = _defaultWriteValidatedSyncConfig,
  });

  final PlatformStringValue Function(String repoPath)
  buildConfiguredHomeLocalPath;
  final PlatformSyncMode Function(SyncMode mode) buildDefaultPlatformMode;
  final String Function(
    String absolutePath,
    String rootPath,
    String description,
  )
  buildRepoPathWithinRoot;
  final RawSyncConfig Function(ResolvedSyncConfig config)
  buildSyncConfigDocument;
  final bool Function(String leftPath, String rightPath) doPathsOverlap;
  final Future<PathStats?> Function(String path) getPathStats;
  final Future<WritableSyncConfig> Function() loadWritableSyncConfig;
  final String Function(String value) normalizeSyncProfileName;
  final String Function(String value) normalizeSyncRepoPath;
  final String Function(String dotweaveHomeDirectory)
  resolveDefaultIdentityFile;
  final String Function() resolveDotweaveHomeDirectoryFromEnv;
  final Future<void> Function(String syncDirectory, RawSyncConfig config)
  writeValidatedSyncConfig;
}

/// Mirrors node:path `resolve` using the platform-native path context.
String _resolvePath(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

PartialPlatformStringValue _normalizePlatformRepoPath(
  PartialPlatformStringValue repoPath,
  String Function(String value) normalizeSyncRepoPathFn,
) {
  return PartialPlatformStringValue(
    defaultValue: repoPath.defaultValue == null
        ? null
        : normalizeSyncRepoPathFn(repoPath.defaultValue!),
    win: repoPath.win == null ? null : normalizeSyncRepoPathFn(repoPath.win!),
    mac: repoPath.mac == null ? null : normalizeSyncRepoPathFn(repoPath.mac!),
    linux: repoPath.linux == null
        ? null
        : normalizeSyncRepoPathFn(repoPath.linux!),
    wsl: repoPath.wsl == null ? null : normalizeSyncRepoPathFn(repoPath.wsl!),
  );
}

SyncMode _resolvePlatformMode(
  PlatformSyncMode configuredMode,
  PlatformKey platformKey,
) {
  return resolveForPlatform(
    platformKey,
    defaultValue: configuredMode.defaultValue,
    win: configuredMode.win,
    mac: configuredMode.mac,
    linux: configuredMode.linux,
    wsl: configuredMode.wsl,
  );
}

PlatformSyncMode _buildConfiguredMode(
  TrackModeRequest? requestedMode,
  PlatformSyncMode? existingMode,
  PlatformSyncMode Function(SyncMode mode) buildDefaultPlatformModeFn,
) {
  final base =
      existingMode ?? buildDefaultPlatformModeFn(AppConstants.sync.modes[0]);

  switch (requestedMode) {
    case null:
      return base;
    case TrackModeValue(:final value):
      final patch = buildDefaultPlatformModeFn(value);
      return PlatformSyncMode(
        defaultValue: patch.defaultValue,
        win: patch.win ?? base.win,
        mac: patch.mac ?? base.mac,
        linux: patch.linux ?? base.linux,
        wsl: patch.wsl ?? base.wsl,
      );
    case PartialPlatformSyncMode():
      return PlatformSyncMode(
        defaultValue: requestedMode.defaultValue ?? base.defaultValue,
        win: requestedMode.win ?? base.win,
        mac: requestedMode.mac ?? base.mac,
        linux: requestedMode.linux ?? base.linux,
        wsl: requestedMode.wsl ?? base.wsl,
      );
  }
}

PlatformStringValue _mergePlatformStringValue(
  PlatformStringValue base,
  PartialPlatformStringValue patch,
) {
  return PlatformStringValue(
    defaultValue: patch.defaultValue ?? base.defaultValue,
    win: patch.win ?? base.win,
    mac: patch.mac ?? base.mac,
    linux: patch.linux ?? base.linux,
    wsl: patch.wsl ?? base.wsl,
  );
}

SyncConfigEntryKind _resolveTargetKind(
  String targetPath,
  PathStats? targetStats,
  SyncConfigEntryKind? requestedKind,
) {
  if (targetStats == null) {
    if (requestedKind != null) {
      return requestedKind;
    }

    throw DotweaveError(
      'Sync target kind is required.',
      code: 'TARGET_KIND_REQUIRED',
      details: ['Target: $targetPath'],
      hint:
          'Pass --kind file or --kind directory when tracking a path that '
          'does not exist yet.',
    );
  }

  final actualKind = () {
    if (targetStats.isDirectory) {
      return 'directory';
    }

    if (targetStats.isFile || targetStats.isSymbolicLink) {
      return 'file';
    }

    throw DotweaveError(
      'Sync target type is not supported.',
      code: 'TARGET_UNSUPPORTED_TYPE',
      details: ['Target: $targetPath'],
      hint: 'Track a regular file, symlink, or directory.',
    );
  }();

  if (requestedKind != null && requestedKind != actualKind) {
    throw DotweaveError(
      'Sync target kind does not match the path.',
      code: 'TARGET_KIND_MISMATCH',
      details: [
        'Target: $targetPath',
        'Requested kind: $requestedKind',
        'Actual kind: $actualKind',
      ],
      hint:
          'Use --kind $actualKind for this target, or choose a matching '
          'path.',
    );
  }

  return actualKind;
}

Future<ResolvedSyncConfigEntry> _buildTrackEntryCandidate(
  String targetPath,
  String syncDirectory,
  String homeDirectory, {
  required String? identityFile,
  SyncConfigEntryKind? kind,
  PartialPlatformStringValue? localPathOverrides,
  List<String>? profiles,
  TrackModeRequest? mode,
  PlatformPermission? permission,
  required PlatformKey platformKey,
  PartialPlatformStringValue? repoPath,
  required TrackDependencies dependencies,
}) async {
  final effectiveDoPathsOverlap = dependencies.doPathsOverlap;

  final effectiveNormalizeSyncRepoPath = dependencies.normalizeSyncRepoPath;
  final effectiveNormalizeSyncProfileName =
      dependencies.normalizeSyncProfileName;
  final effectiveBuildDefaultPlatformMode =
      dependencies.buildDefaultPlatformMode;

  final targetStats = await dependencies.getPathStats(targetPath);
  final resolvedKind = _resolveTargetKind(targetPath, targetStats, kind);

  if (effectiveDoPathsOverlap(targetPath, syncDirectory)) {
    throw DotweaveError(
      'Sync target overlaps the dotweave sync directory.',
      code: 'TARGET_OVERLAPS_SYNC_DIR',
      details: ['Target: $targetPath', 'Sync directory: $syncDirectory'],
      hint: 'Choose a path outside the dotweave sync directory.',
    );
  }

  if (identityFile != null &&
      effectiveDoPathsOverlap(targetPath, identityFile)) {
    throw DotweaveError(
      'Sync target contains the configured age identity file.',
      code: 'TARGET_OVERLAPS_IDENTITY',
      details: ['Target: $targetPath', 'Age identity file: $identityFile'],
      hint: 'Store age key material outside tracked sync targets.',
    );
  }

  final localRepoPath = dependencies.buildRepoPathWithinRoot(
    targetPath,
    homeDirectory,
    'Sync target',
  );
  final configuredLocalPath = _mergePlatformStringValue(
    dependencies.buildConfiguredHomeLocalPath(localRepoPath),
    localPathOverrides ?? const PartialPlatformStringValue(),
  );
  final PlatformStringValue? configuredRepoPath;

  if (repoPath == null) {
    configuredRepoPath = null;
  } else {
    final normalized = _normalizePlatformRepoPath(
      PartialPlatformStringValue(
        defaultValue: repoPath.defaultValue ?? localRepoPath,
        win: repoPath.win,
        mac: repoPath.mac,
        linux: repoPath.linux,
        wsl: repoPath.wsl,
      ),
      effectiveNormalizeSyncRepoPath,
    );
    configuredRepoPath = PlatformStringValue(
      defaultValue: normalized.defaultValue!,
      win: normalized.win,
      mac: normalized.mac,
      linux: normalized.linux,
      wsl: normalized.wsl,
    );
  }

  final resolvedRepoPath = configuredRepoPath == null
      ? localRepoPath
      : resolvePlatformValue(configuredRepoPath, platformKey);
  final configuredPermission = permission;
  final configuredMode = _buildConfiguredMode(
    mode,
    null,
    effectiveBuildDefaultPlatformMode,
  );

  return ResolvedSyncConfigEntry(
    configuredLocalPath: configuredLocalPath,
    configuredRepoPath: configuredRepoPath,
    configuredPermission: configuredPermission,
    permission: configuredPermission == null
        ? null
        : parsePermissionOctal(configuredPermission.defaultValue),
    kind: resolvedKind,
    localPath: targetPath,
    profiles: [
      for (final m in profiles ?? const <String>[])
        effectiveNormalizeSyncProfileName(m),
    ],
    profilesExplicit: profiles != null,
    mode: _resolvePlatformMode(configuredMode, platformKey),
    modeExplicit: true,
    configuredMode: configuredMode,
    permissionExplicit: configuredPermission != null,
    repoPath: resolvedRepoPath,
  );
}

void _validateRequestedProfiles(
  List<String>? requestedProfiles,
  List<String>? availableProfiles,
  String Function(String value) normalizeSyncProfileNameFn,
) {
  if (requestedProfiles == null) {
    return;
  }

  final knownProfiles = {
    AppConstants.sync.defaultProfile,
    ...(availableProfiles ?? const <String>[]),
  };

  for (final profile in requestedProfiles) {
    final normalizedProfile = normalizeSyncProfileNameFn(profile);

    if (!knownProfiles.contains(normalizedProfile)) {
      throw DotweaveError(
        "Unknown profile '$normalizedProfile'.",
        code: 'UNKNOWN_PROFILE',
        hint:
            "Add it with 'dotweave profile add $normalizedProfile', or "
            'choose an existing profile.',
      );
    }
  }
}

Future<TrackResult> trackTarget(
  TrackRequest request,
  String cwd, [
  TrackDependencies dependencies = const TrackDependencies(),
]) async {
  final effectiveNormalizeSyncProfileName =
      dependencies.normalizeSyncProfileName;
  final effectiveNormalizeSyncRepoPath = dependencies.normalizeSyncRepoPath;
  final effectiveBuildDefaultPlatformMode =
      dependencies.buildDefaultPlatformMode;
  final effectiveBuildSyncConfigDocument = dependencies.buildSyncConfigDocument;
  final effectiveWriteValidatedSyncConfig =
      dependencies.writeValidatedSyncConfig;

  final target = request.target.trim();

  if (target.isEmpty) {
    throw DotweaveError(
      'Target path is required.',
      code: 'TARGET_REQUIRED',
      hint:
          'Pass a file or directory path, for example '
          "'dotweave track ~/.gitconfig'.",
    );
  }

  final writable = await dependencies.loadWritableSyncConfig();
  final config = writable.config;
  final context = writable.context;
  final syncDirectory = writable.syncDirectory;
  final identityFile = config.age != null
      ? dependencies.resolveDefaultIdentityFile(
          dependencies.resolveDotweaveHomeDirectoryFromEnv(),
        )
      : null;
  final requestProfiles = request.profiles;
  final isProfileClear =
      requestProfiles != null &&
      requestProfiles.length == 1 &&
      requestProfiles[0] == '';
  final effectiveProfiles = isProfileClear
      ? const <String>[]
      : request.profiles;
  _validateRequestedProfiles(
    effectiveProfiles,
    config.profiles,
    effectiveNormalizeSyncProfileName,
  );

  final candidate = await _buildTrackEntryCandidate(
    _resolvePath([cwd, expandHomePath(target, context.homeDirectory)]),
    syncDirectory,
    context.homeDirectory,
    identityFile: identityFile,
    kind: request.kind,
    localPathOverrides: request.localPathOverrides,
    profiles: effectiveProfiles,
    mode: request.mode,
    permission: request.permission,
    platformKey: context.platformKey,
    repoPath: request.repoPath,
    dependencies: dependencies,
  );

  ResolvedSyncConfigEntry? existingEntry;
  for (final entry in config.entries) {
    if (entry.localPath == candidate.localPath) {
      existingEntry = entry;
      break;
    }
  }

  final alreadyTracked =
      existingEntry != null && existingEntry.kind == candidate.kind;

  if (existingEntry != null && existingEntry.kind != candidate.kind) {
    throw DotweaveError(
      'Sync target conflicts with an existing tracked entry.',
      code: 'TARGET_CONFLICT',
      details: [
        'Requested local path: ${candidate.localPath}',
        'Requested repo path: ${candidate.repoPath}',
        'Existing entry: '
            '${existingEntry.localPath} -> ${existingEntry.repoPath}',
      ],
      hint: 'Untrack or rename the existing entry before adding this root.',
    );
  }

  final nextEntry = () {
    if (existingEntry == null) {
      return candidate;
    }

    final configuredRepoPath = request.repoPath == null
        ? existingEntry.configuredRepoPath
        : _mergePlatformStringValue(
            existingEntry.configuredRepoPath ??
                PlatformStringValue(defaultValue: existingEntry.repoPath),
            _normalizePlatformRepoPath(
              request.repoPath!,
              effectiveNormalizeSyncRepoPath,
            ),
          );
    final configuredMode = _buildConfiguredMode(
      request.mode,
      existingEntry.configuredMode,
      effectiveBuildDefaultPlatformMode,
    );
    final localPathOverrides = request.localPathOverrides;
    final configuredLocalPath = localPathOverrides == null
        ? existingEntry.configuredLocalPath
        : PlatformStringValue(
            defaultValue: candidate.configuredLocalPath.defaultValue,
            win:
                localPathOverrides.win ?? existingEntry.configuredLocalPath.win,
            mac:
                localPathOverrides.mac ?? existingEntry.configuredLocalPath.mac,
            linux:
                localPathOverrides.linux ??
                existingEntry.configuredLocalPath.linux,
            wsl:
                localPathOverrides.wsl ?? existingEntry.configuredLocalPath.wsl,
          );

    return ResolvedSyncConfigEntry(
      configuredLocalPath: configuredLocalPath,
      configuredMode: configuredMode,
      configuredPermission: candidate.configuredPermission,
      configuredRepoPath: configuredRepoPath ?? candidate.configuredRepoPath,
      kind: candidate.kind,
      localPath: candidate.localPath,
      profiles: candidate.profiles,
      profilesExplicit: candidate.profilesExplicit,
      mode: _resolvePlatformMode(configuredMode, context.platformKey),
      modeExplicit: candidate.modeExplicit,
      permission: candidate.permission,
      permissionExplicit: candidate.permissionExplicit,
      repoPath: configuredRepoPath == null
          ? existingEntry.repoPath
          : resolvePlatformValue(configuredRepoPath, context.platformKey),
    );
  }();

  ResolvedSyncConfigEntry? repoPathConflict;
  for (final entry in config.entries) {
    if (entry.repoPath == nextEntry.repoPath &&
        entry.localPath != nextEntry.localPath) {
      repoPathConflict = entry;
      break;
    }
  }

  if (repoPathConflict != null) {
    throw DotweaveError(
      'Sync target conflicts with an existing tracked entry.',
      code: 'TARGET_CONFLICT',
      details: [
        'Requested local path: ${nextEntry.localPath}',
        'Requested repo path: ${nextEntry.repoPath}',
        'Existing entry: '
            '${repoPathConflict.localPath} -> ${repoPathConflict.repoPath}',
      ],
      hint: 'Change --repo or untrack the conflicting entry first.',
    );
  }

  if (!alreadyTracked) {
    final nextConfig = effectiveBuildSyncConfigDocument(
      ResolvedSyncConfig(
        age: config.age,
        entries: [...config.entries, nextEntry],
        profiles: config.profiles,
        repositoryFormat: config.repositoryFormat,
        version: config.version,
      ),
    );

    await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);

    return TrackResult(
      alreadyTracked: alreadyTracked,
      changed: true,
      configuredLocalPath: nextEntry.configuredLocalPath,
      configuredMode: nextEntry.configuredMode,
      kind: nextEntry.kind,
      localPath: nextEntry.localPath,
      profiles: nextEntry.profiles,
      mode: nextEntry.mode,
      permission: nextEntry.permission,
      configuredPermission: nextEntry.configuredPermission,
      configuredRepoPath: nextEntry.configuredRepoPath,
      repoPath: nextEntry.repoPath,
    );
  }

  final trackedEntry = existingEntry;
  final modeChanged =
      request.mode != null &&
      (trackedEntry.mode != nextEntry.mode ||
          trackedEntry.configuredMode != nextEntry.configuredMode);
  final localPathChanged =
      request.localPathOverrides != null &&
      trackedEntry.configuredLocalPath != nextEntry.configuredLocalPath;
  final profilesChanged =
      effectiveProfiles != null &&
      (trackedEntry.profiles.length != candidate.profiles.length ||
          !candidate.profiles.every(trackedEntry.profiles.contains));
  final repoPathChanged =
      request.repoPath != null &&
      (trackedEntry.repoPath != nextEntry.repoPath ||
          trackedEntry.configuredRepoPath != nextEntry.configuredRepoPath);
  final permissionChanged =
      request.permission != null &&
      trackedEntry.configuredPermission != request.permission;
  final changed =
      localPathChanged ||
      modeChanged ||
      profilesChanged ||
      repoPathChanged ||
      permissionChanged;

  if (changed) {
    final nextConfig = effectiveBuildSyncConfigDocument(
      ResolvedSyncConfig(
        age: config.age,
        entries: [
          for (final entry in config.entries)
            if (entry.localPath != candidate.localPath)
              entry
            else
              ResolvedSyncConfigEntry(
                configuredLocalPath: localPathChanged
                    ? nextEntry.configuredLocalPath
                    : entry.configuredLocalPath,
                configuredMode: modeChanged
                    ? nextEntry.configuredMode
                    : entry.configuredMode,
                configuredPermission: permissionChanged
                    ? request.permission
                    : entry.configuredPermission,
                configuredRepoPath: repoPathChanged
                    ? nextEntry.configuredRepoPath
                    : entry.configuredRepoPath,
                kind: entry.kind,
                localPath: entry.localPath,
                profiles: profilesChanged ? candidate.profiles : entry.profiles,
                profilesExplicit: profilesChanged
                    ? candidate.profilesExplicit
                    : entry.profilesExplicit,
                mode: modeChanged ? nextEntry.mode : entry.mode,
                modeExplicit: entry.modeExplicit,
                permission: permissionChanged
                    ? parsePermissionOctal(request.permission!.defaultValue)
                    : entry.permission,
                permissionExplicit: permissionChanged
                    ? true
                    : entry.permissionExplicit,
                repoPath: repoPathChanged ? nextEntry.repoPath : entry.repoPath,
              ),
        ],
        profiles: config.profiles,
        repositoryFormat: config.repositoryFormat,
        version: config.version,
      ),
    );

    await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);
  }

  return TrackResult(
    alreadyTracked: alreadyTracked,
    changed: changed,
    configuredLocalPath: localPathChanged
        ? nextEntry.configuredLocalPath
        : trackedEntry.configuredLocalPath,
    configuredMode: modeChanged
        ? nextEntry.configuredMode
        : trackedEntry.configuredMode,
    kind: nextEntry.kind,
    localPath: nextEntry.localPath,
    profiles: profilesChanged ? nextEntry.profiles : trackedEntry.profiles,
    mode: modeChanged ? nextEntry.mode : trackedEntry.mode,
    permission: permissionChanged
        ? parsePermissionOctal(request.permission!.defaultValue)
        : trackedEntry.permission,
    configuredPermission: permissionChanged
        ? request.permission
        : trackedEntry.configuredPermission,
    configuredRepoPath: repoPathChanged || !alreadyTracked
        ? nextEntry.configuredRepoPath
        : trackedEntry.configuredRepoPath,
    repoPath: repoPathChanged || !alreadyTracked
        ? nextEntry.repoPath
        : trackedEntry.repoPath,
  );
}

/// Outcome of [trackOrSetMode]: whether the target was tracked outright, or
/// whether it already existed inside a tracked directory and only had its
/// sync mode set.
sealed class TrackOutcome {
  const TrackOutcome();
}

/// The target was newly tracked (or an existing entry was updated).
final class TrackedOutcome extends TrackOutcome {
  const TrackedOutcome(this.result);

  final TrackResult result;
}

/// The target was not trackable on its own, so its sync mode was set instead.
final class ModeSetOutcome extends TrackOutcome {
  const ModeSetOutcome(this.result);

  final SetModeResult result;
}

/// Tracks [request], falling back to setting the target's sync mode when it
/// turns out to live inside an already-tracked directory.
///
/// This orchestration -- track, and on "target not found" validate the
/// profiles, set the mode, then assign the profiles -- is a policy about what
/// `dotweave track` means, not about how to render it, but it used to live in
/// the command. Note two rules that are easy to lose: the fallback is skipped
/// when the caller pinned an explicit repository path (there is nothing to
/// infer), and a profile list of exactly `['']` means "clear the profiles"
/// rather than "assign the empty-named profile".
Future<TrackOutcome> trackOrSetMode(
  TrackRequest request,
  String cwd, {
  required SyncMode fallbackMode,
}) async {
  try {
    return TrackedOutcome(await trackTarget(request, cwd));
  } catch (error) {
    if (request.repoPath != null || !isSyncTargetNotFoundError(error)) {
      rethrow;
    }

    final profiles = request.profiles ?? const <String>[];
    final isProfileClear = profiles.length == 1 && profiles[0] == '';

    if (profiles.isNotEmpty && !isProfileClear) {
      await validateProfilesExist(profiles);
    }

    final setResult = await setTargetMode(
      SetModeRequest(mode: fallbackMode, target: request.target),
      cwd,
    );

    if (profiles.isNotEmpty) {
      await assignProfiles(
        AssignProfilesRequest(
          profiles: isProfileClear ? const [] : profiles,
          target: request.target,
        ),
        cwd,
      );
    }

    return ModeSetOutcome(setResult);
  }
}
