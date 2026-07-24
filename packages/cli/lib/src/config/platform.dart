/// Platform key discriminating dotweave behavior: `win`, `mac`, `linux`, or
/// `wsl`. Mirrors the TS `PlatformKey` string union.
typedef PlatformKey = String;

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
      return 'win';
    case 'darwin':
      return 'mac';
    case 'linux':
      return isWslEnvironment(osRelease, wslDistroName, wslInterop)
          ? 'wsl'
          : 'linux';
    default:
      return 'linux';
  }
}

String resolvePlatformValue(
  PlatformStringValue value,
  PlatformKey platformKey,
) {
  if (platformKey == 'wsl') {
    return value.wsl ?? value.linux ?? value.defaultValue;
  }

  switch (platformKey) {
    case 'win':
      return value.win ?? value.defaultValue;
    case 'mac':
      return value.mac ?? value.defaultValue;
    case 'linux':
      return value.linux ?? value.defaultValue;
    default:
      return value.defaultValue;
  }
}
