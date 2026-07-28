import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/repo_format_migration.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:path/path.dart' as p;

const _physicalProfilesRoot = 'profiles';

/// Recursively converts every physical symlink artifact under a directory into
/// a `<name>.dotweave.symlink` regular metadata file (format 0 → 1). Real
/// directories are recursed into; regular files are left untouched. Idempotent:
/// once no physical symlinks remain, re-running is a no-op.
Future<void> _convertPhysicalSymlinks(String directory) async {
  final entries = await listDirectoryEntries(directory);

  for (final entry in entries) {
    final entryPath = p.join(directory, entry.name);
    final stats = await getPathStats(entryPath);

    if (stats == null) {
      continue;
    }

    if (stats.isSymbolicLink) {
      final linkTarget = toPosixLinkTarget(await readLinkTarget(entryPath));
      final metadataPath =
          '$entryPath${AppConstants.sync.symlinkArtifactSuffix}';

      await writeFileNode(metadataPath, (
        contents: linkTarget,
        executable: false,
      ));
      // Remove only the link node; `removePath` unlinks a symlink/junction
      // without recursing into its target.
      await removePath(entryPath);
      continue;
    }

    if (stats.isDirectory) {
      await _convertPhysicalSymlinks(entryPath);
    }
  }
}

Future<void> migrateRepositoryFormatV0ToV1(
  String repositoryDirectory,
  ResolvedSyncConfig config,
) async {
  final profilesDirectory = p.join(repositoryDirectory, _physicalProfilesRoot);

  if ((await getPathStats(profilesDirectory))?.isDirectory != true) {
    return;
  }

  await _convertPhysicalSymlinks(profilesDirectory);
}
