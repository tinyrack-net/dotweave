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

/// Matches a POSIX-separator path that is absolute on some platform: a Windows
/// drive-letter root (`C:/...`), a UNC or POSIX root (`//server/share`, `/usr`).
///
/// [p.posix.isAbsolute] answers `false` for `C:/Users/x`, and the ambient
/// [p.isAbsolute] answers differently depending on the host, so neither is
/// usable here: the portable-target helpers must behave identically whether
/// they run on Windows or on a Linux CI machine with `platform: 'win32'`.
final RegExp _absolutePosixSeparatorPath = RegExp(r'^([A-Za-z]:/|/)');

String _stripTrailingSlash(String path) {
  return path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
}

/// Canonical repository form of a symlink target read from the filesystem via
/// `readLinkTarget`: POSIX separators, with an absolute target inside
/// [homeDirectory] rewritten to the portable `~` / `~/...` form. Relative
/// targets are already portable and absolute targets outside HOME cannot be
/// made portable, so both keep their shape.
///
/// Only for *raw* targets. Use [normalizePortableLinkTarget] for a value that
/// has already been stored -- this function escapes a literal leading `~`,
/// which would corrupt an already-anchored target.
///
/// The HOME prefix match is purely lexical -- no `realpath` -- and is
/// case-insensitive on Windows only. A target that reaches into HOME through a
/// different real path (because HOME itself is a link) therefore stays
/// verbatim; resolving it would destroy relative targets, add a stat per
/// symlink to the push hot path, and silently rewrite what the user expressed.
String toPortableLinkTarget(
  String rawTarget,
  String homeDirectory, [
  String? platform,
]) {
  final target = toPosixLinkTarget(rawTarget);

  if (!_absolutePosixSeparatorPath.hasMatch(target)) {
    // A *relative* target whose first segment is literally `~` (a directory
    // named `~` beside the link) would be indistinguishable from a
    // home-anchored one once stored. Writing it as `./~/...` keeps it distinct
    // without an escape scheme the artifact format could never drop again: the
    // OS resolves `./~/x` and `~/x` to the same place.
    return isHomeAnchoredLinkTarget(target) ? './$target' : target;
  }

  return _anchorHomePrefix(target, homeDirectory, platform);
}

/// Re-canonicalizes a target that has already been through storage: an
/// artifact file's contents, or a snapshot node built from one. Anchors a
/// legacy absolute target written before repository format 2 and leaves every
/// portable form (`~`, `~/...`, `./~/...`, relative, outside HOME) alone.
///
/// Idempotent, so it is safe on every read and every write. Unlike
/// [toPortableLinkTarget] it does not escape a leading `~`, because at this
/// point a leading `~` already means "home-anchored".
String normalizePortableLinkTarget(
  String storedTarget,
  String homeDirectory, [
  String? platform,
]) {
  final target = toPosixLinkTarget(storedTarget);

  if (!_absolutePosixSeparatorPath.hasMatch(target)) {
    return target;
  }

  return _anchorHomePrefix(target, homeDirectory, platform);
}

/// Rewrites an absolute POSIX-separator [target] that sits inside
/// [homeDirectory] to its `~`-anchored form. Callers must have established
/// that [target] is absolute.
String _anchorHomePrefix(
  String target,
  String homeDirectory,
  String? platform,
) {
  final home = _stripTrailingSlash(toPosixLinkTarget(homeDirectory));

  if (home.isEmpty) {
    return target;
  }

  final caseInsensitive = (platform ?? _processPlatform) == 'win32';
  String comparisonKey(String path) =>
      caseInsensitive ? path.toLowerCase() : path;

  final targetKey = comparisonKey(target);
  final homeKey = comparisonKey(home);

  if (targetKey == homeKey) {
    return _homePrefix;
  }

  // The trailing separator is what keeps `C:/Users/winetree94x/...` from
  // matching a HOME of `C:/Users/winetree94`.
  if (!targetKey.startsWith('$homeKey$_posixPathSeparator')) {
    return target;
  }

  // Slice the suffix from the original so the user's casing under HOME
  // survives byte for byte.
  return '$_homePrefix$_posixPathSeparator'
      '${target.substring(home.length + 1)}';
}

/// Expands the portable form produced by [toPortableLinkTarget] back into an
/// absolute POSIX-separator path rooted at [homeDirectory]. Anything else is
/// returned unchanged. Compose with [toNativeLinkTarget] before handing the
/// result to the OS.
///
/// This deliberately duplicates the `~` semantics of `expandHomePath` in
/// `config/xdg.dart` rather than calling it: `util` may not import `config`,
/// and that function additionally trims its input and resolves through
/// `p.current`, both of which would corrupt a link target.
String fromPortableLinkTarget(String storedTarget, String homeDirectory) {
  if (!isHomeAnchoredLinkTarget(storedTarget)) {
    return storedTarget;
  }

  final home = _stripTrailingSlash(toPosixLinkTarget(homeDirectory));

  if (storedTarget == _homePrefix) {
    return home;
  }

  return '$home$_posixPathSeparator${storedTarget.substring(2)}';
}

/// Whether a stored target is `~` or begins with `~/`.
bool isHomeAnchoredLinkTarget(String storedTarget) {
  return storedTarget == _homePrefix ||
      storedTarget.startsWith('$_homePrefix$_posixPathSeparator');
}

/// Whether a stored target will fail to resolve after a move to another
/// machine or user: an absolute path that is not home-anchored. Drives the
/// push/status/doctor warnings; never blocks an operation.
bool isNonPortableLinkTarget(String storedTarget) {
  if (isHomeAnchoredLinkTarget(storedTarget)) {
    return false;
  }

  return _absolutePosixSeparatorPath.hasMatch(toPosixLinkTarget(storedTarget));
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
