import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/global_config.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/config_file.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/services/sync_paths.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/git.dart';

// Mirror of `services/profile.ts`: profile add/list/remove/use service —
// per-machine subset syncing, profile registry in the manifest, and the
// active profile in settings.jsonc.

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) {
    return false;
  }

  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }

  return true;
}

/// Mirror of the TS `ProfileAssignment` readonly object.
class ProfileAssignment {
  const ProfileAssignment({
    required this.entryLocalPath,
    required this.entryRepoPath,
    required this.profiles,
  });

  final String entryLocalPath;
  final String entryRepoPath;
  final List<String> profiles;

  @override
  bool operator ==(Object other) {
    return other is ProfileAssignment &&
        other.entryLocalPath == entryLocalPath &&
        other.entryRepoPath == entryRepoPath &&
        _listEquals(other.profiles, profiles);
  }

  @override
  int get hashCode =>
      Object.hash(entryLocalPath, entryRepoPath, Object.hashAll(profiles));

  @override
  String toString() {
    return 'ProfileAssignment(entryLocalPath: $entryLocalPath, '
        'entryRepoPath: $entryRepoPath, profiles: $profiles)';
  }
}

/// Mirror of the TS `ProfileListResult` readonly object. The
/// `activeProfileMode` field carries the TS `"none" | "single"` union.
class ProfileListResult {
  const ProfileListResult({
    this.activeProfile,
    required this.activeProfileMode,
    this.activeProfileWarning,
    required this.assignments,
    required this.availableProfiles,
    required this.globalConfigExists,
    required this.globalConfigPath,
  });

  final String? activeProfile;
  final String activeProfileMode;
  final String? activeProfileWarning;
  final List<ProfileAssignment> assignments;
  final List<String> availableProfiles;
  final bool globalConfigExists;
  final String globalConfigPath;

  @override
  bool operator ==(Object other) {
    return other is ProfileListResult &&
        other.activeProfile == activeProfile &&
        other.activeProfileMode == activeProfileMode &&
        other.activeProfileWarning == activeProfileWarning &&
        _listEquals(other.assignments, assignments) &&
        _listEquals(other.availableProfiles, availableProfiles) &&
        other.globalConfigExists == globalConfigExists &&
        other.globalConfigPath == globalConfigPath;
  }

  @override
  int get hashCode => Object.hash(
    activeProfile,
    activeProfileMode,
    activeProfileWarning,
    Object.hashAll(assignments),
    Object.hashAll(availableProfiles),
    globalConfigExists,
    globalConfigPath,
  );

  @override
  String toString() {
    return 'ProfileListResult(activeProfile: $activeProfile, '
        'activeProfileMode: $activeProfileMode, '
        'activeProfileWarning: $activeProfileWarning, '
        'assignments: $assignments, availableProfiles: $availableProfiles, '
        'globalConfigExists: $globalConfigExists, '
        'globalConfigPath: $globalConfigPath)';
  }
}

/// Mirror of the TS `ProfileUpdateResult` readonly object. The `action` field
/// carries the TS `"clear" | "use"` union.
class ProfileUpdateResult {
  const ProfileUpdateResult({
    this.activeProfile,
    required this.action,
    required this.globalConfigPath,
    this.profile,
    this.warning,
  });

  final String? activeProfile;
  final String action;
  final String globalConfigPath;
  final String? profile;
  final String? warning;

  @override
  bool operator ==(Object other) {
    return other is ProfileUpdateResult &&
        other.activeProfile == activeProfile &&
        other.action == action &&
        other.globalConfigPath == globalConfigPath &&
        other.profile == profile &&
        other.warning == warning;
  }

  @override
  int get hashCode =>
      Object.hash(activeProfile, action, globalConfigPath, profile, warning);

  @override
  String toString() {
    return 'ProfileUpdateResult(activeProfile: $activeProfile, '
        'action: $action, globalConfigPath: $globalConfigPath, '
        'profile: $profile, warning: $warning)';
  }
}

