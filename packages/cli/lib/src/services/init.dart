import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/global_config.dart';
import 'package:dotweave/src/config/identity_file.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/repository_ignore.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/crypto.dart';
import 'package:dotweave/src/util/env.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/git.dart';
import 'package:dotweave/src/util/jsonc.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/init.ts`: sync repository creation/cloning, age
// identity bootstrap, and the initial manifest / global settings writes.

/// Mirror of the TS `InitRequest` readonly object.
class InitRequest {
  const InitRequest({
    this.ageIdentity,
    this.force,
    this.generateAgeIdentity,
    this.identityFile,
    required this.recipients,
    this.repository,
  });

  final String? ageIdentity;
  final bool? force;
  final bool? generateAgeIdentity;
  final String? identityFile;
  final List<String> recipients;
  final String? repository;
}

/// Mirror of the TS `InitResult` readonly object. The TS `gitAction` union
/// (`cloned` | `existing` | `initialized`) is carried as a plain string.
class InitResult {
  const InitResult({
    required this.alreadyInitialized,
    required this.entryCount,
    required this.gitAction,
    this.gitSource,
    required this.identityFile,
    required this.generatedIdentity,
    required this.recipientCount,
  });

  final bool alreadyInitialized;
  final int entryCount;
  final String gitAction;
  final String? gitSource;
  final String identityFile;
  final bool generatedIdentity;
  final int recipientCount;

  @override
  bool operator ==(Object other) {
    return other is InitResult &&
        other.alreadyInitialized == alreadyInitialized &&
        other.entryCount == entryCount &&
        other.gitAction == gitAction &&
        other.gitSource == gitSource &&
        other.identityFile == identityFile &&
        other.generatedIdentity == generatedIdentity &&
        other.recipientCount == recipientCount;
  }

  @override
  int get hashCode => Object.hash(
    alreadyInitialized,
    entryCount,
    gitAction,
    gitSource,
    identityFile,
    generatedIdentity,
    recipientCount,
  );

  @override
  String toString() {
    return 'InitResult(alreadyInitialized: $alreadyInitialized, '
        'entryCount: $entryCount, gitAction: $gitAction, '
        'gitSource: $gitSource, identityFile: $identityFile, '
        'generatedIdentity: $generatedIdentity, '
        'recipientCount: $recipientCount)';
  }
}

/// Optional overrides for [initializeSyncDirectory], standing in for the
/// vitest seams used by `init.test.ts`:
///
/// - [env] replaces the `#app/lib/env.ts` `ENV` module mock. All env-derived
///   path resolution inside this module threads it through, matching how the
///   TS mock propagates into `sync-context.ts` / `runtime-env.ts`.
/// - [initializeRepository] / [verifyIsGitRepository] replace the
///   `vi.stubEnv("PATH", "")` stub: Dart cannot alter the environment seen by
///   spawned git children in-process, so the two git entry points are
///   injectable instead.
class InitDependencies {
  const InitDependencies({
    this.env,
    this.initializeRepository,
    this.verifyIsGitRepository,
  });

  final Env? env;
  final Future<InitializeRepositoryResult> Function(
    String directory, [
    String? source,
  ])?
  initializeRepository;
  final Future<void> Function(String directory)? verifyIsGitRepository;
}

const String _gitAttributesFileName = '.gitattributes';
const String _gitAttributesContents = '* -text\n';

DotweaveError createMissingRepositoryAgeKeyError() {
  return DotweaveError(
    'Existing repository setup requires an age private key.',
    code: 'INIT_AGE_IDENTITY_REQUIRED',
    hint:
        "Provide your existing age private key with '--key-file', or enter "
        'it when prompted in an interactive terminal.',
  );
}

/// The age-identity decision `init` makes before touching the repository.
///
/// [shouldPrompt] is the only part the CLI acts on directly; everything else
/// feeds [resolveAgeIdentity].
typedef AgeIdentityPlan = ({
  /// Contents of `--key-file`, read and trimmed. Null when absent or blank.
  String? providedKey,

  /// Whether the caller must ask the user for a key before continuing.
  bool shouldPrompt,

  /// Whether an existing repository is being adopted rather than created.
  bool importingRepository,

  /// Whether a usable identity file is already on disk (always false under
  /// `--force`, which regenerates).
  bool identityFileExists,
});

