import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'collation.dart';
import 'error.dart';
import 'file_mode.dart';
import 'fs_errors.dart';
import 'native_stat.dart';
import 'posix_chmod.dart';
import 'windows/reparse.dart';
import 'windows/win32_links.dart' as win32_links;

/// Path metadata mirroring the subset of Node's `fs.Stats` used by dotweave.
///
/// `dart:io` has no `lstat`, so link detection is derived from
/// `FileSystemEntity.type(path, followLinks: false)`; [mode] is `0` for
/// symlink nodes (dotweave never reads a link node's own mode).
class PathStats {
  const PathStats({
    required this.isFile,
    required this.isDirectory,
    required this.isSymbolicLink,
    required this.mode,
  });

  final bool isFile;
  final bool isDirectory;
  final bool isSymbolicLink;
  final int mode;
}

/// A directory entry mirroring the subset of Node's `fs.Dirent` used by
/// dotweave.
class DirectoryEntry {
  const DirectoryEntry({
    required this.name,
    required this.path,
    required this.isFile,
    required this.isDirectory,
    required this.isSymbolicLink,
  });

  final String name;
  final String path;
  final bool isFile;
  final bool isDirectory;
  final bool isSymbolicLink;
}

/// The Windows symlink node kinds accepted by [createSymlink], mirroring
/// Node's `fs.symlink` type argument.
enum SymlinkType { file, dir, junction }

String _randomUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));

  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();

  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

PathNotFoundException _pathNotFound(String path) {
  return PathNotFoundException(
    path,
    const OSError('No such file or directory', 2),
  );
}

/// Checks whether a filesystem path currently exists.
Future<bool> pathExists(String path) async {
  // Fast path: a plain file/dir trivially exists; a definitely-missing path
  // trivially doesn't. Reparse points must delegate — existence follows the
  // link chain here (dangling symlinks report notFound), which only the
  // dart:io implementation reproduces.
  final fast = nativeLstatSync(path);
  switch (fast.outcome) {
    case NativeStatOutcome.present:
      return true;
    case NativeStatOutcome.absent:
      return false;
    case NativeStatOutcome.cannotAnswer:
      break;
  }

  final type = await FileSystemEntity.type(path);

  return type != FileSystemEntityType.notFound;
}

/// Reads path metadata while treating missing paths as an absent result.
Future<PathStats?> getPathStats(String path) async {
  // Fast path: one native metadata call instead of the two dart:io IO-thread
  // round trips below. Links and edge cases fall through to the original
  // implementation, kept verbatim.
  final fast = nativeLstatSync(path);
  switch (fast.outcome) {
    case NativeStatOutcome.present:
      return PathStats(
        isFile: fast.isFile,
        isDirectory: fast.isDirectory,
        isSymbolicLink: false,
        mode: fast.mode,
      );
    case NativeStatOutcome.absent:
      return null;
    case NativeStatOutcome.cannotAnswer:
      break;
  }

  final type = await FileSystemEntity.type(path, followLinks: false);

  if (type == FileSystemEntityType.notFound) {
    return null;
  }

  if (type == FileSystemEntityType.link) {
    return const PathStats(
      isFile: false,
      isDirectory: false,
      isSymbolicLink: true,
      mode: 0,
    );
  }

  final stats = await FileStat.stat(path);

  if (stats.type == FileSystemEntityType.notFound) {
    return null;
  }

  return PathStats(
    isFile: stats.type == FileSystemEntityType.file,
    isDirectory: stats.type == FileSystemEntityType.directory,
    isSymbolicLink: false,
    mode: stats.mode,
  );
}

/// Reads path metadata for a path a directory walk just reported as present.
///
/// The walk and this stat call are not atomic, so the path can disappear in
/// between (an editor rewriting a dotfile during `dotweave push` is enough).
/// Callers used to assert non-null here, which surfaced that race as an
/// unhandled `TypeError` stack dump instead of an actionable message.
Future<PathStats> requirePathStats(String path) async {
  final stats = await getPathStats(path);

  if (stats == null) {
    throw DotweaveError(
      'Path disappeared while scanning.',
      code: 'PATH_DISAPPEARED',
      details: ['Path: $path'],
      hint: 'Re-run the command; the path was removed mid-scan.',
    );
  }

  return stats;
}

/// Reads path metadata while following symlinks and treating missing paths as
/// an absent result.
Future<PathStats?> getFollowedPathStats(String path) async {
  // Fast path is valid only when the node is not a reparse point: for plain
  // files/dirs the followed and unfollowed answers are identical.
  final fast = nativeLstatSync(path);
  switch (fast.outcome) {
    case NativeStatOutcome.present:
      return PathStats(
        isFile: fast.isFile,
        isDirectory: fast.isDirectory,
        isSymbolicLink: false,
        mode: fast.mode,
      );
    case NativeStatOutcome.absent:
      return null;
    case NativeStatOutcome.cannotAnswer:
      break;
  }

  final stats = await FileStat.stat(path);

  if (stats.type == FileSystemEntityType.notFound) {
    return null;
  }

  return PathStats(
    isFile: stats.type == FileSystemEntityType.file,
    isDirectory: stats.type == FileSystemEntityType.directory,
    isSymbolicLink: false,
    mode: stats.mode,
  );
}