/// Mirror of the TS `ProfileRegistryUpdateResult` readonly object. The
/// `action` field carries the TS `"added" | "removed"` union.
class ProfileRegistryUpdateResult {
  const ProfileRegistryUpdateResult({
    required this.action,
    required this.profile,
  });

  final String action;
  final String profile;

  @override
  bool operator ==(Object other) {
    return other is ProfileRegistryUpdateResult &&
        other.action == action &&
        other.profile == profile;
  }

  @override
  int get hashCode => Object.hash(action, profile);

  @override
  String toString() {
    return 'ProfileRegistryUpdateResult(action: $action, profile: $profile)';
  }
}

/// Mirror of the non-exported TS `AssignProfilesRequest` readonly object.
class AssignProfilesRequest {
  const AssignProfilesRequest({required this.profiles, required this.target});

  final List<String> profiles;
  final String target;
}

/// Mirror of the non-exported TS `AssignProfilesResult` readonly object. The
/// `action` field carries the TS `"assigned" | "unchanged"` union.
class AssignProfilesResult {
  const AssignProfilesResult({
    required this.action,
    required this.entryRepoPath,
    required this.profiles,
  });

  final String action;
  final String entryRepoPath;
  final List<String> profiles;

  @override
  bool operator ==(Object other) {
    return other is AssignProfilesResult &&
        other.action == action &&
        other.entryRepoPath == entryRepoPath &&
        _listEquals(other.profiles, profiles);
  }

  @override
  int get hashCode =>
      Object.hash(action, entryRepoPath, Object.hashAll(profiles));

  @override
  String toString() {
    return 'AssignProfilesResult(action: $action, '
        'entryRepoPath: $entryRepoPath, profiles: $profiles)';
  }
}

/// Optional overrides for the profile service functions, standing in for the
/// vitest module mocks used by `profile.test.ts`.
class ProfileDependencies {
  const ProfileDependencies({
    this.buildSyncConfigDocument,
    this.formatGlobalDotweaveConfig,
    this.isProfileActive,
    this.loadWritableSyncConfig,
    this.normalizeSyncProfileName,
    this.readGlobalDotweaveConfig,
    this.readSyncConfig,
    this.requireGitRepository,
    this.resolveActiveProfileSelection,
    this.resolveSyncConfigResolutionContext,
    this.resolveSyncPaths,
    this.resolveTrackedEntry,
    this.writeTextFileAtomically,
    this.writeValidatedSyncConfig,
  });

  final RawSyncConfig Function(ResolvedSyncConfig config)?
  buildSyncConfigDocument;
  final String Function(GlobalDotweaveConfig config)?
  formatGlobalDotweaveConfig;
  final bool Function(ActiveProfileSelection selection, String? profile)?
  isProfileActive;
  final Future<WritableSyncConfig> Function()? loadWritableSyncConfig;
  final String Function(String value)? normalizeSyncProfileName;
  final Future<GlobalDotweaveConfig?> Function(String filePath)?
  readGlobalDotweaveConfig;
  final Future<ResolvedSyncConfig> Function(
    String syncDirectory,
    SyncConfigResolutionContext context,
  )?
  readSyncConfig;
  final Future<void> Function(String syncDirectory)? requireGitRepository;
  final ActiveProfileSelection Function(GlobalDotweaveConfig? config)?
  resolveActiveProfileSelection;
  final SyncConfigResolutionContext Function()?
  resolveSyncConfigResolutionContext;
  final SyncPaths Function()? resolveSyncPaths;
  final ResolvedSyncConfigEntry? Function(
    String target,
    List<ResolvedSyncConfigEntry> entries,
    String cwd,
    String homeDirectory,
  )?
  resolveTrackedEntry;
  final Future<void> Function(String targetPath, String contents)?
  writeTextFileAtomically;
  final Future<void> Function(String syncDirectory, RawSyncConfig config)?
  writeValidatedSyncConfig;
}

List<String> _availableProfilesForConfig(ResolvedSyncConfig config) {
  return [AppConstants.sync.defaultProfile, ...?config.profiles];
}

