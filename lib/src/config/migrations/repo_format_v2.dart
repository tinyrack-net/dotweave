import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/repo_format_migration.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:path/path.dart' as p;

const _physicalProfilesRoot = 'profiles';

/// Recursively rewrites every `<name>.dotweave.symlink` metadata file whose
/// stored target is an absolute path inside [homeDirectory] into the portable
/// `~/...` form (format 1 → 2).
///
/// Relative targets and absolute targets outside HOME are left verbatim, and
/// physical symlinks are skipped -- format 0 → 1 already converted those.
/// Idempotent: a file already in portable form is not rewritten at all, so a
/// no-op migration does not churn mtimes across the whole tree.
///
/// Takes [homeDirectory] explicitly so it is unit-testable without the global
/// environment seam, mirroring how format 1 splits out its own walker.
Future<void> rewriteSymlinkArtifactTargets(
  String directory,
  String homeDirectory,
) async {
  final entries = await listDirectoryEntries(directory);

  for (final entry in entries) {
    final entryPath = p.join(directory, entry.name);
    final stats = await getPathStats(entryPath);

    if (stats == null || stats.isSymbolicLink) {
      continue;
    }

    if (stats.isDirectory) {
      await rewriteSymlinkArtifactTargets(entryPath, homeDirectory);
      continue;
    }

    if (!entry.name.endsWith(AppConstants.sync.symlinkArtifactSuffix)) {
      continue;
    }

    final storedTarget = await File(entryPath).readAsString();
    final portableTarget = normalizePortableLinkTarget(
      storedTarget,
      homeDirectory,
    );

    if (portableTarget == storedTarget) {
      continue;
    }

    await writeFileNode(entryPath, (
      contents: portableTarget,
      executable: false,
    ));
  }
}

/// Only targets that match the *migrating machine's* HOME can be anchored. In
/// practice that is the machine which created the links, so the rewrite lands;
/// anything else stays verbatim and is surfaced by the non-portable-target
/// warning on the next push.
Future<void> migrateRepositoryFormatV1ToV2(
  String repositoryDirectory,
  ResolvedSyncConfig config,
) async {
  final profilesDirectory = p.join(repositoryDirectory, _physicalProfilesRoot);

  if ((await getPathStats(profilesDirectory))?.isDirectory != true) {
    return;
  }

  await rewriteSymlinkArtifactTargets(
    profilesDirectory,
    resolveHomeDirectoryFromEnv(),
  );
}
