import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/file_mode.dart';
import 'package:dotweave/src/services/track.dart';

// Mirror of `cli/platform-flags.ts`: parsing variadic CLI flag values like
// `--mode secret`, `--mode win=ignore`, `--permission linux=0755`, or
// `--repo platform=path` into platform-scoped partial values.
//
// The TS functions cast the parsed partial records to the full
// `PlatformStringValue` / `PlatformSyncMode` shapes even though `default` may
// be absent at runtime. The Dart port returns the honest partial shapes
// ([PartialPlatformStringValue] / [PartialPlatformSyncMode]) that the
// `TrackRequest` consumer actually accepts.

/// Mirror of the TS `PlatformFlagKey` union:
/// `default` | `win` | `mac` | `linux` | `wsl`.
typedef PlatformFlagKey = String;

const Set<PlatformFlagKey> _platformFlagKeys = {
  'default',
  'win',
  'mac',
  'linux',
  'wsl',
};

final Set<SyncMode> _syncModes = Set.of(AppConstants.sync.modes);

Map<PlatformFlagKey, String>? _parsePlatformFlagValues(
  String flagName,
  List<String>? values, {
  required bool allowDefault,
}) {
  if (values == null || values.isEmpty) {
    return null;
  }

  final parsed = <PlatformFlagKey, String>{};

  for (final rawValue in values) {
    final separatorIndex = rawValue.indexOf('=');
    final key = separatorIndex == -1
        ? 'default'
        : rawValue.substring(0, separatorIndex);
    final value = separatorIndex == -1
        ? rawValue
        : rawValue.substring(separatorIndex + 1);

    if (key.isEmpty ||
        value.isEmpty ||
        !_platformFlagKeys.contains(key) ||
        (!allowDefault && key == 'default')) {
      throw DotweaveError(
        'Invalid --$flagName platform value.',
        code: 'INVALID_PLATFORM_FLAG',
        hint: allowDefault
            ? 'Use --$flagName value or --$flagName platform=value.'
            : 'Use --$flagName platform=value with win, mac, linux, or wsl.',
      );
    }

    if (parsed.containsKey(key)) {
      throw DotweaveError(
        'Duplicate --$flagName platform value.',
        code: 'DUPLICATE_PLATFORM_FLAG',
        details: ["Platform '$key' was specified more than once."],
      );
    }

    parsed[key] = value;
  }

  return parsed;
}

Map<PlatformFlagKey, T>? _mapPlatformValues<T>(
  Map<PlatformFlagKey, String>? parsed,
  T Function(String value) validate,
) {
  if (parsed == null) {
    return null;
  }

  return {for (final entry in parsed.entries) entry.key: validate(entry.value)};
}

PartialPlatformStringValue? parsePlatformStringFlags(
  String flagName,
  List<String>? values,
) {
  final parsed = _parsePlatformFlagValues(flagName, values, allowDefault: true);

  if (parsed == null) {
    return null;
  }

  return PartialPlatformStringValue(
    defaultValue: parsed['default'],
    win: parsed['win'],
    mac: parsed['mac'],
    linux: parsed['linux'],
    wsl: parsed['wsl'],
  );
}

PartialPlatformStringValue? parsePlatformStringOverrideFlags(
  String flagName,
  List<String>? values,
) {
  final parsed = _parsePlatformFlagValues(
    flagName,
    values,
    allowDefault: false,
  );

  if (parsed == null) {
    return null;
  }

  return PartialPlatformStringValue(
    defaultValue: parsed['default'],
    win: parsed['win'],
    mac: parsed['mac'],
    linux: parsed['linux'],
    wsl: parsed['wsl'],
  );
}

PartialPlatformSyncMode? parsePlatformModeFlags(
  String flagName,
  List<String>? values,
) {
  final mapped = _mapPlatformValues(
    _parsePlatformFlagValues(flagName, values, allowDefault: true),
    (value) {
      if (!_syncModes.contains(value)) {
        throw DotweaveError(
          "Invalid --$flagName mode '$value'.",
          code: 'INVALID_SYNC_MODE',
          hint: 'Use one of: ${AppConstants.sync.modes.join(', ')}.',
        );
      }

      return value;
    },
  );

  if (mapped == null) {
    return null;
  }

  return PartialPlatformSyncMode(
    defaultValue: mapped['default'],
    win: mapped['win'],
    mac: mapped['mac'],
    linux: mapped['linux'],
    wsl: mapped['wsl'],
  );
}

PlatformPermission? parsePlatformPermissionFlags(
  String flagName,
  List<String>? values,
) {
  final mapped = _mapPlatformValues(
    _parsePlatformFlagValues(flagName, values, allowDefault: true),
    (value) {
      if (!isPermissionOctal(value)) {
        throw DotweaveError(
          "Invalid --$flagName permission '$value'.",
          code: 'INVALID_PERMISSION',
          hint: "Use a 4-character octal permission like '0600' or '0755'.",
        );
      }

      return value;
    },
  );

  if (mapped == null) {
    return null;
  }

  final defaultValue = mapped['default'];

  if (defaultValue == null) {
    // The TS cast permits a permission record without `default`; trackTarget
    // then crashes in `parsePermissionOctal(configuredPermission.default)`
    // with this exact message (`undefined` -> `null`). Dart's non-nullable
    // `PlatformPermission.defaultValue` forces that failure to surface here.
    throw Exception(
      'Invalid permission octal: null. '
      'Expected a 4-character octal string like "0600" or "0755".',
    );
  }

  return PlatformPermission(
    defaultValue: defaultValue,
    win: mapped['win'],
    mac: mapped['mac'],
    linux: mapped['linux'],
    wsl: mapped['wsl'],
  );
}