/// Shared type dispatcher for [removePath]/[_renameNode]: fast-path native
/// classification with the dart:io answer for links/edge cases.
Future<FileSystemEntityType> _nodeType(String path) async {
  final fast = nativeLstatSync(path);
  switch (fast.outcome) {
    case NativeStatOutcome.present:
      return fast.isDirectory
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file;
    case NativeStatOutcome.absent:
      return FileSystemEntityType.notFound;
    case NativeStatOutcome.cannotAnswer:
      return FileSystemEntity.type(path, followLinks: false);
  }
}

/// Lists directory entries in a stable name-sorted order.
Future<List<DirectoryEntry>> listDirectoryEntries(String path) async {
  final entries = <DirectoryEntry>[];

  await for (final entity in Directory(path).list(followLinks: false)) {
    entries.add(
      DirectoryEntry(
        name: p.basename(entity.path),
        path: entity.path,
        isFile: entity is File,
        isDirectory: entity is Directory,
        isSymbolicLink: entity is Link,
      ),
    );
  }

  entries.sort((left, right) {
    return compareLocaleLike(left.name, right.name);
  });

  return entries;
}

/// Removes a path like Node's `rm(path, { force: true, recursive: true })`:
/// missing paths are ignored and link nodes are unlinked without ever
/// touching the link target's contents.
Future<void> removePath(String path) async {
  final type = await _nodeType(path);

  switch (type) {
    case FileSystemEntityType.notFound:
      return;
    case FileSystemEntityType.link:
      // Deleting through Link removes only the reparse point / symlink node.
      // Never use Directory.delete for link nodes.
      await Link(path).delete();
    case FileSystemEntityType.directory:
      await Directory(path).delete(recursive: true);
    default:
      await File(path).delete();
  }
}

Future<void> _renameNode(String from, String to) async {
  final type = await _nodeType(from);

  switch (type) {
    case FileSystemEntityType.notFound:
      throw _pathNotFound(from);
    case FileSystemEntityType.link:
      // Link.rename moves the symlink/junction node itself without following
      // it into the target.
      await Link(from).rename(to);
    case FileSystemEntityType.directory:
      await Directory(from).rename(to);
    default:
      await File(from).rename(to);
  }
}

/// Renames a node by dispatching to the matching `dart:io` entity class,
/// falling back to copy-and-delete when the OS reports a cross-device rename.
Future<void> renamePath(String from, String to) async {
  try {
    await _renameNode(from, to);
  } on FileSystemException catch (error) {
    if (!isCrossDevice(error)) {
      rethrow;
    }

    await copyFilesystemNode(from, to);
    await removePath(from);
  }
}

/// Writes a regular file node with the permissions dotweave should preserve.
///
/// [ensureParent] can be disabled by batch writers that have already created
/// the parent directory (e.g. artifact writes precompute the unique parent
/// set) — the write itself is unchanged.
Future<void> writeFileNode(
  String path,
  ({Object contents, bool executable}) node, {
  int? fileMode,
  bool ensureParent = true,
}) async {
  if (ensureParent) {
    await Directory(p.dirname(path)).create(recursive: true);
  }

  if ((await getPathStats(path))?.isSymbolicLink ?? false) {
    await removePath(path);
  }

  final contents = node.contents;

  if (contents is String) {
    await File(path).writeAsString(contents);
  } else if (contents is List<int>) {
    await File(path).writeAsBytes(contents);
  } else {
    throw ArgumentError.value(
      contents,
      'contents',
      'Expected String or List<int>',
    );
  }

  if (!Platform.isWindows) {
    posixChmod(path, fileMode ?? buildExecutableMode(node.executable));
  }
}

void _createWindowsLink(String target, String path, SymlinkType type) {
  switch (type) {
    case SymlinkType.file:
      win32_links.createSymbolicLink(target, path, directory: false);
    case SymlinkType.dir:
      win32_links.createSymbolicLink(target, path, directory: true);
    case SymlinkType.junction:
      win32_links.createJunction(path, _resolveLinkTarget(target, path));
  }
}

String _resolveLinkTarget(String target, String path) {
  final absoluteTarget = p.isAbsolute(target)
      ? target
      : p.join(p.dirname(path), target);

  return p.normalize(p.absolute(absoluteTarget));
}

