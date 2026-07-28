import 'dart:io';

import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/posix_chmod.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

PathStats createMockStats({
  required bool isFile,
  required bool isDirectory,
  required bool isSymbolicLink,
  required int mode,
}) {
  return PathStats(
    isFile: isFile,
    isDirectory: isDirectory,
    isSymbolicLink: isSymbolicLink,
    mode: mode,
  );
}

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-filesystem-',
    );

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  tearDown(() async {
    while (temporaryDirectories.isNotEmpty) {
      final directory = temporaryDirectories.removeLast();

      try {
        await Directory(directory).delete(recursive: true);
      } on FileSystemException {
        // Mirrors `rm(directory, { force: true, recursive: true })`.
      }
    }
  });

  group('filesystem helpers', () {
    test('checks path existence and missing stats', () async {
      final workspace = await createWorkspace();
      final filePath = p.join(workspace, 'value.txt');

      expect(await pathExists(filePath), false);
      expect(await getPathStats(filePath), isNull);

      await File(filePath).writeAsString('value\n');

      expect(await pathExists(filePath), true);
      expect((await getPathStats(filePath))?.isFile, true);
    });

    test('reports a path that vanished mid-scan as a DotweaveError', () async {
      // Snapshot walkers stat paths a directory listing just reported. When
      // the path is removed in between, the caller must get an actionable
      // error rather than the `TypeError` the old `!` assertion produced.
      final workspace = await createWorkspace();
      final filePath = p.join(workspace, 'vanished.txt');

      await File(filePath).writeAsString('value\n');
      expect((await requirePathStats(filePath)).isFile, true);

      await File(filePath).delete();

      await expectLater(
        requirePathStats(filePath),
        throwsA(
          isA<DotweaveError>()
              .having((error) => error.code, 'code', 'PATH_DISAPPEARED')
              .having(
                (error) => error.details.join(),
                'details',
                contains(filePath),
              ),
        ),
      );
    });

    test('lists directory entries in sorted order', () async {
      final workspace = await createWorkspace();

      await Directory(p.join(workspace, 'b')).create(recursive: true);
      await File(p.join(workspace, 'c.txt')).writeAsString('c\n');
      await File(p.join(workspace, 'a.txt')).writeAsString('a\n');

      final entries = await listDirectoryEntries(workspace);

      expect(entries.map((entry) => entry.name).toList(), [
        'a.txt',
        'b',
        'c.txt',
      ]);
    });

    test('writes regular files and preserves executable bits', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final filePath = p.join(workspace, 'bin', 'tool.sh');

      await writeFileNode(filePath, (
        contents: '#!/bin/sh\nexit 0\n',
        executable: true,
      ));

      expect(await File(filePath).readAsString(), contains('#!/bin/sh'));
      expect((await File(filePath).stat()).mode & 0x49, isNot(0)); // 0o111
    });

    test('writes symlinks after removing existing content', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final linkPath = p.join(workspace, 'links', 'current');

      await Directory(p.join(workspace, 'links')).create(recursive: true);
      await File(linkPath).writeAsString('old\n');
      await writeSymlinkNode(linkPath, '../target.txt');

      expect(await readLinkTarget(linkPath), '../target.txt');
    });

    test('copies regular files and symlinks', () async {
      final workspace = await createWorkspace();
      final sourceDirectory = p.join(workspace, 'source');
      final targetDirectory = p.join(workspace, 'target');
      final filePath = p.join(sourceDirectory, 'nested', 'value.txt');
      final linkPath = p.join(sourceDirectory, 'nested', 'value-link');

      await Directory(
        p.join(sourceDirectory, 'nested'),
      ).create(recursive: true);
      await File(filePath).writeAsString('payload\n');
      if (!Platform.isWindows) {
        posixChmod(filePath, 0x1ED); // 0o755
      }
      await createSymlink('value.txt', linkPath);

      await copyFilesystemNode(sourceDirectory, targetDirectory);

      expect(
        await File(
          p.join(targetDirectory, 'nested', 'value.txt'),
        ).readAsString(),
        'payload\n',
      );
      expect(
        await readLinkTarget(p.join(targetDirectory, 'nested', 'value-link')),
        'value.txt',
      );
    });

    test('replaces and removes paths atomically', () async {
      final workspace = await createWorkspace();
      final targetPath = p.join(workspace, 'config.json');
      final stagedPath = p.join(workspace, 'next.json');

      await File(targetPath).writeAsString('old\n');
      await File(stagedPath).writeAsString('new\n');

      await replacePathAtomically(targetPath, stagedPath);

      expect(await File(targetPath).readAsString(), 'new\n');
      expect(await pathExists(stagedPath), false);

      await removePathAtomically(targetPath);

      expect(await pathExists(targetPath), false);
      await removePathAtomically(targetPath);
      expect(await pathExists(targetPath), false);
    });

    test(
      'writes text files atomically for create and overwrite flows',
      () async {
        final workspace = await createWorkspace();
        final targetPath = p.join(workspace, 'nested', 'config.json');

        await writeTextFileAtomically(targetPath, 'first\n');
        expect(await File(targetPath).readAsString(), 'first\n');

        await writeTextFileAtomically(targetPath, 'second\n');
        expect(await File(targetPath).readAsString(), 'second\n');
      },
    );

    test(
      'throws for unsupported filesystem entry types in copyFilesystemNode',
      () async {
        final workspace = await createWorkspace();
        final sourcePath = p.join(workspace, 'source');
        final targetPath = p.join(workspace, 'target');

        final mockStats = createMockStats(
          isDirectory: false,
          isSymbolicLink: false,
          isFile: false,
          mode: 0,
        );

        await expectLater(
          copyFilesystemNode(sourcePath, targetPath, mockStats),
          throwsA(
            isA<DotweaveError>().having(
              (error) => error.message,
              'message',
              contains('Unsupported filesystem entry'),
            ),
          ),
        );
      },
    );

    test('pathExists returns true for readable directories', () async {
      final workspace = await createWorkspace();
      final subDir = p.join(workspace, 'subdir');
      await Directory(subDir).create(recursive: true);
      expect(await pathExists(subDir), true);
    });

    test(
      'listDirectoryEntries returns empty array for empty directories',
      () async {
        final workspace = await createWorkspace();
        final emptyDir = p.join(workspace, 'empty');
        await Directory(emptyDir).create(recursive: true);
        expect(await listDirectoryEntries(emptyDir), isEmpty);
      },
    );

    test(
      'writeTextFileAtomically creates a new file with correct content',
      () async {
        final workspace = await createWorkspace();
        final filePath = p.join(workspace, 'new.txt');
        await writeTextFileAtomically(filePath, 'hello\n');
        expect(await File(filePath).readAsString(), 'hello\n');
      },
    );

    test('removePathAtomically is idempotent for missing paths', () async {
      final workspace = await createWorkspace();
      final missingPath = p.join(workspace, 'does-not-exist');
      await expectLater(removePathAtomically(missingPath), completes);
    });

    test('applies explicit fileMode when provided to writeFileNode', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final filePath = p.join(workspace, 'ssh', 'id_rsa');

      await writeFileNode(filePath, (
        contents: 'private-key-content\n',
        executable: false,
      ), fileMode: 0x180); // 0o600

      final stats = await File(filePath).stat();
      expect(stats.mode & 0x1FF, 0x180); // mode & 0o777 == 0o600
    });

    test(
      'falls back to executable mode when fileMode is not provided',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final filePath = p.join(workspace, 'bin', 'script.sh');

        await writeFileNode(filePath, (
          contents: '#!/bin/sh\n',
          executable: true,
        ));

        final stats = await File(filePath).stat();
        expect(stats.mode & 0x1FF, 0x1ED); // mode & 0o777 == 0o755
      },
    );
  });
}