bool _isKnownProfile(ResolvedSyncConfig config, String profile) {
  return _availableProfilesForConfig(config).contains(profile);
}

DotweaveError _createUnknownProfileError(String profile) {
  return DotweaveError(
    "Unknown profile '$profile'.",
    code: 'UNKNOWN_PROFILE',
    hint:
        "Add it with 'dotweave profile add $profile', or choose an existing "
        'profile.',
  );
}

void _requireNonDefaultProfile(String profile, String action) {
  if (profile == AppConstants.sync.defaultProfile) {
    throw DotweaveError(
      'Cannot $action the implicit default profile.',
      code: 'DEFAULT_PROFILE_IMPLICIT',
      hint:
          "The '${AppConstants.sync.defaultProfile}' profile always exists "
          'automatically.',
    );
  }
}

List<String> _normalizeAndRequireKnownProfiles(
  List<String> profiles,
  ResolvedSyncConfig config,
  String Function(String value) normalizeSyncProfileNameFn,
) {
  final normalizedProfiles = [
    for (final profile in profiles) normalizeSyncProfileNameFn(profile),
  ];

  for (final profile in normalizedProfiles) {
    if (!_isKnownProfile(config, profile)) {
      throw _createUnknownProfileError(profile);
    }
  }

  return normalizedProfiles;
}

Future<ProfileListResult> listProfiles([
  ProfileDependencies dependencies = const ProfileDependencies(),
]) async {
  final effectiveResolveSyncPaths =
      dependencies.resolveSyncPaths ?? resolveSyncPaths;
  final effectiveResolveSyncConfigResolutionContext =
      dependencies.resolveSyncConfigResolutionContext ??
      resolveSyncConfigResolutionContext;
  final effectiveRequireGitRepository =
      dependencies.requireGitRepository ?? requireGitRepository;
  final effectiveReadGlobalDotweaveConfig =
      dependencies.readGlobalDotweaveConfig ?? readGlobalDotweaveConfig;
  final effectiveReadSyncConfig = dependencies.readSyncConfig ?? readSyncConfig;

  final paths = effectiveResolveSyncPaths();
  final syncDirectory = paths.syncDirectory;
  final globalConfigPath = paths.globalConfigPath;
  final context = effectiveResolveSyncConfigResolutionContext();

  await effectiveRequireGitRepository(syncDirectory);

  // Mirror of the TS `Promise.all` pair.
  final results = await Future.wait<Object?>([
    effectiveReadGlobalDotweaveConfig(globalConfigPath),
    effectiveReadSyncConfig(syncDirectory, context),
  ]);
  final globalConfig = results[0] as GlobalDotweaveConfig?;
  final syncConfig = results[1] as ResolvedSyncConfig;

  final availableProfiles = _availableProfilesForConfig(syncConfig);
  final activeProfile =
      globalConfig?.activeProfile ?? AppConstants.sync.defaultProfile;
  final activeProfileWarning = !availableProfiles.contains(activeProfile)
      ? "Active profile '$activeProfile' is not registered in "
            '${AppConstants.sync.configFileName}.'
      : null;

  final assignments =
      [
        for (final entry in syncConfig.entries)
          if (entry.profilesExplicit && entry.profiles.isNotEmpty)
            ProfileAssignment(
              entryLocalPath: entry.localPath,
              entryRepoPath: entry.repoPath,
              profiles: entry.profiles,
            ),
      ]..sort(
        (left, right) =>
            compareLocaleLike(left.entryRepoPath, right.entryRepoPath),
      );

  return ProfileListResult(
    activeProfile: activeProfile,
    activeProfileWarning: activeProfileWarning,
    activeProfileMode: globalConfig?.activeProfile == null ? 'none' : 'single',
    assignments: assignments,
    availableProfiles: availableProfiles,
    globalConfigExists: globalConfig != null,
    globalConfigPath: globalConfigPath,
  );
}

