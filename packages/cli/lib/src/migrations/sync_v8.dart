import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/lib/collation.dart';
import 'package:dotweave/src/lib/error.dart';

String _normalizeLegacyProfileName(String value) {
  final normalizedValue = value.trim();

  if (normalizedValue.isEmpty) {
    throw DotweaveError(
      'Profile name must not be empty.',
      code: 'INVALID_PROFILE_NAME',
      details: ['Profile name: $value'],
      hint: "Use a short profile name like 'work' or 'personal'.",
    );
  }

  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(normalizedValue)) {
    throw DotweaveError(
      'Profile name contains unsupported characters.',
      code: 'INVALID_PROFILE_NAME',
      details: ['Profile name: $value'],
      hint:
          'Use letters, numbers, dots, underscores, or hyphens, and start '
          'with a letter or number.',
    );
  }

  if (normalizedValue.startsWith('.')) {
    throw DotweaveError(
      "Profile name must not start with '.'.",
      code: 'INVALID_PROFILE_NAME',
      details: ['Profile name: $value'],
      hint: "Use a plain name like 'work' instead of hidden-path style names.",
    );
  }

  if (normalizedValue == '.' || normalizedValue == '..') {
    throw DotweaveError(
      'Profile name is invalid.',
      code: 'INVALID_PROFILE_NAME',
      details: ['Profile name: $value'],
    );
  }

  return normalizedValue;
}

/// Mirror of `migrations/sync-v8.ts`: hoists per-entry profile references
/// into a top-level `profiles` registry and bumps the manifest version to 8.
Map<String, Object?> migrateSyncConfigV7ToV8(Map<String, Object?> config) {
  final profiles = <String>{};
  final rawEntries = config['entries'];
  final entries = rawEntries is List<Object?> ? rawEntries : const <Object?>[];

  for (final entry in entries) {
    if (entry is! Map<String, Object?>) {
      continue;
    }

    final entryProfiles = entry['profiles'];

    if (entryProfiles is! List<Object?>) {
      continue;
    }

    for (final profile in entryProfiles) {
      if (profile is! String) {
        throw DotweaveError(
          'Profile name must be a string.',
          code: 'INVALID_PROFILE_NAME',
          details: ['Profile value: $profile'],
          hint: "Use a short profile name like 'work' or 'personal'.",
        );
      }

      final normalizedProfile = _normalizeLegacyProfileName(profile);

      if (normalizedProfile != AppConstants.sync.defaultProfile) {
        profiles.add(normalizedProfile);
      }
    }
  }

  final sortedProfiles = [...profiles]..sort(compareLocaleLike);

  return {...config, 'version': 8, 'profiles': sortedProfiles};
}
