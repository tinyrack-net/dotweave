import 'dart:io';

/// Reads an environment variable, returning null when it is not set.
///
/// Taken as a parameter wherever this package consults the environment
/// (`NO_COLOR`, `FORCE_COLOR`, `CI`, `TERM`, `STRICLI_NO_COLOR`) so that an
/// application can supply its own view — a validated wrapper, a test double,
/// or a config-file overlay — instead of the process environment.
typedef EnvLookup = String? Function(String name);

/// Default [EnvLookup] over [Platform.environment].
///
/// Falls back to a case-insensitive scan on Windows, where the OS itself
/// treats variable names case-insensitively but [Platform.environment] keys
/// preserve whatever casing the parent process used. Without this,
/// `set no_color=1` in `cmd.exe` would be silently ignored.
String? lookupPlatformEnv(String name) {
  final direct = Platform.environment[name];

  if (direct != null || !Platform.isWindows) {
    return direct;
  }

  final upperName = name.toUpperCase();

  for (final entry in Platform.environment.entries) {
    if (entry.key.toUpperCase() == upperName) {
      return entry.value;
    }
  }

  return null;
}
