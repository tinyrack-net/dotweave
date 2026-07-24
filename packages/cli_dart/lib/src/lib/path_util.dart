import 'dart:io';

import 'package:path/path.dart' as p;

const String _homePrefix = '~';
const String _posixPathSeparator = '/';

const String homeSymbol = _homePrefix;
const String pathSeparator = _posixPathSeparator;

String buildDirectoryKey(String repoPath) {
  return '$repoPath/';
}

bool isPathEqualOrNested(String path, String rootPath) {
  final String rootToPath;
  try {
    rootToPath = p.relative(path, from: rootPath);
  } on p.PathException {
    // node:path returns the absolute target when no relative path exists
    // (e.g. across Windows drives), which the checks below reject; package:path
    // throws instead.
    return false;
  }

  return rootToPath == '' ||
      (!p.isAbsolute(rootToPath) &&
          !rootToPath.startsWith('..') &&
          rootToPath != '..');
}

bool doPathsOverlap(String leftPath, String rightPath) {
  return isPathEqualOrNested(leftPath, rightPath) ||
      isPathEqualOrNested(rightPath, leftPath);
}

bool isExplicitLocalPath(String target) {
  const homePathPrefix = '$_homePrefix$_posixPathSeparator';

  return target == '.' ||
      target == '..' ||
      target == _homePrefix ||
      target.startsWith('./') ||
      target.startsWith('../') ||
      target.startsWith(homePathPrefix) ||
      p.isAbsolute(target);
}

/// Canonicalizes a symlink target for portable repository storage and
/// comparison by converting Windows backslash separators to POSIX forward
/// slashes. The relative/absolute nature of the target is preserved verbatim.
String toPosixLinkTarget(String target) {
  return target.replaceAll(r'\', '/');
}

/// Converts a POSIX-normalized symlink target back to the native separator for
/// the current platform when materializing an OS link. Only Windows needs the
/// conversion; POSIX platforms keep forward slashes.
String toNativeLinkTarget(String target, [String? platform]) {
  return (platform ?? _processPlatform) == 'win32'
      ? target.replaceAll('/', r'\')
      : target;
}

typedef LinkTargetNormalizerPlatform = String;

/// Mirrors NodeJS `process.platform` for the values dotweave distinguishes.
String get _processPlatform {
  if (Platform.isWindows) {
    return 'win32';
  }
  if (Platform.isMacOS) {
    return 'darwin';
  }
  return Platform.operatingSystem;
}

/// Mirrors node:fs `realpathSync.native`; throws when the path cannot be
/// resolved (for example when it does not exist).
String _realpathSyncNative(String path) {
  return File(path).resolveSymbolicLinksSync();
}

/// Mirrors node:path `resolve` using the platform-native path context.
String _resolvePath(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

String _joinPath(List<String> paths) {
  return p.joinAll(paths);
}

String normalizeLinkTargetWithDependencies(
  String target,
  String? baseDir, {
  LinkTargetNormalizerPlatform? platform,
  String Function(String path)? realpathSyncNative,
  String Function(List<String> paths)? resolvePath,
  String Function(String path)? dirnamePath,
  String Function(String path)? basenamePath,
  String Function(List<String> paths)? joinPath,
  bool Function(String path)? isAbsolutePath,
}) {
  final effectivePlatform = platform ?? _processPlatform;
  final effectiveRealpathSyncNative = realpathSyncNative ?? _realpathSyncNative;
  final effectiveResolvePath = resolvePath ?? _resolvePath;
  final effectiveDirnamePath = dirnamePath ?? p.dirname;
  final effectiveBasenamePath = basenamePath ?? p.basename;
  final effectiveJoinPath = joinPath ?? _joinPath;
  final effectiveIsAbsolutePath = isAbsolutePath ?? p.isAbsolute;

  final absoluteTarget = baseDir != null && !effectiveIsAbsolutePath(target)
      ? effectiveResolvePath([baseDir, target])
      : target;

  if (effectivePlatform != 'win32') {
    return absoluteTarget;
  }

  String normalizeSlashes(String path) =>
      path.replaceAll(r'\', '/').toLowerCase();

  String resolveIfWindowsRootRelative(String path) {
    if (path.startsWith(r'\') && !path.startsWith(r'\\')) {
      return effectiveResolvePath([path]);
    }
    return path;
  }

  try {
    return normalizeSlashes(effectiveRealpathSyncNative(absoluteTarget));
  } catch (_) {
    if (baseDir != null) {
      try {
        final dir = effectiveDirnamePath(absoluteTarget);
        final base = effectiveBasenamePath(absoluteTarget);
        return normalizeSlashes(
          effectiveJoinPath([effectiveRealpathSyncNative(dir), base]),
        );
      } catch (_) {
        return normalizeSlashes(resolveIfWindowsRootRelative(absoluteTarget));
      }
    }

    return normalizeSlashes(resolveIfWindowsRootRelative(absoluteTarget));
  }
}

String normalizeLinkTarget(String target, [String? baseDir]) {
  return normalizeLinkTargetWithDependencies(target, baseDir);
}
