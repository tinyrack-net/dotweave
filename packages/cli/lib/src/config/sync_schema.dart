import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/migration.dart';
import 'package:dotweave/src/config/migrations/sync_v8.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/repo_format_migration.dart';
import 'package:dotweave/src/config/xdg.dart';
import 'package:dotweave/src/util/collation.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/file_mode.dart';
import 'package:dotweave/src/util/json_format.dart';
import 'package:dotweave/src/util/jsonc.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:dotweave/src/util/validation.dart';
import 'package:path/path.dart' as p;

// Mirror of `config/sync-schema.ts`: manifest.jsonc schema validation
// (hand-rolled replacement for the TS Zod schemas), normalization, entry
// inheritance, resolution, overlap validation, and serialization.

final ConfigMigrationRegistry _syncConfigMigrationRegistry = {
  7: migrateSyncConfigV7ToV8,
};

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

/// Mirror of the TS `SyncConfigEntryKind` union: `file` | `directory`.
typedef SyncConfigEntryKind = String;

/// Mirror of the TS `SyncMode` union: `normal` | `secret` | `ignore`.
typedef SyncMode = String;

/// Mirror of the TS `ConfiguredSyncRepoPath` alias.
typedef ConfiguredSyncRepoPath = PlatformStringValue;

/// Mirror of the TS `PlatformSyncMode` object: a default sync mode plus
/// optional per-platform overrides. The TS `default` field is named
/// [defaultValue] because `default` is a reserved word in Dart.
class PlatformSyncMode {
  const PlatformSyncMode({
    required this.defaultValue,
    this.win,
    this.mac,
    this.linux,
    this.wsl,
  });

  final SyncMode defaultValue;
  final SyncMode? win;
  final SyncMode? mac;
  final SyncMode? linux;
  final SyncMode? wsl;

  /// Serialization order mirrors the TS schema shape:
  /// default, win, mac, linux, wsl.
  Map<String, Object?> toJson() {
    return {
      'default': defaultValue,
      if (win != null) 'win': win,
      if (mac != null) 'mac': mac,
      if (linux != null) 'linux': linux,
      if (wsl != null) 'wsl': wsl,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is PlatformSyncMode &&
        other.defaultValue == defaultValue &&
        other.win == win &&
        other.mac == mac &&
        other.linux == linux &&
        other.wsl == wsl;
  }

  @override
  int get hashCode => Object.hash(defaultValue, win, mac, linux, wsl);

  @override
  String toString() {
    return 'PlatformSyncMode(default: $defaultValue'
        '${win == null ? '' : ', win: $win'}'
        '${mac == null ? '' : ', mac: $mac'}'
        '${linux == null ? '' : ', linux: $linux'}'
        '${wsl == null ? '' : ', wsl: $wsl'})';
  }
}

/// Mirror of the TS `PlatformPermission` object: a default octal permission
/// string plus optional per-platform overrides.
class PlatformPermission {
  const PlatformPermission({
    required this.defaultValue,
    this.win,
    this.mac,
    this.linux,
    this.wsl,
  });

  final String defaultValue;
  final String? win;
  final String? mac;
  final String? linux;
  final String? wsl;

  /// Serialization order mirrors the TS schema shape:
  /// default, win, mac, linux, wsl.
  Map<String, Object?> toJson() {
    return {
      'default': defaultValue,
      if (win != null) 'win': win,
      if (mac != null) 'mac': mac,
      if (linux != null) 'linux': linux,
      if (wsl != null) 'wsl': wsl,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is PlatformPermission &&
        other.defaultValue == defaultValue &&
        other.win == win &&
        other.mac == mac &&
        other.linux == linux &&
        other.wsl == wsl;
  }

  @override
  int get hashCode => Object.hash(defaultValue, win, mac, linux, wsl);

  @override
  String toString() {
    return 'PlatformPermission(default: $defaultValue'
        '${win == null ? '' : ', win: $win'}'
        '${mac == null ? '' : ', mac: $mac'}'
        '${linux == null ? '' : ', linux: $linux'}'
        '${wsl == null ? '' : ', wsl: $wsl'})';
  }
}

/// Mirror of the inferred TS `syncConfigEntrySchema` entry shape.
class SyncConfigEntry {
  const SyncConfigEntry({
    required this.kind,
    required this.localPath,
    this.repoPath,
    this.profiles,
    this.mode,
    this.permission,
  });

  final SyncConfigEntryKind kind;
  final PlatformStringValue localPath;
  final PlatformStringValue? repoPath;
  final List<String>? profiles;
  final PlatformSyncMode? mode;
  final PlatformPermission? permission;

  /// Serialization order mirrors the insertion order used by the only TS
  /// runtime writer of raw entries (`buildSyncConfigDocument` in
  /// `services/config-file.ts`): kind, localPath, repoPath, mode, permission,
  /// profiles.
  Map<String, Object?> toJson() {
    return {
      'kind': kind,
      'localPath': _platformStringValueToJson(localPath),
      if (repoPath != null) 'repoPath': _platformStringValueToJson(repoPath!),
      if (mode != null) 'mode': mode!.toJson(),
      if (permission != null) 'permission': permission!.toJson(),
      if (profiles != null) 'profiles': profiles,
    };
  }
}

/// Mirror of the TS `AgeConfig` shape (also used for the raw `age` section).
class AgeConfig {
  const AgeConfig({required this.recipients});

  final List<String> recipients;

