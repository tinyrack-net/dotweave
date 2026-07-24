import 'dart:io';

import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/fs_errors.dart';
import 'package:dotweave/src/lib/windows/reparse.dart';
import 'package:dotweave/src/lib/windows/win32_links.dart' as win32_links;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('reparse data buffer codec', () {
    test('round-trips mount point reparse data', () {
      final encoded = encodeMountPointReparseData(
        r'\??\C:\Temp\target dir',
        r'C:\Temp\target dir',
      );
      final decoded = decodeReparseData(encoded);

      expect(decoded.tag, ioReparseTagMountPoint);
      expect(decoded.isMountPoint, true);
      expect(decoded.isSymlink, false);
      expect(decoded.substituteName, r'\??\C:\Temp\target dir');
      expect(decoded.printName, r'C:\Temp\target dir');
      expect(decoded.flags, 0);
    });

    test('rejects buffers that are too short or carry unknown tags', () {
      expect(
        () => decodeReparseData(
          encodeMountPointReparseData('', '').sublist(0, 8),
        ),
        throwsArgumentError,
      );

      final unknownTag = encodeMountPointReparseData(r'\??\C:\x', r'C:\x');
      unknownTag[3] = 0x80; // Rewrite the tag to a non-name reparse tag.
      expect(() => decodeReparseData(unknownTag), throwsArgumentError);
    });

    test('normalizes NT namespace prefixes and trailing separators', () {
      expect(normalizeReparseTarget(r'\??\C:\Users\demo\'), r'C:\Users\demo');
      expect(normalizeReparseTarget(r'\\?\C:\Users\demo'), r'C:\Users\demo');
      expect(normalizeReparseTarget(r'\??\C:\'), r'C:\');
      expect(
        normalizeReparseTarget(r'\??\UNC\server\share\'),
        r'\\server\share',
      );
      expect(
        normalizeReparseTarget('../relative/target'),
        '../relative/target',
      );
      expect(normalizeReparseTarget(r'..\relative\'), r'..\relative');
    });
  });

  group(
    'win32 links',
    () {
      late Directory workspace;

      setUp(() async {
        workspace = await Directory.systemTemp.createTemp('dotweave-links-');
      });

      tearDown(() async {
        try {
          await workspace.delete(recursive: true);
        } on FileSystemException {
          // Best-effort cleanup.
        }
      });

      Future<String> createTargetDirectory() async {
        final target = Directory(p.join(workspace.path, 'target-dir'));
        await target.create(recursive: true);
        await File(
          p.join(target.path, 'payload.txt'),
        ).writeAsString('payload\n');

        return target.path;
      }

      test(
        'junction create/read/delete round-trip preserves the target',
        () async {
          final targetPath = await createTargetDirectory();
          final junctionPath = p.join(workspace.path, 'junction');

          win32_links.createJunction(junctionPath, targetPath);

          expect(
            await FileSystemEntity.type(junctionPath, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(
            await File(p.join(junctionPath, 'payload.txt')).readAsString(),
            'payload\n',
          );

          final reparseData = win32_links.readReparsePoint(junctionPath);
          expect(reparseData.isMountPoint, true);
          expect(reparseData.substituteName, '\\??\\$targetPath');
          expect(reparseData.printName, targetPath);
          expect(await readLinkTarget(junctionPath), targetPath);

          win32_links.deleteLinkNode(junctionPath);

          expect(
            await FileSystemEntity.type(junctionPath, followLinks: false),
            FileSystemEntityType.notFound,
          );
          expect(
            await File(p.join(targetPath, 'payload.txt')).readAsString(),
            'payload\n',
          );
        },
      );

      test('directory symlinks store relative targets verbatim', () async {
        await createTargetDirectory();
        final linkPath = p.join(workspace.path, 'dir-link');

        win32_links.createSymbolicLink('target-dir', linkPath, directory: true);

        expect(
          await FileSystemEntity.type(linkPath, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(
          await File(p.join(linkPath, 'payload.txt')).readAsString(),
          'payload\n',
        );

        final reparseData = win32_links.readReparsePoint(linkPath);
        expect(reparseData.isSymlink, true);
        expect(reparseData.isRelative, true);
        expect(reparseData.substituteName, 'target-dir');
        expect(await readLinkTarget(linkPath), 'target-dir');

        win32_links.deleteLinkNode(linkPath);
        expect(await pathExists(p.join(workspace.path, 'target-dir')), true);
      });

      test(
        'file symlinks resolve through the stored relative target',
        () async {
          final filePath = p.join(workspace.path, 'value.txt');
          await File(filePath).writeAsString('value\n');
          final linkPath = p.join(workspace.path, 'file-link');

          win32_links.createSymbolicLink(
            'value.txt',
            linkPath,
            directory: false,
          );

          expect(await File(linkPath).readAsString(), 'value\n');
          expect(await readLinkTarget(linkPath), 'value.txt');

          win32_links.deleteLinkNode(linkPath);
          expect(await File(filePath).readAsString(), 'value\n');
        },
      );

      test('readReparsePoint rejects nodes without reparse data', () async {
        final filePath = p.join(workspace.path, 'plain.txt');
        await File(filePath).writeAsString('plain\n');

        expect(
          () => win32_links.readReparsePoint(filePath),
          throwsA(
            isA<FileSystemException>().having(
              isInvalidArgument,
              'isInvalidArgument',
              true,
            ),
          ),
        );
      });

      test(
        'deleteLinkNode refuses to delete non-reparse directories',
        () async {
          final targetPath = await createTargetDirectory();

          expect(
            () => win32_links.deleteLinkNode(targetPath),
            throwsA(
              isA<FileSystemException>().having(
                (error) => error.osError?.errorCode,
                'osError.errorCode',
                4390,
              ),
            ),
          );
          expect(
            await File(p.join(targetPath, 'payload.txt')).readAsString(),
            'payload\n',
          );
        },
      );

      test(
        'createSymlink with an explicit junction type stores absolute targets',
        () async {
          final targetPath = await createTargetDirectory();
          final junctionPath = p.join(workspace.path, 'typed-junction');

          await createSymlink('target-dir', junctionPath, SymlinkType.junction);

          final reparseData = win32_links.readReparsePoint(junctionPath);
          expect(reparseData.isMountPoint, true);
          expect(await readLinkTarget(junctionPath), targetPath);

          win32_links.deleteLinkNode(junctionPath);
          expect(await pathExists(targetPath), true);
        },
      );

      test('createJunction rejects relative targets', () {
        expect(
          () => win32_links.createJunction(
            p.join(workspace.path, 'bad-junction'),
            r'..\relative-target',
          ),
          throwsArgumentError,
        );
      });
    },
    skip: Platform.isWindows ? false : 'Windows-only Win32 link tests',
  );
}
