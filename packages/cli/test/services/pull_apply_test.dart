import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/pull_apply.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-pull-apply-',
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

  ResolvedSyncConfigEntry createDirectoryEntry([
    String repoPath = '.config/app',
  ]) {
    return ResolvedSyncConfigEntry(
      configuredLocalPath: const PlatformStringValue(
        defaultValue: '~/.config/app',
      ),
      configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
      kind: 'directory',
      localPath: '/tmp/home/.config/app',
      mode: 'normal',
      modeExplicit: false,
      permissionExplicit: false,
      profiles: const [],
      profilesExplicit: false,
      repoPath: repoPath,
    );
  }

  final plainFileNode = FileSnapshotNode(
    contents: Uint8List.fromList([1]),
    executable: false,
    secret: false,
  );

  final secretFileNode = FileSnapshotNode(
    contents: Uint8List.fromList([2]),
    executable: false,
    secret: true,
  );

  const symlinkNode = SymlinkSnapshotNode(linkTarget: '../target');

  group('pull apply helpers', () {
    test(
      'builds desired directory keys for every nested materialized node',
      () {
        final desiredNodes = <String, FileLikeSnapshotNode>{
          'config/settings.json': plainFileNode,
          'config/nested/theme.json': plainFileNode,
          'state/cache/index.json': secretFileNode,
        };

        expect(
          [...buildDesiredDirectoryKeys(createDirectoryEntry(), desiredNodes)]
            ..sort(),
          [
            '.config/app/',
            '.config/app/config/',
            '.config/app/config/nested/',
            '.config/app/state/',
            '.config/app/state/cache/',
          ],
        );
      },
    );

    test('counts plain, secret, symlink, and directory materializations', () {
      expect(
        buildPullCounts([
          null,
          const AbsentEntryMaterialization(desiredKeys: {}),
          FileEntryMaterialization(
            desiredKeys: {'.gitconfig'},
            node: plainFileNode,
          ),
          const FileEntryMaterialization(
            desiredKeys: {'.config/current'},
            node: symlinkNode,
          ),
          DirectoryEntryMaterialization(
            desiredKeys: {
              '.config/app/',
              '.config/app/plain.txt',
              '.config/app/secret.txt',
              '.config/app/current',
            },
            nodes: <String, FileLikeSnapshotNode>{
              'plain.txt': plainFileNode,
              'secret.txt': secretFileNode,
              'current': symlinkNode,
            },
          ),
        ]),
        (
          decryptedFileCount: 1,
          directoryCount: 1,
          plainFileCount: 2,
          symlinkCount: 2,
        ),
      );
    });

    test(
      'marks stale local children before their now-empty parent directory',
      () async {
        final workspace = await createWorkspace();
        final parent = p.join(workspace, 'app');
        final emptyChild = p.join(parent, 'empty');
        final staleFile = p.join(parent, 'stale.txt');

        await Directory(emptyChild).create(recursive: true);
        await File(staleFile).writeAsString('stale\n');

        final result = await collectDeletableLocalKeys(
          {'.config/app/', '.config/app/empty/', '.config/app/stale.txt'},
          <String>{},
          {
            '.config/app/': parent,
            '.config/app/empty/': emptyChild,
            '.config/app/stale.txt': staleFile,
          },
        );

        expect(result.last, '.config/app/');
        expect(
          {...result.sublist(0, result.length - 1)},
          {'.config/app/empty/', '.config/app/stale.txt'},
        );
      },
    );

    test(
      'does not mark a stale directory when unmanaged local children remain',
      () async {
        final workspace = await createWorkspace();
        final parent = p.join(workspace, 'app');
        final staleFile = p.join(parent, 'stale.txt');
        final unmanagedFile = p.join(parent, 'local-only.txt');

        await Directory(parent).create(recursive: true);
        await File(staleFile).writeAsString('stale\n');
        await File(unmanagedFile).writeAsString('keep\n');

        expect(
          await collectDeletableLocalKeys(
            {'.config/app/', '.config/app/stale.txt'},
            <String>{},
            {'.config/app/': parent, '.config/app/stale.txt': staleFile},
          ),
          ['.config/app/stale.txt'],
        );
      },
    );
  });
}