  Map<String, Object?> toJson() {
    return {'recipients': recipients};
  }
}

/// Mirror of the inferred TS `RawSyncConfig` (`z.infer<typeof
/// syncConfigSchema>`).
class RawSyncConfig {
  const RawSyncConfig({
    required this.version,
    this.repositoryFormat,
    this.age,
    required this.profiles,
    required this.entries,
  });

  final int version;
  final int? repositoryFormat;
  final AgeConfig? age;
  final List<String> profiles;
  final List<SyncConfigEntry> entries;

  /// Serialization order mirrors the TS schema shape (which is also the
  /// literal order in `createInitialSyncConfig`): version, repositoryFormat,
  /// age, profiles, entries.
  Map<String, Object?> toJson() {
    return {
      'version': version,
      if (repositoryFormat != null) 'repositoryFormat': repositoryFormat,
      if (age != null) 'age': age!.toJson(),
      'profiles': profiles,
      'entries': [for (final entry in entries) entry.toJson()],
    };
  }
}

/// Mirror of the TS `SyncConfigResolutionContext`.
class SyncConfigResolutionContext {
  const SyncConfigResolutionContext({
    required this.homeDirectory,
    required this.platformKey,
    required this.readEnv,
    required this.xdgConfigHome,
  });

  final String homeDirectory;
  final PlatformKey platformKey;
  final String? Function(String name) readEnv;
  final String xdgConfigHome;
}

/// Mirror of the TS `ResolvedSyncConfigEntry`.
class ResolvedSyncConfigEntry {
  const ResolvedSyncConfigEntry({
    required this.configuredMode,
    required this.configuredLocalPath,
    this.configuredPermission,
    this.configuredRepoPath,
    required this.kind,
    required this.localPath,
    required this.profiles,
    required this.profilesExplicit,
    required this.mode,
    required this.modeExplicit,
    this.permission,
    required this.permissionExplicit,
    required this.repoPath,
  });

  final PlatformSyncMode configuredMode;
  final PlatformStringValue configuredLocalPath;
  final PlatformPermission? configuredPermission;
  final ConfiguredSyncRepoPath? configuredRepoPath;
  final SyncConfigEntryKind kind;
  final String localPath;
  final List<String> profiles;
  final bool profilesExplicit;
  final SyncMode mode;
  final bool modeExplicit;
  final int? permission;
  final bool permissionExplicit;
  final String repoPath;
}

/// Mirror of the TS `ResolvedSyncConfig`.
class ResolvedSyncConfig {
  const ResolvedSyncConfig({
    this.age,
    required this.entries,
    this.profiles,
    this.repositoryFormat,
    required this.version,
  });

