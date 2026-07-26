/// Platform key discriminating dotweave behavior. Mirrors the TS `PlatformKey`
/// string union, as an enum so that every dispatch over it is checked for
/// exhaustiveness instead of falling through a `default:` branch.
///
/// [wire] is the on-disk/config spelling and is the single source of truth for
/// serialization, so the JSON shape is unchanged.
enum PlatformKey {
  win('win'),
  mac('mac'),
  linux('linux'),
  wsl('wsl');

  const PlatformKey(this.wire);

  /// Spelling used in `manifest.jsonc` and on the command line.
  final String wire;

  /// Returns the key for [value], or `null` when it is not a known platform.
  static PlatformKey? tryParse(String value) {
    for (final key in values) {
      if (key.wire == value) {
        return key;
      }
    }

    return null;
  }

  @override
  String toString() => wire;
}

/// Mirror of the TS `PlatformStringValue` readonly object: a default string
/// plus optional per-platform overrides. The TS `default` field is named
/// [defaultValue] because `default` is a reserved word in Dart.
class PlatformStringValue {
  const PlatformStringValue({
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

  @override
  bool operator ==(Object other) {
    return other is PlatformStringValue &&
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
    return 'PlatformStringValue(default: $defaultValue'
        '${win == null ? '' : ', win: $win'}'
        '${mac == null ? '' : ', mac: $mac'}'
        '${linux == null ? '' : ', linux: $linux'}'
        '${wsl == null ? '' : ', wsl: $wsl'})';
  }
}

bool isWslEnvironment(
  String osRelease,
  String? wslDistroName,
  String? wslInterop,
) {
  final hasWslMarker =
      (wslDistroName != null && wslDistroName.trim().isNotEmpty) ||
      (wslInterop != null && wslInterop.trim().isNotEmpty);

  return hasWslMarker || osRelease.toLowerCase().contains('microsoft');
}

PlatformKey detectCurrentPlatformKey(
  String platformName,
  String osRelease,
  String? wslDistroName,
  String? wslInterop,
) {
  switch (platformName) {
    case 'win32':
      return PlatformKey.win;
    case 'darwin':
      return PlatformKey.mac;
    case 'linux':
      return isWslEnvironment(osRelease, wslDistroName, wslInterop)
          ? PlatformKey.wsl
          : PlatformKey.linux;
    default:
      return PlatformKey.linux;
  }
}

/// Picks the override for [platformKey], falling back to [defaultValue]. WSL
/// falls back to the linux override first, since a WSL user gets linux
/// semantics unless they say otherwise.
///
/// Every per-platform record in the schema (sync mode, permission, repo path,
/// local path) resolves this way, so they all route through here rather than
/// repeating the fallback chain.
T resolveForPlatform<T extends Object>(
  PlatformKey platformKey, {
  required T defaultValue,
  T? win,
  T? mac,
  T? linux,
  T? wsl,
}) {
  return switch (platformKey) {
    PlatformKey.win => win ?? defaultValue,
    PlatformKey.mac => mac ?? defaultValue,
    PlatformKey.linux => linux ?? defaultValue,
    PlatformKey.wsl => wsl ?? linux ?? defaultValue,
  };
}

String resolvePlatformValue(
  PlatformStringValue value,
  PlatformKey platformKey,
) {
  return resolveForPlatform(
    platformKey,
    defaultValue: value.defaultValue,
    win: value.win,
    mac: value.mac,
    linux: value.linux,
    wsl: value.wsl,
  );
}
