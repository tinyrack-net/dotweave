import 'dart:io';

import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/json_format.dart';
import 'package:path/path.dart' as p;

typedef ConfigMigrationFn =
    Map<String, Object?> Function(Map<String, Object?> config);

typedef ConfigMigrationRegistry = Map<int, ConfigMigrationFn>;

class ConfigMigrationResult {
  const ConfigMigrationResult({
    required this.config,
    required this.migrated,
    this.originalVersion,
  });

  final Object? config;
  final bool migrated;
  final int? originalVersion;
}

DotweaveError _withMigrationContext(
  DotweaveError error,
  String filePath,
  int fromVersion,
) {
  return DotweaveError(
    error.message,
    code: error.code,
    details: [
      ...error.details,
      'Config file: $filePath',
      'Migration: $fromVersion → ${fromVersion + 1}',
    ],
    hint: error.hint,
  );
}

ConfigMigrationResult applyConfigMigrations(
  Object? rawConfig,
  ConfigMigrationRegistry registry,
  int targetVersion,
  String filePath,
) {
  if (rawConfig is! Map<String, Object?>) {
    return ConfigMigrationResult(config: rawConfig, migrated: false);
  }

  final version = rawConfig['version'];

  if (version is! int) {
    return ConfigMigrationResult(config: rawConfig, migrated: false);
  }

  if (version == targetVersion) {
    return ConfigMigrationResult(
      config: rawConfig,
      migrated: false,
      originalVersion: version,
    );
  }

  if (version > targetVersion) {
    throw DotweaveError(
      'Config file version $version is newer than this CLI supports '
      '(max: $targetVersion).',
      code: 'CONFIG_NEWER_VERSION',
      details: ['Config file: $filePath'],
      hint: 'Upgrade dotweave to the latest version.',
    );
  }

  var current = rawConfig;

  for (var v = version; v < targetVersion; v++) {
    final migrateFn = registry[v];

    if (migrateFn == null) {
      throw DotweaveError(
        'No migration path found for config version $v → ${v + 1}.',
        code: 'CONFIG_MIGRATION_NOT_FOUND',
        details: ['Config file: $filePath'],
        hint: 'Upgrade dotweave to the latest version.',
      );
    }

    try {
      current = migrateFn(current);
    } catch (error) {
      if (error is DotweaveError) {
        throw _withMigrationContext(error, filePath, v);
      }

      throw DotweaveError(
        'Failed to migrate config from version $v to ${v + 1}.',
        code: 'CONFIG_MIGRATION_FAILED',
        details: [
          'Config file: $filePath',
          'Migration: $v → ${v + 1}',
          extractErrorMessage(error),
        ],
      );
    }
  }

  return ConfigMigrationResult(
    config: current,
    migrated: true,
    originalVersion: version,
  );
}

/// Persists a migrated config: writes a `.v<originalVersion>.bak` backup of
/// the original raw config, then atomically rewrites the file with the
/// migrated one. Shared by every config reader so backup/rewrite behaves
/// identically, and is always called AFTER semantic validation so an invalid
/// migration is never persisted.
Future<void> persistMigratedConfig(
  String filePath,
  Object? originalRawConfig,
  Object? migratedConfig,
  int originalVersion,
) async {
  final backupPath = p.join(
    p.dirname(filePath),
    '${p.basename(filePath)}.v$originalVersion.bak',
  );
  await File(backupPath).writeAsString(formatJsonPretty(originalRawConfig));

  await writeTextFileAtomically(filePath, formatJsonPretty(migratedConfig));
}

/// Applies sequential config migrations from the detected version up to
/// targetVersion. Creates a backup file before the first migration step, then
/// saves the result. Returns the migrated config (or the original if no
/// migration was needed).
Future<Object?> runConfigMigrations(
  Object? rawConfig,
  ConfigMigrationRegistry registry,
  int targetVersion,
  String filePath,
) async {
  final result = applyConfigMigrations(
    rawConfig,
    registry,
    targetVersion,
    filePath,
  );

  final originalVersion = result.originalVersion;

  if (!result.migrated || originalVersion == null) {
    return result.config;
  }

  await persistMigratedConfig(
    filePath,
    rawConfig,
    result.config,
    originalVersion,
  );

  return result.config;
}