Future<ProfileUpdateResult> setActiveProfile(
  String profile, [
  ProfileDependencies dependencies = const ProfileDependencies(),
]) async {
  final effectiveNormalizeSyncProfileName =
      dependencies.normalizeSyncProfileName ?? normalizeSyncProfileName;
  final effectiveResolveSyncPaths =
      dependencies.resolveSyncPaths ?? resolveSyncPaths;
  final effectiveResolveSyncConfigResolutionContext =
      dependencies.resolveSyncConfigResolutionContext ??
      resolveSyncConfigResolutionContext;
  final effectiveRequireGitRepository =
      dependencies.requireGitRepository ?? requireGitRepository;
  final effectiveReadSyncConfig = dependencies.readSyncConfig ?? readSyncConfig;
  final effectiveFormatGlobalDotweaveConfig =
      dependencies.formatGlobalDotweaveConfig ?? formatGlobalDotweaveConfig;
  final effectiveWriteTextFileAtomically =
      dependencies.writeTextFileAtomically ?? writeTextFileAtomically;

  final normalizedProfile = effectiveNormalizeSyncProfileName(profile);
  final paths = effectiveResolveSyncPaths();
  final syncDirectory = paths.syncDirectory;
  final globalConfigPath = paths.globalConfigPath;
  final context = effectiveResolveSyncConfigResolutionContext();

  await effectiveRequireGitRepository(syncDirectory);

  final syncConfig = await effectiveReadSyncConfig(syncDirectory, context);

  if (!_isKnownProfile(syncConfig, normalizedProfile)) {
    throw _createUnknownProfileError(normalizedProfile);
  }

  await effectiveWriteTextFileAtomically(
    globalConfigPath,
    effectiveFormatGlobalDotweaveConfig(
      GlobalDotweaveConfig(
        activeProfile: normalizedProfile,
        version: AppConstants.globalConfig.currentVersion,
      ),
    ),
  );

  return ProfileUpdateResult(
    activeProfile: normalizedProfile,
    globalConfigPath: globalConfigPath,
    action: 'use',
    profile: normalizedProfile,
  );
}

Future<ProfileRegistryUpdateResult> addProfile(
  String profile, [
  ProfileDependencies dependencies = const ProfileDependencies(),
]) async {
  final effectiveNormalizeSyncProfileName =
      dependencies.normalizeSyncProfileName ?? normalizeSyncProfileName;
  final effectiveLoadWritableSyncConfig =
      dependencies.loadWritableSyncConfig ?? loadWritableSyncConfig;
  final effectiveBuildSyncConfigDocument =
      dependencies.buildSyncConfigDocument ?? buildSyncConfigDocument;
  final effectiveWriteValidatedSyncConfig =
      dependencies.writeValidatedSyncConfig ?? writeValidatedSyncConfig;

  final normalizedProfile = effectiveNormalizeSyncProfileName(profile);
  _requireNonDefaultProfile(normalizedProfile, 'add');

  final writable = await effectiveLoadWritableSyncConfig();
  final config = writable.config;
  final syncDirectory = writable.syncDirectory;

  if ((config.profiles ?? const <String>[]).contains(normalizedProfile)) {
    throw DotweaveError(
      "Profile '$normalizedProfile' already exists.",
      code: 'PROFILE_ALREADY_EXISTS',
      hint: 'Choose a different profile name.',
    );
  }

  final nextConfig = effectiveBuildSyncConfigDocument(
    ResolvedSyncConfig(
      age: config.age,
      entries: config.entries,
      profiles: [...(config.profiles ?? const <String>[]), normalizedProfile]
        ..sort(compareLocaleLike),
      repositoryFormat: config.repositoryFormat,
      version: config.version,
    ),
  );

  await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);

  return ProfileRegistryUpdateResult(
    action: 'added',
    profile: normalizedProfile,
  );
}