/// Reads `--key-file` and decides whether `init` needs to prompt for a key.
///
/// This precedence -- explicit key beats prompt beats existing identity beats
/// generating a new one -- is a domain rule, and it used to be spread across
/// five booleans in the `init` command, alongside a raw `File(...).readAsString`.
Future<AgeIdentityPlan> planAgeIdentity({
  required String? keyFile,
  required String? repository,
  required bool force,
  Future<String> Function(String path)? readKeyFile,
  String Function()? resolveIdentityFile,
  Future<bool> Function(String path)? identityFileExists,
}) async {
  final read = readKeyFile ?? (path) => File(path).readAsString();
  final identityFile =
      (resolveIdentityFile ??
      () =>
          resolveDefaultIdentityFile(resolveDotweaveHomeDirectoryFromEnv()))();
  final exists = identityFileExists ?? pathExists;

  final rawKey = keyFile == null ? null : (await read(keyFile)).trim();
  final providedKey = rawKey == null || rawKey.isEmpty ? null : rawKey;
  // `--force` regenerates, so an identity already on disk does not count.
  final hasIdentityFile = force ? false : await exists(identityFile);
  final importingRepository =
      repository != null && repository.trim().isNotEmpty;

  return (
    providedKey: providedKey,
    // A key file that was given but turned out blank still counts as "asked
    // and answered": do not prompt on top of it.
    shouldPrompt:
        providedKey == null &&
        keyFile == null &&
        !hasIdentityFile &&
        importingRepository,
    importingRepository: importingRepository,
    identityFileExists: hasIdentityFile,
  );
}

/// Final identity decision, given the answer to the prompt [plan] asked for
/// (null when it did not ask).
///
/// Throws when an existing repository is being adopted with no key at all,
/// since its artifacts would be undecryptable.
({String? ageIdentity, bool generateAgeIdentity}) resolveAgeIdentity(
  AgeIdentityPlan plan,
  String? promptAnswer,
) {
  final trimmedAnswer = promptAnswer?.trim();

  if (plan.importingRepository &&
      plan.providedKey == null &&
      trimmedAnswer == '') {
    throw createMissingRepositoryAgeKeyError();
  }

  return (
    ageIdentity:
        plan.providedKey ??
        (trimmedAnswer != null && trimmedAnswer.isNotEmpty
            ? trimmedAnswer
            : null),
    generateAgeIdentity:
        !plan.importingRepository &&
        plan.providedKey == null &&
        (trimmedAnswer == '' ||
            (trimmedAnswer == null && !plan.identityFileExists)),
  );
}

DotweaveError createAlreadyInitializedError(String syncDirectory) {
  return DotweaveError(
    'Sync directory is already initialized.',
    code: 'INIT_ALREADY_INITIALIZED',
    details: ['Sync directory: $syncDirectory'],
    hint:
        "Use 'dotweave init --force' to replace the local sync repository "
        'data.',
  );
}

List<String> _normalizeRecipients(List<String> recipients) {
  return {
    for (final recipient in recipients.map((recipient) => recipient.trim()))
      if (recipient.isNotEmpty) recipient,
  }.toList()..sort(compareLocaleLike);
}

/// Mirror of the TS `resolveSyncPaths` from `services/sync-context.ts` with
/// the [Env] seam threaded through in place of the mocked `ENV` module.
SyncPaths _resolveSyncPathsWithEnv(Env? env) {
  final syncDirectory = resolveDotweaveSyncDirectoryFromEnv(env: env);

  return SyncPaths(
    configPath: resolveSyncConfigFilePath(syncDirectory),
    globalConfigPath: resolveDotweaveGlobalConfigFilePathFromEnv(env: env),
    homeDirectory: resolveHomeDirectoryFromEnv(env: env),
    syncDirectory: syncDirectory,
  );
}

/// Mirror of the TS `resolveSyncConfigResolutionContext` from
/// `services/sync-context.ts` with the [Env] seam threaded through.
SyncConfigResolutionContext _resolveSyncConfigResolutionContextWithEnv(
  Env? env,
) {
  return SyncConfigResolutionContext(
    homeDirectory: resolveHomeDirectoryFromEnv(env: env),
    platformKey: resolveCurrentPlatformKey(env: env),
    readEnv: (name) => readEnvValue(name, env: env),
    xdgConfigHome: resolveXdgConfigHomeFromEnv(env: env),
  );
}

