import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/xdg.dart';
import 'package:dotweave/src/lib/env.dart';
import 'package:dotweave/src/lib/string.dart';

/// Mirrors NodeJS `os.platform()` for the values dotweave distinguishes.
String _osPlatform() {
  if (Platform.isWindows) {
    return 'win32';
  }
  if (Platform.isMacOS) {
    return 'darwin';
  }
  return Platform.operatingSystem;
}

/// Mirrors NodeJS `os.release()` closely enough for WSL detection: the
/// string contains the kernel release (e.g. `...-microsoft-standard-WSL2`).
String _osRelease() {
  return Platform.operatingSystemVersion;
}

/// Mirrors node:os `homedir()` for the platforms dotweave supports.
String _osHomedir() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? '';
  }
  return Platform.environment['HOME'] ?? '';
}

/// Test seam standing in for the vitest `vi.mock("#app/lib/env.ts")` module
/// mock used by the sync service integration suites: when set, every env read
/// that would fall back to the process-wide [ENV] resolves against this
/// override instead. Production code never sets it; test fixtures must reset
/// it to `null` in teardown.
Env? testEnvOverride;

/// Test seam standing in for the vitest
/// `vi.spyOn(platformConfig, "detectCurrentPlatformKey").mockReturnValue(...)`
/// spy used by the sync service integration suites: when set,
/// [resolveCurrentPlatformKey] returns it directly. Production code never
/// sets it; test fixtures must reset it to `null` in teardown.
PlatformKey? testPlatformKeyOverride;

/// The TS module reads the global `ENV` and `node:os` directly; the Dart port
/// keeps the same call shapes but accepts optional [Env]/platform overrides
/// in place of vitest module mocks.
String? readEnvValue(String name, {Env? env}) {
  return normalizeConfiguredValue((env ?? testEnvOverride ?? ENV)[name]);
}

String resolveHomeDirectoryFromEnv({Env? env}) {
  return resolveHomeDirectory(readEnvValue('HOME', env: env));
}

String resolveXdgConfigHomeFromEnv({Env? env}) {
  return resolveXdgConfigHome(
    readEnvValue('HOME', env: env),
    readEnvValue('XDG_CONFIG_HOME', env: env),
  );
}

String resolveDotweaveHomeDirectoryFromEnv({
  Env? env,
  String? platform,
  String? osHomeDirectory,
}) {
  return resolveDotweaveHomeDirectory(
    appData: readEnvValue('APPDATA', env: env),
    dotweaveHome: readEnvValue('DOTWEAVE_HOME', env: env),
    home: readEnvValue('HOME', env: env),
    localAppData: readEnvValue('LOCALAPPDATA', env: env),
    osHomeDirectory: osHomeDirectory ?? _osHomedir(),
    platform: platform ?? _osPlatform(),
    userProfile: readEnvValue('USERPROFILE', env: env),
    xdgConfigHome: readEnvValue('XDG_CONFIG_HOME', env: env),
  );
}

String resolveDotweaveGlobalConfigFilePathFromEnv({
  Env? env,
  String? platform,
  String? osHomeDirectory,
}) {
  return resolveDotweaveGlobalConfigFilePath(
    resolveDotweaveHomeDirectoryFromEnv(
      env: env,
      platform: platform,
      osHomeDirectory: osHomeDirectory,
    ),
  );
}

String resolveDotweaveSyncDirectoryFromEnv({
  Env? env,
  String? platform,
  String? osHomeDirectory,
}) {
  return resolveDotweaveSyncDirectory(
    resolveDotweaveHomeDirectoryFromEnv(
      env: env,
      platform: platform,
      osHomeDirectory: osHomeDirectory,
    ),
  );
}

PlatformKey resolveCurrentPlatformKey({
  Env? env,
  String? platform,
  String? osRelease,
}) {
  final platformKeyOverride = testPlatformKeyOverride;

  if (platformKeyOverride != null) {
    return platformKeyOverride;
  }

  return detectCurrentPlatformKey(
    platform ?? _osPlatform(),
    osRelease ?? _osRelease(),
    readEnvValue('WSL_DISTRO_NAME', env: env),
    readEnvValue('WSL_INTEROP', env: env),
  );
}