Future<ProfileRegistryUpdateResult> removeProfile(
  String profile, [
  ProfileDependencies dependencies = const ProfileDependencies(),
]) async {
  final effectiveNormalizeSyncProfileName =
      dependencies.normalizeSyncProfileName ?? normalizeSyncProfileName;
  final effectiveResolveSyncPaths =
      dependencies.resolveSyncPaths ?? resolveSyncPaths;
  final effectiveLoadWritableSyncConfig =
      dependencies.loadWritableSyncConfig ?? loadWritableSyncConfig;
  final effectiveReadGlobalDotweaveConfig =
      dependencies.readGlobalDotweaveConfig ?? readGlobalDotweaveConfig;
  final effectiveResolveActiveProfileSelection =
      dependencies.resolveActiveProfileSelection ??
      resolveActiveProfileSelection;
  final effectiveIsProfileActive =
      dependencies.isProfileActive ?? isProfileActive;
  final effectiveBuildSyncConfigDocument =
      dependencies.buildSyncConfigDocument ?? buildSyncConfigDocument;
  final effectiveWriteValidatedSyncConfig =
      dependencies.writeValidatedSyncConfig ?? writeValidatedSyncConfig;

  final normalizedProfile = effectiveNormalizeSyncProfileName(profile);
  _requireNonDefaultProfile(normalizedProfile, 'remove');

  final globalConfigPath = effectiveResolveSyncPaths().globalConfigPath;
  final writable = await effectiveLoadWritableSyncConfig();
  final config = writable.config;
  final syncDirectory = writable.syncDirectory;

  if (!(config.profiles ?? const <String>[]).contains(normalizedProfile)) {
    throw _createUnknownProfileError(normalizedProfile);
  }

  final globalConfig = await effectiveReadGlobalDotweaveConfig(
    globalConfigPath,
  );
  final activeProfile = effectiveResolveActiveProfileSelection(globalConfig);

  if (effectiveIsProfileActive(activeProfile, normalizedProfile)) {
    throw DotweaveError(
      "Cannot remove active profile '$normalizedProfile'.",
      code: 'PROFILE_ACTIVE',
      hint:
          "Switch profiles first with 'dotweave profile use default' or "
          "clear it with 'dotweave profile use'.",
    );
  }

  final referencingEntries = [
    for (final entry in config.entries)
      if (entry.profiles.contains(normalizedProfile)) entry,
  ];

  if (referencingEntries.isNotEmpty) {
    final entryCount = referencingEntries.length;
    throw DotweaveError(
      "Cannot remove profile '$normalizedProfile' because it is still "
      'referenced by $entryCount sync '
      '${entryCount == 1 ? 'entry' : 'entries'}.',
      code: 'PROFILE_IN_USE',
      details: [
        for (final entry in referencingEntries) 'Entry: ${entry.repoPath}',
      ],
      hint:
          'Reassign or clear these entry profile assignments before removing '
          'the profile.',
    );
  }

  final nextConfig = effectiveBuildSyncConfigDocument(
    ResolvedSyncConfig(
      age: config.age,
      entries: config.entries,
      profiles: [
        for (final registeredProfile in config.profiles ?? const <String>[])
          if (registeredProfile != normalizedProfile) registeredProfile,
      ],
      repositoryFormat: config.repositoryFormat,
      version: config.version,
    ),
  );

  await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);

  return ProfileRegistryUpdateResult(
    action: 'removed',
    profile: normalizedProfile,
  );
}

Future<ProfileUpdateResult> clearActiveProfile([
  ProfileDependencies dependencies = const ProfileDependencies(),
]) async {
  final effectiveResolveSyncPaths =
      dependencies.resolveSyncPaths ?? resolveSyncPaths;
  final effectiveRequireGitRepository =
      dependencies.requireGitRepository ?? requireGitRepository;
  final effectiveFormatGlobalDotweaveConfig =
      dependencies.formatGlobalDotweaveConfig ?? formatGlobalDotweaveConfig;
  final effectiveWriteTextFileAtomically =
      dependencies.writeTextFileAtomically ?? writeTextFileAtomically;

  final paths = effectiveResolveSyncPaths();
  final syncDirectory = paths.syncDirectory;
  final globalConfigPath = paths.globalConfigPath;

  await effectiveRequireGitRepository(syncDirectory);

  await effectiveWriteTextFileAtomically(
    globalConfigPath,
    effectiveFormatGlobalDotweaveConfig(
      GlobalDotweaveConfig(version: AppConstants.globalConfig.currentVersion),
    ),
  );

  return ProfileUpdateResult(
    globalConfigPath: globalConfigPath,
    action: 'clear',
  );
}

