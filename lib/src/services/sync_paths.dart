import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/config/xdg.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/sync-paths.ts`: repo-path construction inside the home
// root and tracked-entry resolution helpers.

/// Mirrors node:path `resolve` using the platform-native path context.
String _resolvePath(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

String buildRepoPathWithinRoot(
  String absolutePath,
  String rootPath,
  String description,
) {
  final String relativePath;

  try {
    relativePath = p.relative(absolutePath, from: rootPath);
  } on p.PathException {
    // node:path `relative` returns the absolute target when no relative path
    // exists (e.g. across Windows drives), which fails the inside-root check
    // below; package:path throws instead.
    throw DotweaveError(
      '$description must stay inside the configured home root.',
      code: 'TARGET_OUTSIDE_ROOT',
      details: ['Target: $absolutePath', 'Allowed root: $rootPath'],
      hint: 'Use a path inside $rootPath.',
    );
  }

  // node:path `relative` returns '' for identical paths; package:path
  // returns '.'.
  if (relativePath == '' || relativePath == '.') {
    throw DotweaveError(
      '$description resolves to the root directory, which cannot be tracked '
      'directly.',
      code: 'TARGET_ROOT_DISALLOWED',
      details: ['Target: $absolutePath', 'Root: $rootPath'],
      hint: 'Choose a file or subdirectory inside $rootPath.',
    );
  }

  if (p.isAbsolute(relativePath) ||
      relativePath.startsWith('..') ||
      relativePath == '..') {
    throw DotweaveError(
      '$description must stay inside the configured home root.',
      code: 'TARGET_OUTSIDE_ROOT',
      details: ['Target: $absolutePath', 'Allowed root: $rootPath'],
      hint: 'Use a path inside $rootPath.',
    );
  }

  return normalizeSyncRepoPath(relativePath);
}

PlatformStringValue buildConfiguredHomeLocalPath(String repoPath) {
  return PlatformStringValue(
    defaultValue: '$homeSymbol$pathSeparator$repoPath',
  );
}

String? tryBuildRepoPathWithinRoot(
  String absolutePath,
  String rootPath,
  String description,
) {
  try {
    return buildRepoPathWithinRoot(absolutePath, rootPath, description);
  } on DotweaveError {
    // "Is this path inside the root?" is a question, so a rejection is an
    // answer rather than a failure. Narrowed so that only the validation
    // errors this asks about are absorbed.
    return null;
  }
}

String? tryNormalizeRepoPathInput(String value) {
  try {
    return normalizeSyncRepoPath(value);
  } on DotweaveError {
    return null;
  }
}

ResolvedSyncConfigEntry? resolveTrackedEntry(
  String target,
  List<ResolvedSyncConfigEntry> entries,
  String cwd,
  String homeDirectory,
) {
  final resolvedTargetPath = _resolvePath([
    cwd,
    expandHomePath(target, homeDirectory),
  ]);
  final byLocalPath = [
    for (final entry in entries)
      if (entry.localPath == resolvedTargetPath) entry,
  ];

  final List<ResolvedSyncConfigEntry> matches;

  if (byLocalPath.isNotEmpty || isExplicitLocalPath(target)) {
    matches = byLocalPath;
  } else {
    final normalizedRepoPath = tryNormalizeRepoPathInput(target);
    matches = normalizedRepoPath == null
        ? const []
        : [
            for (final entry in entries)
              if (entry.repoPath == normalizedRepoPath) entry,
          ];
  }

  if (matches.length > 1) {
    throw DotweaveError(
      'Multiple tracked sync entries match: $target',
      code: 'TARGET_CONFLICT',
      hint: 'Use an explicit local path to choose the tracked entry.',
    );
  }

  return matches.isEmpty ? null : matches[0];
}