/// Creates a symlink while correctly handling Windows symlink types.
Future<void> createSymlink(
  String target,
  String path, [
  SymlinkType? type,
]) async {
  if (!Platform.isWindows) {
    await Link(path).create(target);
    return;
  }

  // On Windows, the symlink type (file, dir, junction) must be specified.
  if (type != null) {
    _createWindowsLink(target, path, type);
    return;
  }

  final absoluteTarget = p.isAbsolute(target)
      ? target
      : p.join(p.dirname(path), target);
  final stats = await getFollowedPathStats(absoluteTarget);

  if (stats?.isDirectory ?? false) {
    // Prefer a real directory symlink: it stores the target verbatim, so a
    // relative target stays relative and the link remains portable across
    // machines. A junction always stores an absolute target, so it is only a
    // fallback for when the OS denies symlink creation (no Developer Mode or
    // administrator privileges).
    try {
      win32_links.createSymbolicLink(target, path, directory: true);
    } catch (error) {
      if (isSymlinkPrivilegeError(error)) {
        win32_links.createJunction(path, _resolveLinkTarget(target, path));
        return;
      }

      rethrow;
    }

    return;
  }

  win32_links.createSymbolicLink(target, path, directory: false);
}

/// Replaces a path with a symlink node and its target.
Future<void> writeSymlinkNode(String path, String linkTarget) async {
  await Directory(p.dirname(path)).create(recursive: true);
  await removePath(path);
  await createSymlink(linkTarget, path);
}

/// Reads the stored target of a symlink or junction node.
///
/// On Windows this decodes the reparse point directly so junction targets are
/// returned deterministically without NT namespace prefixes.
Future<String> readLinkTarget(String path) async {
  if (!Platform.isWindows) {
    return Link(path).target();
  }

  final reparseData = win32_links.readReparsePoint(path);

  return normalizeReparseTarget(reparseData.substituteName);
}

/// Copies a filesystem node into the sync layout while preserving supported
/// node types.
Future<void> copyFilesystemNode(
  String sourcePath,
  String targetPath, [
  PathStats? stats,
]) async {
  final sourceStats = stats ?? await getPathStats(sourcePath);

  if (sourceStats == null) {
    throw _pathNotFound(sourcePath);
  }

  if (sourceStats.isDirectory) {
    await Directory(targetPath).create(recursive: true);

    final entries = await listDirectoryEntries(sourcePath);

    for (final entry in entries) {
      await copyFilesystemNode(
        p.join(sourcePath, entry.name),
        p.join(targetPath, entry.name),
      );
    }

    return;
  }

  if (sourceStats.isSymbolicLink) {
    final linkTarget = await readLinkTarget(sourcePath);
    await writeSymlinkNode(targetPath, linkTarget);

    return;
  }

  if (!sourceStats.isFile) {
    throw DotweaveError('Unsupported filesystem entry: $sourcePath');
  }

  await writeFileNode(targetPath, (
    contents: await File(sourcePath).readAsBytes(),
    executable: isExecutableMode(sourceStats.mode),
  ));
}

/// Swaps a staged path into place with rollback protection for the previous
/// target.
Future<void> replacePathAtomically(String targetPath, String nextPath) async {
  final backupPath = p.join(
    p.dirname(targetPath),
    '.${p.basename(targetPath)}.dotweave-sync-backup-${_randomUuid()}',
  );
  final existingStats = await getPathStats(targetPath);
  var targetMoved = false;

  try {
    if (existingStats != null) {
      await renamePath(targetPath, backupPath);
      targetMoved = true;
    }

    await renamePath(nextPath, targetPath);

    if (targetMoved) {
      await removePath(backupPath);
    }
  } catch (error) {
    if (targetMoved && !(await pathExists(targetPath))) {
      try {
        await renamePath(backupPath, targetPath);
      } catch (_) {
        // Mirrors the TS `.catch(() => {})`: rollback is best-effort.
      }
    }

    rethrow;
  } finally {
    try {
      await removePath(backupPath);
    } catch (_) {
      // Mirrors the TS `.catch(() => {})`: cleanup is best-effort.
    }
  }
}

/// Removes a path through a temporary rename so deletion is completed
/// atomically.
Future<void> removePathAtomically(String targetPath) async {
  final stats = await getPathStats(targetPath);

  if (stats == null) {
    return;
  }

  final backupPath = p.join(
    p.dirname(targetPath),
    '.${p.basename(targetPath)}.dotweave-sync-remove-${_randomUuid()}',
  );

  await renamePath(targetPath, backupPath);
  await removePath(backupPath);
}

/// Writes text content through a staging directory before replacing the
/// target file.
Future<void> writeTextFileAtomically(String targetPath, String contents) async {
  await Directory(p.dirname(targetPath)).create(recursive: true);
  final stagingDirectory = await Directory(
    p.dirname(targetPath),
  ).createTemp('.${p.basename(targetPath)}.dotweave-sync-');
  final stagedPath = p.join(stagingDirectory.path, p.basename(targetPath));

  try {
    await File(stagedPath).writeAsString(contents);
    await replacePathAtomically(targetPath, stagedPath);
  } finally {
    await removePath(stagingDirectory.path);
  }
}
