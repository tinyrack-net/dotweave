import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';

export 'package:dotweave/src/config/sync_schema.dart' show ResolvedSyncConfig;

/// A repository format migration rewrites the on-disk artifacts under a sync
/// repository from one format version to the next. Unlike config migrations
/// (pure object transforms), these touch the filesystem, so they are async and
/// receive the repository directory.
typedef RepoFormatMigrationFn =
    Future<void> Function(
      String repositoryDirectory,
      ResolvedSyncConfig config,
    );

typedef RepoFormatMigrationRegistry = Map<int, RepoFormatMigrationFn>;

class RepoFormatMigrationResult {
  const RepoFormatMigrationResult({
    required this.fromFormat,
    required this.migrated,
  });

  final int fromFormat;
  final bool migrated;
}

/// Verifies a repository's on-disk format is within the range this CLI can
/// operate on: not newer than the current format, and not older than the
/// supported floor. Runs on every config read so all commands fail fast with a
/// clear message.
void assertRepositoryFormatSupported(
  int currentFormat,
  int targetFormat,
  int minSupportedFormat,
  String contextLabel,
) {
  if (currentFormat > targetFormat) {
    throw DotweaveError(
      'Repository format $currentFormat is newer than this CLI supports '
      '(max: $targetFormat).',
      code: 'REPO_FORMAT_NEWER',
      details: [contextLabel],
      hint: 'Upgrade dotweave to the latest version.',
    );
  }

  if (currentFormat < minSupportedFormat) {
    throw DotweaveError(
      'Repository format $currentFormat is older than this CLI supports '
      '(min: $minSupportedFormat).',
      code: 'REPO_FORMAT_TOO_OLD',
      details: [contextLabel],
      hint:
          'Run an older dotweave release to migrate this repository up to '
          'format $minSupportedFormat, then upgrade again.',
    );
  }
}

/// Runs the pending repository-format migrations for a repository, stepping
/// from its current format up to the target. Refuses repositories that are
/// newer than this CLI understands, or older than the supported floor.
Future<RepoFormatMigrationResult> applyRepositoryFormatMigrations(
  String repositoryDirectory,
  ResolvedSyncConfig config,
  RepoFormatMigrationRegistry registry,
  int targetFormat,
  int minSupportedFormat,
) async {
  final currentFormat = config.repositoryFormat ?? 0;

  assertRepositoryFormatSupported(
    currentFormat,
    targetFormat,
    minSupportedFormat,
    'Repository directory: $repositoryDirectory',
  );

  if (currentFormat == targetFormat) {
    return RepoFormatMigrationResult(
      fromFormat: currentFormat,
      migrated: false,
    );
  }

  for (var format = currentFormat; format < targetFormat; format++) {
    final migrateFn = registry[format];

    if (migrateFn == null) {
      throw DotweaveError(
        'No repository format migration found for $format → ${format + 1}.',
        code: 'REPO_FORMAT_MIGRATION_NOT_FOUND',
        details: ['Repository directory: $repositoryDirectory'],
        hint: 'Upgrade dotweave to the latest version.',
      );
    }

    try {
      await migrateFn(repositoryDirectory, config);
    } on DotweaveError catch (error) {
      throw DotweaveError(
        error.message,
        code: error.code,
        details: [
          ...error.details,
          'Repository directory: $repositoryDirectory',
          'Repository format migration: $format → ${format + 1}',
        ],
        hint: error.hint,
      );
    } catch (error) {
      throw DotweaveError(
        'Failed to migrate repository format $format → ${format + 1}.',
        code: 'REPO_FORMAT_MIGRATION_FAILED',
        details: [
          'Repository directory: $repositoryDirectory',
          if (error is Error || error is Exception) extractErrorMessage(error),
        ],
      );
    }
  }

  return RepoFormatMigrationResult(fromFormat: currentFormat, migrated: true);
}
