import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/file_mode.dart';
import 'package:dotweave/src/util/posix_chmod.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-local-snapshot-',
    );

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  ResolvedSyncConfigEntry createEntry(
    SyncConfigEntryKind kind,
    String localPath,
    String repoPath,
    SyncMode mode, [
    int? permission,
  ]) {
    return ResolvedSyncConfigEntry(
      configuredLocalPath: PlatformStringValue(defaultValue: localPath),
      configuredMode: PlatformSyncMode(defaultValue: mode),
      configuredPermission: permission == null
          ? null
          : PlatformPermission(defaultValue: formatPermissionOctal(permission)),
      kind: kind,
      localPath: localPath,
      mode: mode,
      modeExplicit: true,
      permission: permission,
      permissionExplicit: permission != null,
      profiles: const [],
      profilesExplicit: false,
      repoPath: repoPath,
    );
  }

  EffectiveSyncConfig createConfig(List<ResolvedSyncConfigEntry> entries) {
    return EffectiveSyncConfig(
      age: const RuntimeAgeConfig(
        identityFile: '/tmp/keys.txt',
        recipients: [],
      ),
      entries: entries,
      version: 7,
    );
  }

  tearDown(() async {
    while (temporaryDirectories.isNotEmpty) {
      final directory = temporaryDirectories.removeLast();

      if (await Directory(directory).exists()) {
        await Directory(directory).delete(recursive: true);
      }
    }
  });

  group('local snapshot', () {
    test('does not recurse into ignored directory entries', () async {
      final workspace = await createWorkspace();
      final opencodeDirectory = p.join(workspace, '.config', 'opencode');
      final nodeModulesDirectory = p.join(opencodeDirectory, 'node_modules');
      final nestedDirectory = p.join(nodeModulesDirectory, 'pkg-a', 'dist');
      final trackedFile = p.join(opencodeDirectory, 'settings.json');
      final ignoredFile = p.join(nestedDirectory, 'index.js');

      await Directory(nestedDirectory).create(recursive: true);
      await File(trackedFile).writeAsString('{\n}\n');
      await File(ignoredFile).writeAsString('module.exports = {}\n');

      final config = createConfig([
        createEntry(
          'directory',
          opencodeDirectory,
          '.config/opencode',
          'normal',
        ),
        createEntry(
          'directory',
          nodeModulesDirectory,
          '.config/opencode/node_modules',
          'ignore',
        ),
      ]);
      final snapshot = await buildLocalSnapshot(config);

      expect([...snapshot.keys]..sort(), [
        '.config/opencode',
        '.config/opencode/settings.json',
      ]);
    });

    test(
      'does not collect a directory child through its default repo path when '
      'the child resolves to a platform-specific repo path',
      () async {
        final workspace = await createWorkspace();
        final zshDirectory = p.join(workspace, '.config', 'zsh');
        final platformFile = p.join(zshDirectory, 'platform.zsh');
        final otherFile = p.join(zshDirectory, 'other.zsh');

        await Directory(zshDirectory).create(recursive: true);
        await File(platformFile).writeAsString('wsl platform\n');
        await File(otherFile).writeAsString('other\n');

        final snapshot = await buildLocalSnapshot(
          createConfig([
            createEntry('directory', zshDirectory, '.config/zsh', 'normal'),
            createEntry(
              'file',
              platformFile,
              '.config/zsh/platform.wsl.zsh',
              'normal',
            ),
          ]),
        );

        expect([...snapshot.keys]..sort(), [
          '.config/zsh',
          '.config/zsh/other.zsh',
          '.config/zsh/platform.wsl.zsh',
        ]);
      },
    );

    test(
      'still captures explicit child overrides under ignored directories',
      () async {
        final workspace = await createWorkspace();
        final opencodeDirectory = p.join(workspace, '.config', 'opencode');
        final nodeModulesDirectory = p.join(opencodeDirectory, 'node_modules');
        final nestedDirectory = p.join(nodeModulesDirectory, 'pkg-a');
        final ignoredFile = p.join(nestedDirectory, 'index.js');
        final keepFile = p.join(nodeModulesDirectory, 'keep.js');

        await Directory(nestedDirectory).create(recursive: true);
        await File(ignoredFile).writeAsString('module.exports = {}\n');
        await File(keepFile).writeAsString('export const keep = true;\n');

        final snapshot = await buildLocalSnapshot(
          createConfig([
            createEntry(
              'directory',
              opencodeDirectory,
              '.config/opencode',
              'normal',
            ),
            createEntry(
              'directory',
              nodeModulesDirectory,
              '.config/opencode/node_modules',
              'ignore',
            ),
            createEntry(
              'file',
              keepFile,
              '.config/opencode/node_modules/keep.js',
              'normal',
            ),
          ]),
        );

        expect(snapshot.containsKey('.config/opencode'), isTrue);
        expect(snapshot.containsKey('.config/opencode/node_modules'), isFalse);
        expect(
          snapshot.containsKey('.config/opencode/node_modules/keep.js'),
          isTrue,
        );
        expect(
          snapshot.containsKey('.config/opencode/node_modules/pkg-a/index.js'),
          isFalse,
        );
      },
    );

    test(
      'derives executable metadata from explicit manifest permission',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final keyFile = p.join(workspace, '.ssh', 'id_rsa');

        await Directory(p.join(workspace, '.ssh')).create(recursive: true);
        await File(keyFile).writeAsString('key\n');
        posixChmod(keyFile, 0x1ED); // 0o755

        final snapshot = await buildLocalSnapshot(
          createConfig([
            createEntry('file', keyFile, '.ssh/id_rsa', 'normal', 0x180),
          ]), // 0o600
        );
        final node = snapshot['.ssh/id_rsa'];

        expect(node, isA<FileSnapshotNode>());
        expect((node! as FileSnapshotNode).executable, isFalse);
        expect(node.type, 'file');
      },
    );

    test('captures symlink entries in the snapshot', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final targetFile = p.join(workspace, 'target.txt');
      final linkPath = p.join(workspace, 'link.txt');

      await File(targetFile).writeAsString('target\n');
      await Link(linkPath).create(targetFile);

      final snapshot = await buildLocalSnapshot(
        createConfig([createEntry('file', linkPath, 'link.txt', 'normal')]),
      );

      final node = snapshot['link.txt'];

      expect(node, isA<SymlinkSnapshotNode>());
      expect(node!.type, 'symlink');
      expect((node as SymlinkSnapshotNode).linkTarget, targetFile);
    });

    test('skips absent local paths for normal-mode entries', () async {
      final workspace = await createWorkspace();
      final absentPath = p.join(workspace, 'does-not-exist.txt');

      final snapshot = await buildLocalSnapshot(
        createConfig([
          createEntry('file', absentPath, 'does-not-exist.txt', 'normal'),
        ]),
      );

      expect(snapshot.containsKey('does-not-exist.txt'), isFalse);
    });

    test('handles file-to-directory type change gracefully', () async {
      final workspace = await createWorkspace();
      final filePath = p.join(workspace, 'expected-dir');

      await File(filePath).writeAsString('not a directory\n');

      await expectLater(
        buildLocalSnapshot(
          createConfig([
            createEntry('directory', filePath, 'expected-dir', 'normal'),
          ]),
        ),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            contains('expects a directory'),
          ),
        ),
      );
    });

    test(
      'handles permission-only entries without explicit configured permission',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final scriptFile = p.join(workspace, 'script.sh');

        await Directory(workspace).create(recursive: true);
        await File(scriptFile).writeAsString('#!/bin/sh\n');
        posixChmod(scriptFile, 0x1ED); // 0o755

        final snapshot = await buildLocalSnapshot(
          createConfig([
            createEntry('file', scriptFile, 'script.sh', 'normal'),
          ]),
        );

        final node = snapshot['script.sh'];

        expect(node, isA<FileSnapshotNode>());
        expect(node!.type, 'file');
        expect((node as FileSnapshotNode).executable, isTrue);
      },
    );
  });
}