/// Mirror of the TS `resolveAgeFromSyncConfig` from
/// `services/sync-context.ts` with the [Env] seam threaded through.
RuntimeAgeConfig _resolveAgeFromSyncConfigWithEnv(AgeConfig age, Env? env) {
  return RuntimeAgeConfig(
    identityFile: resolveDefaultIdentityFile(
      resolveDotweaveHomeDirectoryFromEnv(env: env),
    ),
    recipients: age.recipients,
  );
}

Future<({bool generatedIdentity, List<String> recipients})>
_resolveInitAgeBootstrap(InitRequest request, Env? env) async {
  final identityFile = resolveDefaultIdentityFile(
    resolveDotweaveHomeDirectoryFromEnv(env: env),
  );
  final explicitRecipients = _normalizeRecipients(request.recipients);
  final ageIdentity = request.ageIdentity;

  if (ageIdentity != null) {
    final keyPair = await writeAgeIdentityFile(identityFile, ageIdentity);

    return (
      generatedIdentity: false,
      recipients: _normalizeRecipients([
        ...explicitRecipients,
        keyPair.recipient,
      ]),
    );
  }

  if (explicitRecipients.isEmpty) {
    if (await pathExists(identityFile)) {
      return (
        generatedIdentity: false,
        recipients: _normalizeRecipients(
          await readAgeRecipientsFromIdentityFile(identityFile),
        ),
      );
    }

    final keyPair = await createAgeIdentityFile(identityFile);

    return (generatedIdentity: true, recipients: [keyPair.recipient]);
  }

  if (request.generateAgeIdentity == true) {
    final keyPair = await createAgeIdentityFile(identityFile);

    return (
      generatedIdentity: true,
      recipients: _normalizeRecipients([
        ...explicitRecipients,
        keyPair.recipient,
      ]),
    );
  }

  if (await pathExists(identityFile)) {
    return (generatedIdentity: false, recipients: explicitRecipients);
  }

  final keyPair = await createAgeIdentityFile(identityFile);

  return (
    generatedIdentity: true,
    recipients: _normalizeRecipients([
      ...explicitRecipients,
      keyPair.recipient,
    ]),
  );
}

Future<void> _writeGlobalSettings(String globalConfigPath) async {
  final existingGlobalConfig = await readGlobalDotweaveConfig(globalConfigPath);
  final globalConfigToWrite = GlobalDotweaveConfig(
    activeProfile:
        existingGlobalConfig?.activeProfile ?? AppConstants.sync.defaultProfile,
    version: AppConstants.globalConfig.currentVersion,
  );
  await Directory(p.dirname(globalConfigPath)).create(recursive: true);
  await writeTextFileAtomically(
    globalConfigPath,
    formatGlobalDotweaveConfig(globalConfigToWrite),
  );
}

Future<void> _ensureManagedRepositoryAttributes(String syncDirectory) async {
  final attributesPath = p.join(syncDirectory, _gitAttributesFileName);

  if (await pathExists(attributesPath)) {
    final existingContents = await File(attributesPath).readAsString();

    if (existingContents == _gitAttributesContents) {
      return;
    }
  }

  await writeTextFileAtomically(attributesPath, _gitAttributesContents);
}

