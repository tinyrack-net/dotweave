import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/pull_apply.dart';
import 'package:dotweave/src/services/repo_snapshot.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/git.dart';

// Mirror of `services/doctor.ts`: environment diagnostics over the sync
// repository, configuration, age identity, and tracked local paths.

/// Mirror of the TS `DoctorCheckLevel` union: `fail` | `ok` | `warn`.
typedef DoctorCheckLevel = String;

/// Mirror of the TS `DoctorCheck` readonly object.
class DoctorCheck {
  const DoctorCheck({
    required this.checkId,
    required this.detail,
    required this.level,
  });

  final String checkId;
  final String detail;
  final DoctorCheckLevel level;

  @override
  bool operator ==(Object other) {
    return other is DoctorCheck &&
        other.checkId == checkId &&
        other.detail == detail &&
        other.level == level;
  }

  @override
  int get hashCode => Object.hash(checkId, detail, level);

  @override
  String toString() {
    return 'DoctorCheck(checkId: $checkId, detail: $detail, level: $level)';
  }
}

/// Mirror of the TS `DoctorResult` readonly object.
class DoctorResult {
  const DoctorResult({
    required this.checks,
    required this.hasFailures,
    required this.hasWarnings,
  });

  final List<DoctorCheck> checks;
  final bool hasFailures;
  final bool hasWarnings;

  @override
  bool operator ==(Object other) {
    if (other is! DoctorResult ||
        other.hasFailures != hasFailures ||
        other.hasWarnings != hasWarnings ||
        other.checks.length != checks.length) {
      return false;
    }

    for (var index = 0; index < checks.length; index += 1) {
      if (other.checks[index] != checks[index]) {
        return false;
      }
    }

    return true;
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(checks), hasFailures, hasWarnings);

  @override
  String toString() {
    return 'DoctorResult(checks: $checks, hasFailures: $hasFailures, '
        'hasWarnings: $hasWarnings)';
  }
}

/// Optional overrides for [runDoctorChecks], standing in for the vitest
/// module mocks used by `doctor.test.ts` (git, sync-context, filesystem, and
/// repo-snapshot seams).
class DoctorDependencies {
  const DoctorDependencies({
    this.buildRepositorySnapshot,
    this.loadSyncConfig,
    this.pathExists,
    this.resolveSyncPaths,
    this.verifyIsGitRepository,
  });

  final Future<Map<String, SnapshotNode>> Function(
    String syncDirectory,
    EffectiveSyncConfig config,
  )?
  buildRepositorySnapshot;
  final Future<LoadedSyncConfig> Function(String syncDirectory)? loadSyncConfig;
  final Future<bool> Function(String path)? pathExists;
  final SyncPaths Function()? resolveSyncPaths;
  final Future<void> Function(String directory)? verifyIsGitRepository;
}

DoctorCheck _ok(String checkId, String detail) {
  return DoctorCheck(checkId: checkId, detail: detail, level: 'ok');
}

DoctorCheck _warn(String checkId, String detail) {
  return DoctorCheck(checkId: checkId, detail: detail, level: 'warn');
}

DoctorCheck _fail(String checkId, String detail) {
  return DoctorCheck(checkId: checkId, detail: detail, level: 'fail');
}

/// Mirror of the TS `error instanceof Error` check on caught values.
bool _isErrorLike(Object error) {
  return error is Exception || error is Error;
}

Future<DoctorResult> runDoctorChecks([
  DoctorDependencies dependencies = const DoctorDependencies(),
]) async {
  final effectiveResolveSyncPaths =
      dependencies.resolveSyncPaths ?? resolveSyncPaths;
  final effectiveVerifyIsGitRepository =
      dependencies.verifyIsGitRepository ?? verifyIsGitRepository;
  final effectiveLoadSyncConfig = dependencies.loadSyncConfig ?? loadSyncConfig;
  final effectivePathExists = dependencies.pathExists ?? pathExists;
  final effectiveBuildRepositorySnapshot =
      dependencies.buildRepositorySnapshot ?? buildRepositorySnapshot;

  final syncDirectory = effectiveResolveSyncPaths().syncDirectory;
  final checks = <DoctorCheck>[];

  try {
    await effectiveVerifyIsGitRepository(syncDirectory);
    checks.add(_ok('git', 'Sync directory is a git repository.'));
  } catch (error) {
    checks.add(
      _fail(
        'git',
        _isErrorLike(error)
            ? extractErrorMessage(error)
            : 'Git repository check failed.',
      ),
    );

    return DoctorResult(checks: checks, hasFailures: true, hasWarnings: false);
  }

  final EffectiveSyncConfig config;

  try {
    final loaded = await effectiveLoadSyncConfig(syncDirectory);
    final effectiveConfig = loaded.effectiveConfig;
    final fullConfig = loaded.fullConfig;

    config = effectiveConfig;
    checks.add(
      _ok(
        'config',
        'Loaded config with ${fullConfig.entries.length} entries and '
            '${effectiveConfig.age.recipients.length} recipients.',
      ),
    );
    checks.add(
      _ok(
        'profiles',
        effectiveConfig.activeProfile == null
            ? 'No active profile configured.'
            : 'Active profile: ${effectiveConfig.activeProfile}.',
      ),
    );
  } catch (error) {
    checks.add(
      _fail(
        'config',
        _isErrorLike(error)
            ? formatDotweaveError(error)
            : 'Sync configuration could not be read.',
      ),
    );

    return DoctorResult(checks: checks, hasFailures: true, hasWarnings: false);
  }

  checks.add(
    await effectivePathExists(config.age.identityFile)
        ? _ok('age', 'Age identity file exists at ${config.age.identityFile}.')
        : _fail(
            'age',
            'Age identity file is missing: ${config.age.identityFile}',
          ),
  );

  checks.add(
    config.entries.isEmpty
        ? _warn('entries', 'No sync entries are configured yet.')
        : _ok('entries', 'Tracked ${config.entries.length} sync entries.'),
  );

  final missingEntries = config.entries.where((entry) {
    return entry.mode != 'ignore' && entry.localPath.isNotEmpty;
  }).toList();

  final healthyMissingEntries = <String>{};

  final repositorySnapshot = await effectiveBuildRepositorySnapshot(
    syncDirectory,
    config,
  );
  try {
    for (final entry in missingEntries) {
      if (await effectivePathExists(entry.localPath)) {
        continue;
      }

      buildEntryMaterialization(entry, repositorySnapshot, config);
      healthyMissingEntries.add(entry.repoPath);
    }
  } catch (error) {
    checks.add(
      _fail(
        'local-paths',
        _isErrorLike(error)
            ? formatDotweaveError(error)
            : 'Tracked local paths could not be checked.',
      ),
    );

    final hasFailures = checks.any((check) => check.level == 'fail');
    final hasWarnings = checks.any((check) => check.level == 'warn');

    return DoctorResult(
      checks: checks,
      hasFailures: hasFailures,
      hasWarnings: hasWarnings,
    );
  }

  checks.add(
    _ok(
      'local-paths',
      healthyMissingEntries.isEmpty
          ? 'All tracked local paths currently exist.'
          : 'All missing local paths are healthy for the current sync state '
                '(${healthyMissingEntries.length} '
                'entr${healthyMissingEntries.length == 1 ? 'y' : 'ies'}).',
    ),
  );

  final hasFailures = checks.any((check) => check.level == 'fail');
  final hasWarnings = checks.any((check) => check.level == 'warn');

  return DoctorResult(
    checks: checks,
    hasFailures: hasFailures,
    hasWarnings: hasWarnings,
  );
}