Future<List<String>> validateProfilesExist(
  List<String> profiles, [
  ProfileDependencies dependencies = const ProfileDependencies(),
]) async {
  final effectiveLoadWritableSyncConfig =
      dependencies.loadWritableSyncConfig ?? loadWritableSyncConfig;
  final effectiveNormalizeSyncProfileName =
      dependencies.normalizeSyncProfileName ?? normalizeSyncProfileName;

  final writable = await effectiveLoadWritableSyncConfig();
  return _normalizeAndRequireKnownProfiles(
    profiles,
    writable.config,
    effectiveNormalizeSyncProfileName,
  );
}

Future<AssignProfilesResult> assignProfiles(
  AssignProfilesRequest request,
  String cwd, [
  ProfileDependencies dependencies = const ProfileDependencies(),
]) async {
  final effectiveLoadWritableSyncConfig =
      dependencies.loadWritableSyncConfig ?? loadWritableSyncConfig;
  final effectiveResolveTrackedEntry =
      dependencies.resolveTrackedEntry ?? resolveTrackedEntry;
  final effectiveNormalizeSyncProfileName =
      dependencies.normalizeSyncProfileName ?? normalizeSyncProfileName;
  final effectiveBuildSyncConfigDocument =
      dependencies.buildSyncConfigDocument ?? buildSyncConfigDocument;
  final effectiveWriteValidatedSyncConfig =
      dependencies.writeValidatedSyncConfig ?? writeValidatedSyncConfig;

  final target = request.target.trim();

  if (target.isEmpty) {
    throw DotweaveError(
      'Target path is required.',
      code: 'TARGET_REQUIRED',
      hint:
          "Pass a tracked entry path, for example 'dotweave track "
          "~/.gitconfig --profile default --profile work'.",
    );
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
    throw DotweaveError(
      'No tracked sync entry matches: $target',
      code: 'TARGET_NOT_TRACKED',
      hint: "Track the root first with 'dotweave track'.",
    );
  }

  final normalizedProfiles = _normalizeAndRequireKnownProfiles(
    request.profiles,
    config,
    effectiveNormalizeSyncProfileName,
  );

  if (entry.profiles.length == normalizedProfiles.length &&
      normalizedProfiles.every(entry.profiles.contains)) {
    return AssignProfilesResult(
      action: 'unchanged',
      entryRepoPath: entry.repoPath,
      profiles: normalizedProfiles,
    );
  }

  final nextConfig = effectiveBuildSyncConfigDocument(
    ResolvedSyncConfig(
      age: config.age,
      entries: [
        for (final e in config.entries)
          if (e.repoPath != entry.repoPath)
            e
          else
            ResolvedSyncConfigEntry(
              configuredMode: e.configuredMode,
              configuredLocalPath: e.configuredLocalPath,
              configuredPermission: e.configuredPermission,
              configuredRepoPath: e.configuredRepoPath,
              kind: e.kind,
              localPath: e.localPath,
              profiles: normalizedProfiles,
              profilesExplicit: normalizedProfiles.isNotEmpty,
              mode: e.mode,
              modeExplicit: e.modeExplicit,
              permission: e.permission,
              permissionExplicit: e.permissionExplicit,
              repoPath: e.repoPath,
            ),
      ],
      profiles: config.profiles,
      repositoryFormat: config.repositoryFormat,
      version: config.version,
    ),
  );

  await effectiveWriteValidatedSyncConfig(syncDirectory, nextConfig);

  return AssignProfilesResult(
    action: 'assigned',
    entryRepoPath: entry.repoPath,
    profiles: normalizedProfiles,
  );
}