Future<InitResult> initializeSyncDirectory(
  InitRequest request, [
  InitDependencies dependencies = const InitDependencies(),
]) async {
  final env = dependencies.env;
  final effectiveVerifyIsGitRepository =
      dependencies.verifyIsGitRepository ?? verifyIsGitRepository;
  final effectiveInitializeRepository =
      dependencies.initializeRepository ?? initializeRepository;

  final paths = _resolveSyncPathsWithEnv(env);
  final syncDirectory = paths.syncDirectory;
  final configPath = paths.configPath;
  final globalConfigPath = paths.globalConfigPath;
  final context = _resolveSyncConfigResolutionContextWithEnv(env);
  final identityFile = resolveDefaultIdentityFile(
    resolveDotweaveHomeDirectoryFromEnv(env: env),
  );

  if (request.force == true) {
    await removePath(syncDirectory);
    await removePath(identityFile);
    await removePath(globalConfigPath);
  }

  final resolvedConfigPath = await validateJsoncConfigPath(configPath);
  final configExists = await pathExists(resolvedConfigPath);
  final importingRepository =
      request.repository != null && request.repository!.trim() != '';

  if (importingRepository &&
      request.ageIdentity == null &&
      !(await pathExists(identityFile))) {
    throw createMissingRepositoryAgeKeyError();
  }

  if (configExists) {
    throw createAlreadyInitializedError(syncDirectory);
  }

  await Directory(p.dirname(syncDirectory)).create(recursive: true);

  var gitAction = 'existing';
  String? gitSource;

  try {
    await effectiveVerifyIsGitRepository(syncDirectory);
  } on DotweaveError {
    // Any git-level failure here means "not a usable repository yet", and the
    // recovery below re-runs git so a missing executable still surfaces with
    // its own message and hint. Narrowed from a bare catch so that a defect
    // in the Dart code above is no longer silently read as "not a repo".

    final syncDirectoryExists = await pathExists(syncDirectory);

    if (syncDirectoryExists) {
      final entries = await Directory(
        syncDirectory,
      ).list(followLinks: false).toList();

      if (entries.isNotEmpty) {
        throw DotweaveError(
          'Sync directory already exists and is not empty.',
          code: 'SYNC_DIR_NOT_EMPTY',
          details: ['Sync directory: $syncDirectory'],
          hint:
              'Empty the directory, remove it, or point init at a different '
              'repository source.',
        );
      }
    }

    final trimmedRepository = request.repository?.trim();
    final gitSourceInput =
        trimmedRepository == null || trimmedRepository.isEmpty
        ? null
        : trimmedRepository;
    final InitializeRepositoryResult gitResult;

    try {
      gitResult = await effectiveInitializeRepository(
        syncDirectory,
        gitSourceInput,
      );
    } catch (error) {
      final errorMessage = gitSourceInput == null
          ? 'Failed to initialize the sync directory.'
          : 'Failed to clone the sync directory.';
      final errorCode = gitSourceInput == null
          ? 'SYNC_INIT_GIT_FAILED'
          : 'SYNC_CLONE_FAILED';
      final details = [
        'Sync directory: $syncDirectory',
        if (gitSourceInput != null) 'Repository source: $gitSourceInput',
      ];

      if (isMissingGitExecutableError(error)) {
        throw DotweaveError(
          errorMessage,
          code: errorCode,
          details: [
            ...details,
            // The TS `error instanceof Error ? error.message : ...` fallback:
            // a missing-git error is always a DotweaveError here.
            extractErrorMessage(error),
          ],
          hint:
              'Install Git and ensure the git executable is available on '
              'PATH, then run dotweave init again.',
        );
      }

      throw wrapUnknownError(
        errorMessage,
        error,
        code: errorCode,
        details: details,
        hint: gitSourceInput == null
            ? 'Check that git is installed and the sync directory is '
                  'writable.'
            : 'Check that the repository source is reachable and you have '
                  'access to it.',
      );
    }

    gitAction = gitResult.action;
    gitSource = gitResult.source;
  }

  await Directory(syncDirectory).create(recursive: true);
  await _ensureManagedRepositoryAttributes(syncDirectory);
  await ensureManagedSecretArtifactIgnoreRules(syncDirectory);

  if (await pathExists(await validateJsoncConfigPath(configPath))) {
    final config = await readSyncConfig(syncDirectory, context);

    final ageBootstrap = await _resolveInitAgeBootstrap(request, env);

    await _writeGlobalSettings(globalConfigPath);

    final configAge = config.age;
    final age = configAge != null
        ? _resolveAgeFromSyncConfigWithEnv(configAge, env)
        : null;

    return InitResult(
      alreadyInitialized: false,
      entryCount: config.entries.length,
      gitAction: gitAction,
      gitSource: gitSource,
      generatedIdentity: ageBootstrap.generatedIdentity,
      identityFile:
          age?.identityFile ??
          resolveDefaultIdentityFile(
            resolveDotweaveHomeDirectoryFromEnv(env: env),
          ),
      recipientCount: age?.recipients.length ?? 0,
    );
  }

  final ageBootstrap = await _resolveInitAgeBootstrap(request, env);

  await _writeGlobalSettings(globalConfigPath);

  final initialConfig = createInitialSyncConfig(
    AgeConfig(
      recipients: {
        for (final recipient in ageBootstrap.recipients) recipient.trim(),
      }.toList(),
    ),
  );

  parseSyncConfig(initialConfig.toJson(), context);
  await File(configPath).writeAsString(formatSyncConfig(initialConfig));

  return InitResult(
    alreadyInitialized: false,
    entryCount: 0,
    gitAction: gitAction,
    gitSource: gitSource,
    generatedIdentity: ageBootstrap.generatedIdentity,
    identityFile: resolveDefaultIdentityFile(
      resolveDotweaveHomeDirectoryFromEnv(env: env),
    ),
    recipientCount: ageBootstrap.recipients.length,
  );
}
