import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/migration.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/json_format.dart';
import 'package:dotweave/src/lib/jsonc.dart';
import 'package:dotweave/src/lib/validation.dart';
import 'package:dotweave/src/migrations/global_v3.dart';

final ConfigMigrationRegistry _globalConfigMigrationRegistry = {
  2: migrateGlobalConfigV2ToV3,
};

class GlobalDotweaveConfig {
  const GlobalDotweaveConfig({this.activeProfile, required this.version});

  final String? activeProfile;
  final int version;

  /// Serialization order mirrors the TS literal: `activeProfile` (when
  /// present) before `version`.
  Map<String, Object?> toJson() {
    return {
      if (activeProfile != null) 'activeProfile': activeProfile,
      'version': version,
    };
  }
}

/// Mirror of the TS `ActiveProfileSelection` union:
/// `{ mode: "none" }` or `{ profile, mode: "single" }`.
class ActiveProfileSelection {
  const ActiveProfileSelection.none() : profile = null, mode = 'none';

  const ActiveProfileSelection.single(String this.profile) : mode = 'single';

  final String? profile;
  final String mode;
}

/// Zod-style type name used in hand-rolled validation messages.
String _receivedType(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is String) {
    return 'string';
  }
  if (value is num) {
    return 'number';
  }
  if (value is bool) {
    return 'boolean';
  }
  if (value is List) {
    return 'array';
  }
  if (value is Map) {
    return 'object';
  }

  return 'unknown';
}

/// Hand-rolled replacement for the TS Zod schema
/// `z.object({ activeProfile: z.string().trim().min(1).optional(),
/// version: z.literal(3) })`, collecting issues rendered through
/// [formatInputIssues] with Zod v4 default messages.
GlobalDotweaveConfig parseGlobalDotweaveConfig(Object? input) {
  final issues = <ValidationIssue>[];
  String? activeProfile;

  if (input is! Map<String, Object?>) {
    issues.add(
      ValidationIssue(
        path: const [],
        message:
            'Invalid input: expected object, received '
            '${_receivedType(input)}',
      ),
    );
  } else {
    if (input.containsKey('activeProfile')) {
      final rawActiveProfile = input['activeProfile'];

      if (rawActiveProfile is! String) {
        issues.add(
          ValidationIssue(
            path: const ['activeProfile'],
            message:
                'Invalid input: expected string, received '
                '${_receivedType(rawActiveProfile)}',
          ),
        );
      } else {
        final trimmedActiveProfile = rawActiveProfile.trim();

        if (trimmedActiveProfile.isEmpty) {
          issues.add(
            const ValidationIssue(
              path: ['activeProfile'],
              message: 'Too small: expected string to have >=1 characters',
            ),
          );
        } else {
          activeProfile = trimmedActiveProfile;
        }
      }
    }

    final rawVersion = input['version'];

    if (rawVersion is! num ||
        rawVersion != AppConstants.globalConfig.currentVersion) {
      issues.add(
        ValidationIssue(
          path: const ['version'],
          message:
              'Invalid input: expected '
              '${AppConstants.globalConfig.currentVersion}',
        ),
      );
    }
  }

  if (issues.isNotEmpty) {
    throw DotweaveError(
      'Global dotweave configuration is invalid.',
      code: 'GLOBAL_CONFIG_VALIDATION_FAILED',
      details: formatInputIssues(issues).split('\n'),
      hint:
          'Fix ~/.config/dotweave/settings.jsonc, then run the command '
          'again.',
    );
  }

  return GlobalDotweaveConfig(
    activeProfile: activeProfile == null
        ? null
        : normalizeSyncProfileName(activeProfile),
    version: AppConstants.globalConfig.currentVersion,
  );
}

String formatGlobalDotweaveConfig(GlobalDotweaveConfig config) {
  return formatJsonPretty(config.toJson());
}

Future<GlobalDotweaveConfig?> readGlobalDotweaveConfig(String filePath) async {
  final resolvedPath = await validateJsoncConfigPath(filePath);
  try {
    final contents = await File(resolvedPath).readAsString();
    final parsed = parseJsonc(contents);
    final migration = applyConfigMigrations(
      parsed,
      _globalConfigMigrationRegistry,
      AppConstants.globalConfig.currentVersion,
      resolvedPath,
    );
    final validated = parseGlobalDotweaveConfig(migration.config);

    // Persist only after validation succeeds (shared writer, same behavior
    // as the manifest reader).
    final originalVersion = migration.originalVersion;
    if (migration.migrated && originalVersion != null) {
      await persistMigratedConfig(
        resolvedPath,
        parsed,
        migration.config,
        originalVersion,
      );
    }

    return validated;
  } on DotweaveError {
    rethrow;
  } on FormatException catch (error) {
    throw DotweaveError(
      'Global dotweave configuration is not valid JSON.',
      code: 'GLOBAL_CONFIG_INVALID_JSON',
      details: ['Config file: $resolvedPath', error.message],
      hint:
          'Fix the JSON syntax in ~/.config/dotweave/settings.jsonc, then '
          'run the command again.',
    );
  } on PathNotFoundException {
    return null;
  } catch (error) {
    throw DotweaveError(
      'Failed to read global dotweave configuration.',
      code: 'GLOBAL_CONFIG_READ_FAILED',
      details: ['Config file: $resolvedPath', extractErrorMessage(error)],
    );
  }
}

ActiveProfileSelection resolveActiveProfileSelection(
  GlobalDotweaveConfig? config,
) {
  final activeProfile = config?.activeProfile;

  if (activeProfile == null) {
    return const ActiveProfileSelection.none();
  }

  return ActiveProfileSelection.single(activeProfile);
}

bool isProfileActive(ActiveProfileSelection selection, String? profile) {
  if (profile == null) {
    return true;
  }

  if (selection.mode == 'none') {
    return false;
  }

  return selection.profile == profile;
}
