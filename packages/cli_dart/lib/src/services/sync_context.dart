import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/global_config.dart';
import 'package:dotweave/src/config/identity_file.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/git.dart';

// Mirror of `services/sync-context.ts`: effective sync config construction
// and loading of the sync/global configuration pair.

/// Mirror of the TS `RuntimeAgeConfig` readonly object.
class RuntimeAgeConfig {
  const RuntimeAgeConfig({
    required this.identityFile,
    required this.recipients,
  });

  final String identityFile;
  final List<String> recipients;
}

/// Mirror of the TS `SyncPaths` readonly object.
class SyncPaths {
  const SyncPaths({
    required this.configPath,
    required this.globalConfigPath,
    required this.homeDirectory,
    required this.syncDirectory,
  });

  final String configPath;
  final String globalConfigPath;
  final String homeDirectory;
  final String syncDirectory;
}

/// Mirror of the TS `EffectiveSyncConfig` intersection type
/// (`ResolvedSyncConfig & { activeProfile?, age }`). The TS spread overrides
/// the resolved `age` (AgeConfig) with the runtime [RuntimeAgeConfig], so the
/// Dart class carries the [ResolvedSyncConfig] fields directly with `age`
/// typed as [RuntimeAgeConfig].
class EffectiveSyncConfig {
  const EffectiveSyncConfig({
    this.activeProfile,
    required this.age,
    required this.entries,
    this.profiles,
    this.repositoryFormat,
    required this.version,
  });

  final String? activeProfile;
  final RuntimeAgeConfig age;
  final List<ResolvedSyncConfigEntry> entries;
  final List<String>? profiles;
  final int? repositoryFormat;
  final int version;
}

/// Mirror of the TS `LoadedSyncConfig` readonly object.
class LoadedSyncConfig {
  const LoadedSyncConfig({
    required this.effectiveConfig,
    required this.fullConfig,
    this.globalConfig,
  });

  final EffectiveSyncConfig effectiveConfig;
  final ResolvedSyncConfig fullConfig;
  final GlobalDotweaveConfig? globalConfig;
}

SyncConfigResolutionContext resolveSyncConfigResolutionContext() {
  return SyncConfigResolutionContext(
    homeDirectory: resolveHomeDirectoryFromEnv(),
    platformKey: resolveCurrentPlatformKey(),
    readEnv: readEnvValue,
    xdgConfigHome: resolveXdgConfigHomeFromEnv(),
  );
}

SyncPaths resolveSyncPaths() {
  final syncDirectory = resolveDotweaveSyncDirectoryFromEnv();

  return SyncPaths(
    configPath: resolveSyncConfigFilePath(syncDirectory),
    globalConfigPath: resolveDotweaveGlobalConfigFilePathFromEnv(),
    homeDirectory: resolveHomeDirectoryFromEnv(),
    syncDirectory: syncDirectory,
  );
}

RuntimeAgeConfig resolveAgeFromSyncConfig(AgeConfig age) {
  return RuntimeAgeConfig(
    identityFile: resolveDefaultIdentityFile(
      resolveDotweaveHomeDirectoryFromEnv(),
    ),
    recipients: age.recipients,
  );
}

EffectiveSyncConfig buildEffectiveSyncConfig(
  ResolvedSyncConfig fullConfig,
  ActiveProfileSelection selection,
  RuntimeAgeConfig age,
) {
  final activeProfile = selection.mode == 'single'
      ? normalizeSyncProfileName(selection.profile!)
      : null;

  final effectiveProfile =
      activeProfile != null && activeProfile != AppConstants.sync.defaultProfile
      ? activeProfile
      : AppConstants.sync.defaultProfile;

  if (effectiveProfile != AppConstants.sync.defaultProfile &&
      !(fullConfig.profiles ?? const <String>[]).contains(effectiveProfile)) {
    throw DotweaveError(
      "Unknown profile '$effectiveProfile'.",
      code: 'UNKNOWN_PROFILE',
      hint:
          "Add it with 'dotweave profile add $effectiveProfile', or choose "
          'an existing profile.',
    );
  }

  final entries = [
    for (final entry in fullConfig.entries)
      if (entry.profiles.isEmpty || entry.profiles.contains(effectiveProfile))
        entry,
  ];

  return EffectiveSyncConfig(
    activeProfile: activeProfile,
    age: age,
    entries: entries,
    profiles: fullConfig.profiles,
    repositoryFormat: fullConfig.repositoryFormat,
    version: fullConfig.version,
  );
}

