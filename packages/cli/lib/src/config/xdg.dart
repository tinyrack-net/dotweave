import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/lib/string.dart';
import 'package:path/path.dart' as p;

/// Mirrors node:path `resolve` using the platform-native path context:
/// absolute (or Windows root-relative) parts restart resolution, the current
/// working directory seeds the chain, and the result is normalized.
String _resolve(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

/// Mirrors node:os `homedir()` for the platforms dotweave supports.
String _osHomedir() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? '';
  }
  return Platform.environment['HOME'] ?? '';
}

String resolveHomeDirectory(String? home) {
  final configuredValue = normalizeConfiguredValue(home);

  if (configuredValue != null) {
    return _resolve([configuredValue]);
  }

  return _resolve([_osHomedir()]);
}

String resolveXdgConfigHome(String? home, String? xdgConfigHome) {
  final configuredValue = normalizeConfiguredValue(xdgConfigHome);

  if (configuredValue != null) {
    return _resolve([configuredValue]);
  }

  return _resolve([resolveHomeDirectory(home), '.config']);
}

String resolveDotweaveConfigDirectory(String xdgConfigHome) {
  return _resolve([xdgConfigHome, AppConstants.xdg.appDirectoryName]);
}

String resolveDotweaveHomeDirectory({
  String? appData,
  String? dotweaveHome,
  String? home,
  String? localAppData,
  String? osHomeDirectory,
  required String platform,
  String? userProfile,
  String? xdgConfigHome,
}) {
  final configuredDotweaveHome = normalizeConfiguredValue(dotweaveHome);

  if (configuredDotweaveHome != null) {
    return _resolve([configuredDotweaveHome]);
  }

  if (platform == 'win32') {
    final configuredAppData = normalizeConfiguredValue(appData);
    if (configuredAppData != null) {
      return _resolve([configuredAppData, AppConstants.xdg.appDirectoryName]);
    }

    final configuredLocalAppData = normalizeConfiguredValue(localAppData);
    if (configuredLocalAppData != null) {
      return _resolve([
        configuredLocalAppData,
        AppConstants.xdg.appDirectoryName,
      ]);
    }

    final configuredUserProfile = normalizeConfiguredValue(userProfile);
    if (configuredUserProfile != null) {
      return _resolve([
        configuredUserProfile,
        'AppData',
        'Roaming',
        AppConstants.xdg.appDirectoryName,
      ]);
    }

    return _resolve([
      normalizeConfiguredValue(osHomeDirectory) ?? _osHomedir(),
      'AppData',
      'Roaming',
      AppConstants.xdg.appDirectoryName,
    ]);
  }

  return resolveDotweaveConfigDirectory(
    resolveXdgConfigHome(home, xdgConfigHome),
  );
}

String resolveDotweaveGlobalConfigFilePath(String dotweaveConfigDirectory) {
  return _resolve([
    dotweaveConfigDirectory,
    AppConstants.globalConfig.fileName,
  ]);
}

String resolveDotweaveSyncDirectory(String dotweaveConfigDirectory) {
  return _resolve([
    dotweaveConfigDirectory,
    AppConstants.xdg.syncDirectoryName,
  ]);
}

String expandHomePath(String value, String? home) {
  var expandedValue = value.trim();
  final homeDirectory = resolveHomeDirectory(home);

  if (expandedValue == '~') {
    expandedValue = homeDirectory;
  } else if (expandedValue.startsWith('~/')) {
    expandedValue = _resolve([homeDirectory, expandedValue.substring(2)]);
  }

  return expandedValue;
}

String expandConfiguredPath(
  String value,
  String? home,
  String? xdgConfigHome, [
  String? Function(String name)? readEnv,
]) {
  var expandedValue = value.trim();

  if (readEnv != null && expandedValue.contains('%')) {
    expandedValue = expandWindowsEnvVars(expandedValue, readEnv);
  }

  expandedValue = expandHomePath(expandedValue, home);
  final resolvedXdgConfigHome = resolveXdgConfigHome(home, xdgConfigHome);

  final xdgMatch = RegExp(
    r'^\$(?:\{XDG_CONFIG_HOME\}|XDG_CONFIG_HOME)(?:/(.*))?$',
  ).firstMatch(expandedValue);
  if (xdgMatch != null) {
    final xdgSuffix = xdgMatch.group(1);
    expandedValue = xdgSuffix != null
        ? _resolve([resolvedXdgConfigHome, xdgSuffix])
        : resolvedXdgConfigHome;
  }

  return expandedValue;
}

String resolveConfiguredAbsolutePath(
  String value,
  String? home,
  String? xdgConfigHome, [
  String? Function(String name)? readEnv,
]) {
  final expandedValue = expandConfiguredPath(
    value,
    home,
    xdgConfigHome,
    readEnv,
  );

  if (!p.isAbsolute(expandedValue)) {
    throw Exception(
      'Configured path must be absolute or start with ~ or '
      '\$XDG_CONFIG_HOME: $value',
    );
  }

  return _resolve([expandedValue]);
}

String expandWindowsEnvVars(
  String value,
  String? Function(String name) readEnv,
) {
  return value.replaceAllMapped(RegExp('%([^%]+)%'), (match) {
    final varName = match.group(1)!;
    final envValue = normalizeConfiguredValue(readEnv(varName));

    if (envValue == null) {
      throw Exception('Environment variable %$varName% is not defined.');
    }

    return envValue;
  });
}