  final AgeConfig? age;
  final List<ResolvedSyncConfigEntry> entries;
  final List<String>? profiles;
  final int? repositoryFormat;
  final int version;
}

// ---------------------------------------------------------------------------
// Schema validation (hand-rolled replacement for the TS Zod schemas)
// ---------------------------------------------------------------------------

const List<String> _platformOverrideKeys = ['win', 'mac', 'linux', 'wsl'];

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

String _receivedTypeOf(Map<String, Object?> parent, String key) {
  return parent.containsKey(key) ? _receivedType(parent[key]) : 'undefined';
}

String _enumOptionsMessage(List<String> options) {
  return 'Invalid option: expected one of '
      '${options.map((option) => '"$option"').join('|')}';
}

/// Mirror of `requiredTrimmedStringSchema`:
/// `z.string().trim().min(1, "Value must not be empty.")`.
String? _parseRequiredTrimmedString(
  Object? value,
  List<Object> path,
  String received,
  List<ValidationIssue> issues,
) {
  if (value is! String) {
    issues.add(
      ValidationIssue(
        path: path,
        message: 'Invalid input: expected string, received $received',
      ),
    );
    return null;
  }

  final trimmedValue = value.trim();

  if (trimmedValue.isEmpty) {
    issues.add(
      ValidationIssue(path: path, message: 'Value must not be empty.'),
    );
    return null;
  }

  return trimmedValue;
}

/// Mirror of `platformLocalPathSchema` / `platformRepoPathSchema`: an object
/// with a required trimmed `default` and optional per-platform overrides.
PlatformStringValue? _parsePlatformStringValue(
  Map<String, Object?> parent,
  String key,
  List<Object> basePath,
  List<ValidationIssue> issues,
) {
  final path = [...basePath, key];
  final raw = parent[key];

  if (raw is! Map<String, Object?>) {
    issues.add(
      ValidationIssue(
        path: path,
        message:
            'Invalid input: expected object, received '
            '${_receivedTypeOf(parent, key)}',
      ),
    );
    return null;
  }

  final defaultValue = _parseRequiredTrimmedString(
    raw['default'],
    [...path, 'default'],
    _receivedTypeOf(raw, 'default'),
    issues,
  );
  final overrides = <String, String?>{};

  for (final overrideKey in _platformOverrideKeys) {
    if (raw.containsKey(overrideKey)) {
      overrides[overrideKey] = _parseRequiredTrimmedString(
        raw[overrideKey],
        [...path, overrideKey],
        _receivedType(raw[overrideKey]),
        issues,
      );
    }
  }

  if (defaultValue == null) {
    return null;
  }

  return PlatformStringValue(
    defaultValue: defaultValue,
    win: overrides['win'],
    mac: overrides['mac'],
    linux: overrides['linux'],
    wsl: overrides['wsl'],
  );
}

/// Mirror of `z.enum(AppConstants.SYNC.MODES)`.
SyncMode? _parseSyncModeValue(
  Object? value,
  List<Object> path,
  List<ValidationIssue> issues,
) {
  if (value is String && AppConstants.sync.modes.contains(value)) {
    return value;
  }

  issues.add(
    ValidationIssue(
      path: path,
      message: _enumOptionsMessage(AppConstants.sync.modes),
    ),
  );
  return null;
}

/// Mirror of `platformSyncModeSchema`.
PlatformSyncMode? _parsePlatformSyncMode(
  Map<String, Object?> parent,
  String key,
  List<Object> basePath,
  List<ValidationIssue> issues,
) {
  final path = [...basePath, key];
  final raw = parent[key];

  if (raw is! Map<String, Object?>) {
    issues.add(
      ValidationIssue(
        path: path,
        message:
            'Invalid input: expected object, received '
            '${_receivedTypeOf(parent, key)}',
      ),
    );
    return null;
  }

  final defaultValue = _parseSyncModeValue(raw['default'], [
    ...path,
    'default',
  ], issues);
  final overrides = <String, SyncMode?>{};

  for (final overrideKey in _platformOverrideKeys) {
    if (raw.containsKey(overrideKey)) {
      overrides[overrideKey] = _parseSyncModeValue(raw[overrideKey], [
        ...path,
        overrideKey,
      ], issues);
    }
  }

  if (defaultValue == null) {
    return null;
  }

  return PlatformSyncMode(
    defaultValue: defaultValue,
    win: overrides['win'],
    mac: overrides['mac'],
    linux: overrides['linux'],
    wsl: overrides['wsl'],
  );
}

final RegExp _permissionOctalPattern = RegExp(r'^0[0-7]{3}$');

/// Mirror of `permissionOctalSchema`.
String? _parsePermissionOctalValue(
  Object? value,
  List<Object> path,
  String received,
  List<ValidationIssue> issues,
) {
  if (value is! String) {
    issues.add(
      ValidationIssue(
        path: path,
        message: 'Invalid input: expected string, received $received',
      ),
    );
    return null;
  }

  if (!_permissionOctalPattern.hasMatch(value)) {
    issues.add(
      ValidationIssue(
        path: path,
        message:
            "Permission must be a 4-character octal string like '0600' or "
            "'0755'.",
      ),
    );
    return null;
  }

  return value;
}

/// Mirror of `platformPermissionSchema`.
PlatformPermission? _parsePlatformPermission(
  Map<String, Object?> parent,
  String key,
  List<Object> basePath,
  List<ValidationIssue> issues,
) {
  final path = [...basePath, key];
  final raw = parent[key];

  if (raw is! Map<String, Object?>) {
    issues.add(
      ValidationIssue(
        path: path,
        message:
            'Invalid input: expected object, received '
            '${_receivedTypeOf(parent, key)}',
      ),
    );
    return null;
  }

  final defaultValue = _parsePermissionOctalValue(
    raw['default'],
    [...path, 'default'],
    _receivedTypeOf(raw, 'default'),
    issues,
  );
  final overrides = <String, String?>{};

  for (final overrideKey in _platformOverrideKeys) {
    if (raw.containsKey(overrideKey)) {
      overrides[overrideKey] = _parsePermissionOctalValue(
        raw[overrideKey],
        [...path, overrideKey],
        _receivedType(raw[overrideKey]),
        issues,
      );
    }
  }

  if (defaultValue == null) {
    return null;
  }

  return PlatformPermission(
    defaultValue: defaultValue,
    win: overrides['win'],
    mac: overrides['mac'],
    linux: overrides['linux'],
    wsl: overrides['wsl'],
  );
}

/// Mirror of `syncConfigEntrySchema`.
SyncConfigEntry? _parseSyncConfigEntry(
  Object? value,
  int index,
  List<ValidationIssue> issues,
) {
  final path = <Object>['entries', index];

  if (value is! Map<String, Object?>) {
    issues.add(
      ValidationIssue(
        path: path,
        message:
            'Invalid input: expected object, received ${_receivedType(value)}',
      ),
    );
    return null;
  }

  final rawKind = value['kind'];
  SyncConfigEntryKind? kind;

  if (rawKind is String && (rawKind == 'file' || rawKind == 'directory')) {
    kind = rawKind;
  } else {
    issues.add(
      ValidationIssue(
        path: [...path, 'kind'],
        message: _enumOptionsMessage(const ['file', 'directory']),
      ),
    );
  }

  final localPath = _parsePlatformStringValue(value, 'localPath', path, issues);
  final repoPath = value.containsKey('repoPath')
      ? _parsePlatformStringValue(value, 'repoPath', path, issues)
      : null;

  List<String>? profiles;

  if (value.containsKey('profiles')) {
    final rawProfiles = value['profiles'];

    if (rawProfiles is! List<Object?>) {
      issues.add(
        ValidationIssue(
          path: [...path, 'profiles'],
          message:
              'Invalid input: expected array, received '
              '${_receivedType(rawProfiles)}',
        ),
      );
    } else {
      final parsedProfiles = <String>[];
      var profilesValid = true;

      for (var i = 0; i < rawProfiles.length; i += 1) {
        final profile = _parseRequiredTrimmedString(
          rawProfiles[i],
          [...path, 'profiles', i],
          _receivedType(rawProfiles[i]),
          issues,
        );

        if (profile == null) {
          profilesValid = false;
        } else {
          parsedProfiles.add(profile);
        }
      }

      if (rawProfiles.isEmpty) {
        issues.add(
          ValidationIssue(
            path: [...path, 'profiles'],
            message: 'At least one profile must be specified.',
          ),
        );
        profilesValid = false;
      }

      if (profilesValid) {
        profiles = parsedProfiles;
      }
    }
  }

  final mode = value.containsKey('mode')
      ? _parsePlatformSyncMode(value, 'mode', path, issues)
      : null;
  final permission = value.containsKey('permission')
      ? _parsePlatformPermission(value, 'permission', path, issues)
      : null;

  if (kind == null || localPath == null) {
    return null;
  }

  return SyncConfigEntry(
    kind: kind,
    localPath: localPath,
    repoPath: repoPath,
    profiles: profiles,
    mode: mode,
    permission: permission,
  );
}

/// Mirror of `syncConfigSchema.safeParse`: validates the raw manifest input
/// and returns the typed config, or the collected issues on failure.
(RawSyncConfig?, List<ValidationIssue>) _parseRawSyncConfig(Object? input) {
  final issues = <ValidationIssue>[];

  if (input is! Map<String, Object?>) {
    issues.add(
      ValidationIssue(
        path: const [],
        message:
            'Invalid input: expected object, received ${_receivedType(input)}',
      ),
    );
    return (null, issues);
  }

  // version: z.union([z.literal(7), z.literal(8)])
  final rawVersion = input['version'];
  var version = 0;

  if (rawVersion is num &&
      (rawVersion == 7 || rawVersion == AppConstants.sync.configVersion)) {
    version = rawVersion.toInt();
  } else {
    issues.add(
      const ValidationIssue(path: ['version'], message: 'Invalid input'),
    );
  }

  // repositoryFormat: z.number().int().min(0).optional()
  int? repositoryFormat;

  if (input.containsKey('repositoryFormat')) {
    final rawRepositoryFormat = input['repositoryFormat'];

    if (rawRepositoryFormat is! num) {
      issues.add(
        ValidationIssue(
          path: const ['repositoryFormat'],
          message:
              'Invalid input: expected number, received '
              '${_receivedType(rawRepositoryFormat)}',
        ),
      );
    } else if (rawRepositoryFormat is! int &&
        rawRepositoryFormat != rawRepositoryFormat.truncateToDouble()) {
      issues.add(
        const ValidationIssue(
          path: ['repositoryFormat'],
          message: 'Invalid input: expected int, received number',
        ),
      );
    } else if (rawRepositoryFormat < 0) {
      issues.add(
        const ValidationIssue(
          path: ['repositoryFormat'],
          message: 'Too small: expected number to be >=0',
        ),
      );
    } else {
      repositoryFormat = rawRepositoryFormat.toInt();
    }
  }

  // age: syncConfigAgeSchema.optional()
  AgeConfig? age;

  if (input.containsKey('age')) {
    final rawAge = input['age'];

    if (rawAge is! Map<String, Object?>) {
      issues.add(
        ValidationIssue(
          path: const ['age'],
          message:
              'Invalid input: expected object, received '
              '${_receivedType(rawAge)}',
        ),
      );
    } else {
      final rawRecipients = rawAge['recipients'];

      if (rawRecipients is! List<Object?>) {
        issues.add(
          ValidationIssue(
            path: const ['age', 'recipients'],
            message:
                'Invalid input: expected array, received '
                '${_receivedTypeOf(rawAge, 'recipients')}',
          ),
        );
      } else {
        final recipients = <String>[];
        var recipientsValid = true;

        for (var i = 0; i < rawRecipients.length; i += 1) {
          final recipient = _parseRequiredTrimmedString(
            rawRecipients[i],
            ['age', 'recipients', i],
            _receivedType(rawRecipients[i]),
            issues,
          );

          if (recipient == null) {
            recipientsValid = false;
          } else {
            recipients.add(recipient);
          }
        }

        if (rawRecipients.isEmpty) {
          issues.add(
            const ValidationIssue(
              path: ['age', 'recipients'],
              message: 'At least one age recipient is required.',
            ),
          );
          recipientsValid = false;
        }

        if (recipientsValid) {
          age = AgeConfig(recipients: recipients);
        }
      }
    }
  }

  // profiles: z.array(requiredTrimmedStringSchema).default([])
  var profiles = <String>[];

  if (input.containsKey('profiles')) {
    final rawProfiles = input['profiles'];

    if (rawProfiles is! List<Object?>) {
      issues.add(
        ValidationIssue(
          path: const ['profiles'],
          message:
              'Invalid input: expected array, received '
              '${_receivedType(rawProfiles)}',
        ),
      );
    } else {
      final parsedProfiles = <String>[];
      var profilesValid = true;

      for (var i = 0; i < rawProfiles.length; i += 1) {
        final profile = _parseRequiredTrimmedString(
          rawProfiles[i],
          ['profiles', i],
          _receivedType(rawProfiles[i]),
          issues,
        );

        if (profile == null) {
          profilesValid = false;
        } else {
          parsedProfiles.add(profile);
        }
      }

      if (profilesValid) {
        profiles = parsedProfiles;
      }
    }
  }

  // entries: z.array(syncConfigEntrySchema)
  final entries = <SyncConfigEntry>[];
  final rawEntries = input['entries'];

  if (rawEntries is! List<Object?>) {
    issues.add(
      ValidationIssue(
        path: const ['entries'],
        message:
            'Invalid input: expected array, received '
            '${_receivedTypeOf(input, 'entries')}',
      ),
    );
  } else {
    for (var i = 0; i < rawEntries.length; i += 1) {
      final entry = _parseSyncConfigEntry(rawEntries[i], i, issues);

      if (entry != null) {
        entries.add(entry);
      }
    }
  }

  if (issues.isNotEmpty) {
    return (null, issues);
  }

  return (
    RawSyncConfig(
      version: version,
      repositoryFormat: repositoryFormat,
      age: age,
      profiles: profiles,
      entries: entries,
    ),
    issues,
  );
}

/// Mirror of `syncConfigSchema.parse` on already-decoded JSON input: returns
/// the validated raw config or throws when it is invalid. The TS call site
/// (`writeValidatedSyncConfig` in `services/config-file.ts`) surfaces the raw
/// ZodError; the Dart port raises a DotweaveError carrying the same formatted
/// issue lines used by [parseSyncConfig].
RawSyncConfig parseRawSyncConfig(Object? input) {
  final (data, issues) = _parseRawSyncConfig(input);

  if (data == null) {
    throw DotweaveError(
      'Sync configuration is invalid.',
      code: 'CONFIG_VALIDATION_FAILED',
      details: formatInputIssues(issues).split('\n'),
      hint:
          'Fix the invalid fields in ${AppConstants.sync.configFileName}, '
          'then run the command again.',
    );
  }

  return data;
}

// ---------------------------------------------------------------------------
// Normalization utilities
// ---------------------------------------------------------------------------

String normalizeSyncRepoPath(String value) {
  final normalizedValue = p.posix.normalize(value.replaceAll(r'\', '/'));

  if (normalizedValue == '' ||
      normalizedValue == '.' ||
      normalizedValue.startsWith('../') ||
      normalizedValue.contains('/../') ||
      normalizedValue.startsWith('/')) {
    throw DotweaveError(
      'Repository path must be a relative POSIX path inside the repository '
      'root.',
      code: 'INVALID_REPO_PATH',
      details: ['Repository path: $value'],
      hint:
          "Use a relative path like '.config/tool/settings.json' without "
          "'..' segments.",
    );
  }

  if (hasReservedSyncArtifactSuffixSegment(normalizedValue)) {
    throw DotweaveError(
      'Repository path must not use the reserved suffixes '
      '${AppConstants.sync.secretArtifactSuffix} or '
      '${AppConstants.sync.symlinkArtifactSuffix}.',
      code: 'RESERVED_ARTIFACT_SUFFIX',
      details: ['Repository path: $value'],
      hint:
          'Rename the path so no segment ends with a reserved artifact '
          'suffix.',
    );
  }

  return normalizedValue;
}

String normalizeSyncProfileName(
  String value, [
  String description = 'Profile name',
]) {
  final normalizedValue = value.trim();

  if (normalizedValue.isEmpty) {
    throw DotweaveError(
      '$description must not be empty.',
      code: 'INVALID_PROFILE_NAME',
      details: ['$description: $value'],
      hint: "Use a short profile name like 'work' or 'personal'.",
    );
  }

  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(normalizedValue)) {
    throw DotweaveError(
      '$description contains unsupported characters.',
      code: 'INVALID_PROFILE_NAME',
      details: ['$description: $value'],
      hint:
          'Use letters, numbers, dots, underscores, or hyphens, and start '
          'with a letter or number.',
    );
  }

  if (normalizedValue.startsWith('.')) {
    throw DotweaveError(
      "$description must not start with '.'.",
      code: 'INVALID_PROFILE_NAME',
      details: ['$description: $value'],
      hint: "Use a plain name like 'work' instead of hidden-path style names.",
    );
  }

  if (normalizedValue == '.' || normalizedValue == '..') {
    throw DotweaveError(
      '$description is invalid.',
      code: 'INVALID_PROFILE_NAME',
      details: ['$description: $value'],
    );
  }

  if (normalizedValue == 'profiles') {
    throw DotweaveError(
      '$description conflicts with the reserved profile artifact directory.',
      code: 'INVALID_PROFILE_NAME',
      details: ['$description: $value'],
      hint:
          "Use a profile name like 'work' or 'personal' instead of "
          "'profiles'.",
    );
  }

  return normalizedValue;
}

bool hasReservedSyncArtifactSuffixSegment(String value) {
  return value
      .replaceAll(r'\', '/')
      .split('/')
      .any(
        (segment) =>
            segment.endsWith(AppConstants.sync.secretArtifactSuffix) ||
            segment.endsWith(AppConstants.sync.symlinkArtifactSuffix),
      );
}

String deriveRepoPathFromLocalPath(
  PlatformStringValue localPath,
  String homeDirectory,
) {
  final resolvedDefaultPath = resolveConfiguredAbsolutePath(
    localPath.defaultValue,
    homeDirectory,
    null,
  );
  final relativePath = p.relative(resolvedDefaultPath, from: homeDirectory);

  return normalizeSyncRepoPath(relativePath.replaceAll(r'\', '/'));
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

void _validatePathOverlaps(
  List<ResolvedSyncConfigEntry> entries,
  String property,
  String description,
) {
  String valueOf(ResolvedSyncConfigEntry entry) {
    return property == 'repoPath' ? entry.repoPath : entry.localPath;
  }

  for (var index = 0; index < entries.length; index += 1) {
    final currentEntry = entries[index];

    for (
      var otherIndex = index + 1;
      otherIndex < entries.length;
      otherIndex += 1
    ) {
      final otherEntry = entries[otherIndex];
      final currentValue = valueOf(currentEntry);
      final otherValue = valueOf(otherEntry);

      if (currentValue == otherValue) {
        final isRepoPath = property == 'repoPath';

        throw DotweaveError(
          isRepoPath
              ? 'Multiple entries target the same repository path in '
                    '${AppConstants.sync.configFileName}.'
              : 'Duplicate ${description.toLowerCase()} paths in '
                    '${AppConstants.sync.configFileName}.',
          code: 'DUPLICATE_PATHS',
          details: isRepoPath
              ? [
                  '${currentEntry.localPath} -> $currentValue',
                  '${otherEntry.localPath} -> $otherValue',
                ]
              : [
                  '${currentEntry.repoPath}: $currentValue',
                  '${otherEntry.repoPath}: $otherValue',
                ],
          hint: isRepoPath
              ? 'Each entry must use a unique repoPath. Change or remove one '
                    'of the conflicting entries.'
              : 'Remove the duplicate entry from '
                    '${AppConstants.sync.configFileName}.',
        );
      }

      final isParentChild =
          currentValue.startsWith('$otherValue/') ||
          currentValue.startsWith('$otherValue${p.separator}') ||
          otherValue.startsWith('$currentValue/') ||
          otherValue.startsWith('$currentValue${p.separator}');

      if (isParentChild) {
        continue;
      }

      final overlaps = property == 'repoPath'
          ? false
          : doPathsOverlap(currentValue, otherValue);

      if (overlaps) {
        throw DotweaveError(
          '$description paths must not overlap in '
          '${AppConstants.sync.configFileName}.',
          code: 'OVERLAPPING_PATHS',
          details: [
            '${currentEntry.repoPath}: $currentValue',
            '${otherEntry.repoPath}: $otherValue',
          ],
          hint:
              'Split overlapping entries so each tracked root owns a '
              'distinct path.',
        );
      }
    }
  }
}

void validateResolvedSyncConfigEntries(List<ResolvedSyncConfigEntry> entries) {
  _validatePathOverlaps(entries, 'repoPath', 'Repository');
  _validatePathOverlaps(entries, 'localPath', 'Local');
}

List<String> _normalizeProfileRegistry(List<String> profiles) {
  final normalizedProfiles = [
    for (final profile in profiles) normalizeSyncProfileName(profile),
  ];
  final seenProfiles = <String>{};

  for (final profile in normalizedProfiles) {
    if (profile == AppConstants.sync.defaultProfile) {
      throw DotweaveError(
        "Profile '${AppConstants.sync.defaultProfile}' is implicit and must "
        'not be listed in manifest profiles.',
        code: 'INVALID_PROFILE_REGISTRY',
        hint:
            "Remove '${AppConstants.sync.defaultProfile}' from profiles in "
            '${AppConstants.sync.configFileName}.',
      );
    }

    if (seenProfiles.contains(profile)) {
      throw DotweaveError(
        "Duplicate profile '$profile' in manifest.",
        code: 'DUPLICATE_PROFILE',
        hint:
            'Remove duplicate profile names from profiles in '
            '${AppConstants.sync.configFileName}.',
      );
    }

    seenProfiles.add(profile);
  }

  return normalizedProfiles;
}

void _validateProfileReferences(
  Iterable<(String, List<String>)> references,
  List<String> profiles,
) {
  final availableProfiles = {AppConstants.sync.defaultProfile, ...profiles};

  for (final (entryLabel, entryProfiles) in references) {
    for (final profile in entryProfiles) {
      final normalizedProfile = normalizeSyncProfileName(profile);

      if (!availableProfiles.contains(normalizedProfile)) {
        throw DotweaveError(
          "Unknown profile '$normalizedProfile'.",
          code: 'UNKNOWN_PROFILE',
          details: ['Entry: $entryLabel'],
          hint:
              "Add it with 'dotweave profile add $normalizedProfile', or "
              'remove it from the entry profiles.',
        );
      }
    }
  }
}

void _validateEntryProfileReferences(
  List<ResolvedSyncConfigEntry> entries,
  List<String> profiles,
) {
  _validateProfileReferences(
    entries.map((entry) => (entry.repoPath, entry.profiles)),
    profiles,
  );
}

List<String> validateRawSyncConfigProfileRegistry(RawSyncConfig config) {
  final profiles = _normalizeProfileRegistry(config.profiles);

  _validateProfileReferences(
    config.entries.map(
      (entry) => (
        entry.repoPath?.defaultValue ?? entry.localPath.defaultValue,
        entry.profiles ?? const <String>[],
      ),
    ),
    profiles,
  );

  return profiles;
}

List<String> _collectLegacyProfileRegistry(List<SyncConfigEntry> entries) {
  final profiles = <String>{};

  for (final entry in entries) {
    final entryProfiles = entry.profiles;

    if (entryProfiles == null) {
      continue;
    }

    for (final profile in entryProfiles) {
      final normalizedProfile = normalizeSyncProfileName(profile);
      if (normalizedProfile != AppConstants.sync.defaultProfile) {
        profiles.add(normalizedProfile);
      }
    }
  }

  return [...profiles]..sort(compareLocaleLike);
}

// ---------------------------------------------------------------------------
// Internal parsing helpers
// ---------------------------------------------------------------------------

final PlatformSyncMode _defaultSyncMode = PlatformSyncMode(
  defaultValue: AppConstants.sync.modes[0],
);

SyncMode _resolveSyncModeForPlatform(
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

int _resolveSyncPermissionForPlatform(
  PlatformPermission configuredPermission,
  PlatformKey platformKey,
) {
  return parsePermissionOctal(
    resolveForPlatform(
      platformKey,
      defaultValue: configuredPermission.defaultValue,
      win: configuredPermission.win,
      mac: configuredPermission.mac,
      linux: configuredPermission.linux,
      wsl: configuredPermission.wsl,
    ),
  );
}

ConfiguredSyncRepoPath _normalizeConfiguredRepoPath(
  ConfiguredSyncRepoPath repoPath,
) {
  return PlatformStringValue(
    defaultValue: normalizeSyncRepoPath(repoPath.defaultValue),
    win: repoPath.win == null ? null : normalizeSyncRepoPath(repoPath.win!),
    mac: repoPath.mac == null ? null : normalizeSyncRepoPath(repoPath.mac!),
    linux: repoPath.linux == null
        ? null
        : normalizeSyncRepoPath(repoPath.linux!),
    wsl: repoPath.wsl == null ? null : normalizeSyncRepoPath(repoPath.wsl!),
  );
}

String _resolveSyncEntryLocalPath(
  PlatformStringValue value,
  SyncConfigResolutionContext context,
) {
  final platformKey = context.platformKey;
  final homeDirectory = context.homeDirectory;
  final xdgConfigHome = context.xdgConfigHome;
  final readEnv = context.readEnv;
  final platformPath = resolvePlatformValue(value, platformKey);
  final String resolvedLocalPath;

  try {
    resolvedLocalPath = resolveConfiguredAbsolutePath(
      platformPath,
      homeDirectory,
      xdgConfigHome,
      readEnv,
    );
  } catch (error) {
    throw DotweaveError(extractErrorMessage(error));
  }

  final String relativePath;

  try {
    relativePath = p.relative(resolvedLocalPath, from: homeDirectory);
  } on p.PathException {
    // node:path `relative` returns the absolute target when no relative path
    // exists (e.g. across Windows drives), which fails the inside-HOME check
    // below; package:path throws instead.
    throw DotweaveError(
      'Sync entry local path must stay inside HOME.',
      code: 'ENTRY_OUTSIDE_HOME',
      details: [
        'Configured path: $platformPath',
        'Home directory: $homeDirectory',
      ],
      hint: "Use a path under HOME, such as '~/...'.",
    );
  }

  if (relativePath == '' || relativePath == '.') {
    throw DotweaveError(
      'Sync entry local path cannot be the home directory itself.',
      code: 'ENTRY_ROOT_DISALLOWED',
      details: [
        'Configured path: $platformPath',
        'Home directory: $homeDirectory',
      ],
      hint: 'Track a file or subdirectory inside HOME instead.',
    );
  }

  if (p.isAbsolute(relativePath) ||
      relativePath.startsWith('..') ||
      relativePath == '..') {
    throw DotweaveError(
      'Sync entry local path must stay inside HOME.',
      code: 'ENTRY_OUTSIDE_HOME',
      details: [
        'Configured path: $platformPath',
        'Home directory: $homeDirectory',
      ],
      hint: "Use a path under HOME, such as '~/...'.",
    );
  }

  return resolvedLocalPath;
}

ResolvedSyncConfigEntry? _findNearestParentEntry(
  Map<String, ResolvedSyncConfigEntry> entries,
  String childRepoPath,
) {
  ResolvedSyncConfigEntry? best;

  for (final entry in entries.values) {
    if (entry.kind == 'directory' &&
        childRepoPath != entry.repoPath &&
        childRepoPath.startsWith('${entry.repoPath}/') &&
        (best == null || entry.repoPath.length > best.repoPath.length)) {
      best = entry;
    }
  }

  return best;
}

List<ResolvedSyncConfigEntry> _applyEntryInheritance(
  List<ResolvedSyncConfigEntry> entries,
  PlatformKey platformKey,
) {
  final sorted = [...entries]
    ..sort((a, b) => a.repoPath.length - b.repoPath.length);

  final resolved = <String, ResolvedSyncConfigEntry>{};

  for (final entry in sorted) {
    final parent = _findNearestParentEntry(resolved, entry.repoPath);

    final inheritedMode = !entry.modeExplicit && parent != null
        ? parent.configuredMode
        : entry.configuredMode;

    final inheritedProfiles = !entry.profilesExplicit && parent != null
        ? parent.profiles
        : entry.profiles;

    final inheritedPermission = !entry.permissionExplicit && parent != null
        ? parent.configuredPermission
        : entry.configuredPermission;

    resolved[entry.repoPath] = ResolvedSyncConfigEntry(
      configuredMode: inheritedMode,
      configuredLocalPath: entry.configuredLocalPath,
      configuredPermission: inheritedPermission,
      configuredRepoPath: entry.configuredRepoPath,
      kind: entry.kind,
      localPath: entry.localPath,
      profiles: inheritedProfiles,
      profilesExplicit: entry.profilesExplicit,
      mode: _resolveSyncModeForPlatform(inheritedMode, platformKey),
      modeExplicit: entry.modeExplicit,
      permission: inheritedPermission != null
          ? _resolveSyncPermissionForPlatform(inheritedPermission, platformKey)
          : null,
      permissionExplicit: entry.permissionExplicit,
      repoPath: entry.repoPath,
    );
  }

  return [
    for (final e in entries)
      resolved[e.repoPath] ??
          (throw StateError('Missing resolved entry for ${e.repoPath}')),
  ];
}

// ---------------------------------------------------------------------------
// Public API: parsing & serialization
// ---------------------------------------------------------------------------

ResolvedSyncConfig parseSyncConfig(
  Object? input,
  SyncConfigResolutionContext context,
) {
  final platformKey = context.platformKey;
  final homeDirectory = context.homeDirectory;
  final (data, issues) = _parseRawSyncConfig(input);

  if (data == null) {
    throw DotweaveError(
      'Sync configuration is invalid.',
      code: 'CONFIG_VALIDATION_FAILED',
      details: formatInputIssues(issues).split('\n'),
      hint:
          'Fix the invalid fields in ${AppConstants.sync.configFileName}, '
          'then run the command again.',
    );
  }

  final profiles = _normalizeProfileRegistry(
    data.version == 7
        ? _collectLegacyProfileRegistry(data.entries)
        : data.profiles,
  );

  final rawEntries = [
    for (final entry in data.entries)
      () {
        final resolvedLocalPath = _resolveSyncEntryLocalPath(
          entry.localPath,
          context,
        );
        final configuredRepoPath = entry.repoPath == null
            ? null
            : _normalizeConfiguredRepoPath(entry.repoPath!);
        final repoPath = configuredRepoPath == null
            ? deriveRepoPathFromLocalPath(entry.localPath, homeDirectory)
            : resolvePlatformValue(configuredRepoPath, platformKey);

        final entryProfiles = entry.profiles;
        if (entryProfiles != null && entryProfiles.isNotEmpty) {
          for (final profile in entryProfiles) {
            normalizeSyncProfileName(profile);
          }
        }
        final profiles = entryProfiles != null && entryProfiles.isNotEmpty
            ? entryProfiles
            : <String>[];

        final configuredMode = entry.mode ?? _defaultSyncMode;
        final configuredPermission = entry.permission;

        return ResolvedSyncConfigEntry(
          configuredMode: configuredMode,
          configuredLocalPath: entry.localPath,
          configuredPermission: configuredPermission,
          configuredRepoPath: configuredRepoPath,
          kind: entry.kind,
          localPath: resolvedLocalPath,
          profiles: profiles,
          profilesExplicit: entry.profiles != null,
          mode: _resolveSyncModeForPlatform(configuredMode, platformKey),
          modeExplicit: entry.mode != null,
          permission: configuredPermission != null
              ? _resolveSyncPermissionForPlatform(
                  configuredPermission,
                  platformKey,
                )
              : null,
          permissionExplicit: entry.permission != null,
          repoPath: repoPath,
        );
      }(),
  ];

  validateResolvedSyncConfigEntries(rawEntries);

  final entries = _applyEntryInheritance(rawEntries, platformKey);
  _validateEntryProfileReferences(entries, profiles);

  final age = data.age == null
      ? null
      : AgeConfig(
          recipients: [
            ...{...data.age!.recipients},
          ],
        );

  return ResolvedSyncConfig(
    age: age,
    entries: entries,
    profiles: profiles,
    repositoryFormat: data.repositoryFormat,
    version: data.version,
  );
}

RawSyncConfig createInitialSyncConfig(AgeConfig age) {
  return RawSyncConfig(
    version: AppConstants.sync.configVersion,
    // A freshly created repository is at the current format by construction.
    repositoryFormat: AppConstants.sync.repositoryFormat,
    age: age,
    profiles: [],
    entries: [],
  );
}

String formatSyncConfig(RawSyncConfig config) {
  return formatJsonPretty(config.toJson());
}

String resolveSyncConfigFilePath(String syncDirectory) {
  return p.join(syncDirectory, AppConstants.sync.configFileName);
}

Future<ResolvedSyncConfig> readSyncConfig(
  String syncDirectory,
  SyncConfigResolutionContext context,
) async {
  final filePath = await validateJsoncConfigPath(
    resolveSyncConfigFilePath(syncDirectory),
  );
  try {
    final contents = await File(filePath).readAsString();
    final parsed = parseJsonc(contents);
    final migration = applyConfigMigrations(
      parsed,
      _syncConfigMigrationRegistry,
      AppConstants.sync.configVersion,
      filePath,
    );
    final resolved = parseSyncConfig(migration.config, context);

    assertRepositoryFormatSupported(
      resolved.repositoryFormat ?? 0,
      AppConstants.sync.repositoryFormat,
      AppConstants.sync.minSupportedRepositoryFormat,
      'Config file: $filePath',
    );

    // Persist only after validation succeeds, via the shared writer, so an
    // invalid migration result is never written to disk.
    final originalVersion = migration.originalVersion;
    if (migration.migrated && originalVersion != null) {
      await persistMigratedConfig(
        filePath,
        parsed,
        migration.config,
        originalVersion,
      );
    }

    return resolved;
  } on DotweaveError {
    rethrow;
  } on FormatException catch (error) {
    throw DotweaveError(
      'Sync configuration is not valid JSON.',
      code: 'CONFIG_INVALID_JSON',
      details: ['Config file: $filePath', error.message],
      hint:
          'Fix the JSON syntax in ${AppConstants.sync.configFileName}, then '
          'run the command again.',
    );
  } catch (error) {
    throw DotweaveError(
      'Failed to read sync configuration.',
      code: 'CONFIG_READ_FAILED',
      details: ['Config file: $filePath', extractErrorMessage(error)],
      hint:
          "Run 'dotweave init' if the sync directory has not been "
          'initialized yet.',
    );
  }
}

Map<String, Object?> _platformStringValueToJson(PlatformStringValue value) {
  return {
    'default': value.defaultValue,
    if (value.win != null) 'win': value.win,
    if (value.mac != null) 'mac': value.mac,
    if (value.linux != null) 'linux': value.linux,
    if (value.wsl != null) 'wsl': value.wsl,
  };
}