Future<LoadedSyncConfig> loadSyncConfig(
  String syncDirectory, {
  String? profile,
}) async {
  final context = resolveSyncConfigResolutionContext();
  final fullConfig = await readSyncConfig(syncDirectory, context);
  final globalConfig = await readGlobalDotweaveConfig(
    resolveDotweaveGlobalConfigFilePathFromEnv(),
  );
  final selection = profile == null
      ? resolveActiveProfileSelection(globalConfig)
      : ActiveProfileSelection.single(profile);

  final rawAge = fullConfig.age;

  if (rawAge == null) {
    final configPath = resolveSyncConfigFilePath(syncDirectory);
    throw DotweaveError(
      'Age configuration is missing from ${AppConstants.sync.configFileName}.',
      code: 'AGE_CONFIG_MISSING',
      details: ['Config file: $configPath'],
      hint: "Run 'dotweave init' to set up encryption.",
    );
  }

  final age = resolveAgeFromSyncConfig(rawAge);

  return LoadedSyncConfig(
    effectiveConfig: buildEffectiveSyncConfig(fullConfig, selection, age),
    fullConfig: fullConfig,
    globalConfig: globalConfig,
  );
}

/// Mirror of the TS `WritableSyncConfig` readonly object.
class WritableSyncConfig {
  const WritableSyncConfig({
    required this.config,
    required this.configPath,
    required this.context,
    required this.syncDirectory,
  });

  final ResolvedSyncConfig config;
  final String configPath;
  final SyncConfigResolutionContext context;
  final String syncDirectory;
}

/// Optional overrides for [loadWritableSyncConfig], standing in for the
/// vitest module mocks used by `sync-context.writable.test.ts`.
class SyncContextDependencies {
  const SyncContextDependencies({
    this.readSyncConfig,
    this.requireGitRepository,
    this.resolveSyncConfigResolutionContext,
    this.resolveSyncPaths,
  });

  final Future<ResolvedSyncConfig> Function(
    String syncDirectory,
    SyncConfigResolutionContext context,
  )?
  readSyncConfig;
  final Future<void> Function(String syncDirectory)? requireGitRepository;
  final SyncConfigResolutionContext Function()?
  resolveSyncConfigResolutionContext;
  final SyncPaths Function()? resolveSyncPaths;
}

Future<WritableSyncConfig> loadWritableSyncConfig([
  SyncContextDependencies dependencies = const SyncContextDependencies(),
]) async {
  final effectiveResolveSyncPaths =
      dependencies.resolveSyncPaths ?? resolveSyncPaths;
  final effectiveResolveSyncConfigResolutionContext =
      dependencies.resolveSyncConfigResolutionContext ??
      resolveSyncConfigResolutionContext;
  final effectiveRequireGitRepository =
      dependencies.requireGitRepository ?? requireGitRepository;
  final effectiveReadSyncConfig = dependencies.readSyncConfig ?? readSyncConfig;

  final paths = effectiveResolveSyncPaths();
  final syncDirectory = paths.syncDirectory;
  final configPath = paths.configPath;
  final context = effectiveResolveSyncConfigResolutionContext();
  await effectiveRequireGitRepository(syncDirectory);
  final config = await effectiveReadSyncConfig(syncDirectory, context);
  return WritableSyncConfig(
    config: config,
    configPath: configPath,
    context: context,
    syncDirectory: syncDirectory,
  );
}
