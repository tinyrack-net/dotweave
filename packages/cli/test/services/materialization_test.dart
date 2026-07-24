import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/file_mode.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/path_util.dart';
import 'package:dotweave/src/lib/posix_chmod.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/pull_apply.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List bufferFrom(String value) {
  return Uint8List.fromList(utf8.encode(value));
}

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-local-materialization-',
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

      try {
        await Directory(directory).delete(recursive: true);
      } on FileSystemException {
        // Mirrors `rm(directory, { force: true, recursive: true })`.
      }
    }
  });

  group('local materialization', () {
    test(
      'does not scan ignored child directory descendants while planning pull',
      () async {
        final workspace = await createWorkspace();
        final opencodeDirectory = p.join(workspace, '.config', 'opencode');
        final nodeModulesDirectory = p.join(opencodeDirectory, 'node_modules');
        final nestedDirectory = p.join(nodeModulesDirectory, 'pkg-a', 'dist');
        final trackedFile = p.join(opencodeDirectory, 'settings.json');
        final ignoredFile = p.join(nestedDirectory, 'index.js');

        await Directory(nestedDirectory).create(recursive: true);
        await File(trackedFile).writeAsString('{\n}\n');
        await File(ignoredFile).writeAsString('module.exports = {}\n');

        final rootEntry = createEntry(
          'directory',
          opencodeDirectory,
          '.config/opencode',
          'normal',
        );
        final config = createConfig([
          rootEntry,
          createEntry(
            'directory',
            nodeModulesDirectory,
            '.config/opencode/node_modules',
            'ignore',
          ),
        ]);
        final existingKeys = <String>{};

        final deletedLocalCount = await countDeletedLocalNodes(
          rootEntry,
          {
            buildDirectoryKey('.config/opencode'),
            '.config/opencode/settings.json',
          },
          config,
          existingKeys,
        );

        expect(deletedLocalCount, 0);
        expect(existingKeys, {
          buildDirectoryKey('.config/opencode'),
          '.config/opencode/settings.json',
        });
      },
    );

    test(
      'skips ignored directory entries entirely while planning pull',
      () async {
        final workspace = await createWorkspace();
        final opencodeDirectory = p.join(workspace, '.config', 'opencode');
        final nodeModulesDirectory = p.join(opencodeDirectory, 'node_modules');
        final nestedDirectory = p.join(nodeModulesDirectory, 'pkg-a', 'dist');
        final ignoredFile = p.join(nestedDirectory, 'index.js');

        await Directory(nestedDirectory).create(recursive: true);
        await File(ignoredFile).writeAsString('module.exports = {}\n');

        final ignoredEntry = createEntry(
          'directory',
          nodeModulesDirectory,
          '.config/opencode/node_modules',
          'ignore',
        );
        final existingKeys = <String>{};

        final deletedLocalCount = await countDeletedLocalNodes(
          ignoredEntry,
          <String>{},
          createConfig([
            createEntry(
              'directory',
              opencodeDirectory,
              '.config/opencode',
              'normal',
            ),
            ignoredEntry,
          ]),
          existingKeys,
        );

        expect(deletedLocalCount, 0);
        expect(existingKeys.length, 0);
      },
    );

    test('records deleted local paths while planning pull', () async {
      final workspace = await createWorkspace();
      final appDirectory = p.join(workspace, '.config', 'app');
      final configFile = p.join(appDirectory, 'config.json');
      final cacheFile = p.join(appDirectory, 'cache.json');

      await Directory(appDirectory).create(recursive: true);
      await File(configFile).writeAsString('{}\n');
      await File(cacheFile).writeAsString('{}\n');

      final existingKeys = <String>{};
      final keyToLocalPath = <String, String>{};
      final entry = createEntry(
        'directory',
        appDirectory,
        '.config/app',
        'normal',
      );

      final deletedLocalCount = await countDeletedLocalNodes(
        entry,
        {buildDirectoryKey('.config/app'), '.config/app/config.json'},
        createConfig([entry]),
        existingKeys,
        keyToLocalPath,
      );

      expect(deletedLocalCount, 1);
      expect(keyToLocalPath['.config/app/cache.json'], cacheFile);
    });

    test(
      'collects only changed local paths for a materialized directory',
      () async {
        final workspace = await createWorkspace();
        final appDirectory = p.join(workspace, '.config', 'app');
        final configFile = p.join(appDirectory, 'config.json');
        final linkPath = p.join(appDirectory, 'current');

        await Directory(appDirectory).create(recursive: true);
        await File(configFile).writeAsString('{"version":1}\n');
        await File(p.join(appDirectory, 'v1')).writeAsString('');
        await createSymlink('./v1', linkPath, SymlinkType.file);

        final entry = createEntry(
          'directory',
          appDirectory,
          '.config/app',
          'normal',
        );

        await File(p.join(appDirectory, 'stale.txt')).writeAsString('old\n');

        expect(
          await collectChangedLocalPaths(
            entry,
            DirectoryEntryMaterialization(
              desiredKeys: {
                buildDirectoryKey('.config/app'),
                '.config/app/config.json',
                '.config/app/current',
                '.config/app/missing.txt',
              },
              nodes: <String, FileLikeSnapshotNode>{
                'config.json': FileSnapshotNode(
                  contents: bufferFrom('{"version":1}\n'),
                  executable: false,
                  secret: false,
                ),
                'current': const SymlinkSnapshotNode(linkTarget: './v1'),
                'missing.txt': FileSnapshotNode(
                  contents: bufferFrom('new\n'),
                  executable: false,
                  secret: false,
                ),
              },
            ),
          ),
          [p.join(appDirectory, 'missing.txt')],
        );
      },
    );

    test(
      'ignores non-executable file permission drift without explicit permission',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final configFile = p.join(workspace, '.config', 'app', 'config.json');

        await Directory(
          p.join(workspace, '.config', 'app'),
        ).create(recursive: true);
        await File(configFile).writeAsString('{"version":1}\n');
        posixChmod(configFile, 0x180); // 0o600

        final entry = createEntry(
          'file',
          configFile,
          '.config/app/config.json',
          'normal',
        );

        expect(
          await collectChangedLocalPaths(
            entry,
            FileEntryMaterialization(
              desiredKeys: {'.config/app/config.json'},
              node: FileSnapshotNode(
                contents: bufferFrom('{"version":1}\n'),
                executable: false,
                secret: false,
              ),
            ),
          ),
          <String>[],
        );
      },
    );

    test('reports executable-bit drift without explicit permission', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final scriptFile = p.join(workspace, '.local', 'bin', 'tool');

      await Directory(
        p.join(workspace, '.local', 'bin'),
      ).create(recursive: true);
      await File(scriptFile).writeAsString('#!/bin/sh\n');
      posixChmod(scriptFile, 0x1A4); // 0o644

      final entry = createEntry(
        'file',
        scriptFile,
        '.local/bin/tool',
        'normal',
      );

      expect(
        await collectChangedLocalPaths(
          entry,
          FileEntryMaterialization(
            desiredKeys: {'.local/bin/tool'},
            node: FileSnapshotNode(
              contents: bufferFrom('#!/bin/sh\n'),
              executable: true,
              secret: false,
            ),
          ),
        ),
        [scriptFile],
      );
    });

    test('reports explicit file permission drift', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final keyFile = p.join(workspace, '.ssh', 'id_rsa');

      await Directory(p.join(workspace, '.ssh')).create(recursive: true);
      await File(keyFile).writeAsString('key\n');
      posixChmod(keyFile, 0x1A4); // 0o644

      final entry = createEntry(
        'file',
        keyFile,
        '.ssh/id_rsa',
        'normal',
        0x180, // 0o600
      );

      expect(
        await collectChangedLocalPaths(
          entry,
          FileEntryMaterialization(
            desiredKeys: {'.ssh/id_rsa'},
            node: FileSnapshotNode(
              contents: bufferFrom('key\n'),
              executable: false,
              secret: false,
            ),
          ),
        ),
        [keyFile],
      );
    });

    test(
      'ignores directory permission drift without explicit permission',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final appDirectory = p.join(workspace, '.config', 'app');

        await Directory(appDirectory).create(recursive: true);
        posixChmod(appDirectory, 0x1C0); // 0o700

        final entry = createEntry(
          'directory',
          appDirectory,
          '.config/app',
          'normal',
        );

        expect(
          await collectChangedLocalPaths(
            entry,
            DirectoryEntryMaterialization(
              desiredKeys: {buildDirectoryKey('.config/app')},
              nodes: const {},
            ),
          ),
          <String>[],
        );
      },
    );

    test('reports explicit directory permission drift', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final sshDirectory = p.join(workspace, '.ssh');

      await Directory(sshDirectory).create(recursive: true);
      posixChmod(sshDirectory, 0x1ED); // 0o755

      final entry = createEntry(
        'directory',
        sshDirectory,
        '.ssh',
        'normal',
        0x180, // 0o600
      );

      expect(
        await collectChangedLocalPaths(
          entry,
          DirectoryEntryMaterialization(
            desiredKeys: {buildDirectoryKey('.ssh')},
            nodes: const {},
          ),
        ),
        [sshDirectory],
      );
    });

    test(
      'includes stale local paths for incremental directory updates',
      () async {
        final workspace = await createWorkspace();
        final appDirectory = p.join(workspace, '.config', 'app');
        final configFile = p.join(appDirectory, 'config.json');
        final staleFile = p.join(appDirectory, 'stale.txt');

        await Directory(appDirectory).create(recursive: true);
        await File(configFile).writeAsString('{"version":1}\n');
        await File(staleFile).writeAsString('old\n');

        final entry = createEntry(
          'directory',
          appDirectory,
          '.config/app',
          'normal',
        );

        expect(
          await collectChangedLocalPaths(
            entry,
            DirectoryEntryMaterialization(
              desiredKeys: {
                buildDirectoryKey('.config/app'),
                '.config/app/config.json',
              },
              nodes: <String, FileLikeSnapshotNode>{
                'config.json': FileSnapshotNode(
                  contents: bufferFrom('{"version":1}\n'),
                  executable: false,
                  secret: false,
                ),
              },
            ),
            createConfig([entry]),
          ),
          [staleFile],
        );
      },
    );

    test('does not materialize a parent default-path artifact for a '
        'platform-specific child repo path', () {
      final rootEntry = createEntry(
        'directory',
        '/home/user/.config/zsh',
        '.config/zsh',
        'normal',
      );
      final childEntry = createEntry(
        'file',
        '/home/user/.config/zsh/platform.zsh',
        '.config/zsh/platform.wsl.zsh',
        'normal',
      );
      final materialization =
          buildEntryMaterialization(rootEntry, <String, SnapshotNode>{
            buildDirectoryKey('.config/zsh'): const DirectorySnapshotNode(),
            '.config/zsh/platform.zsh': FileSnapshotNode(
              contents: bufferFrom('default artifact\n'),
              executable: false,
              secret: false,
            ),
            '.config/zsh/platform.wsl.zsh': FileSnapshotNode(
              contents: bufferFrom('wsl artifact\n'),
              executable: false,
              secret: false,
            ),
            '.config/zsh/other.zsh': FileSnapshotNode(
              contents: bufferFrom('other\n'),
              executable: false,
              secret: false,
            ),
          }, createConfig([rootEntry, childEntry]));

      expect(materialization.type, 'directory');
      expect(materialization.desiredKeys, {
        buildDirectoryKey('.config/zsh'),
        '.config/zsh/other.zsh',
      });
      expect(
        materialization is DirectoryEntryMaterialization
            ? [...materialization.nodes.keys]
            : <String>[],
        ['other.zsh'],
      );
    });

    test(
      'does not count explicit child entry paths as stale parent paths',
      () async {
        final workspace = await createWorkspace();
        final rootDirectory = p.join(workspace, '.config', 'zsh');
        final childDirectory = p.join(rootDirectory, 'plugins');
        final parentFile = p.join(rootDirectory, '.zshrc');
        final childFile = p.join(childDirectory, 'plugin.zsh');

        await Directory(childDirectory).create(recursive: true);
        await File(
          parentFile,
        ).writeAsString('source ~/.zsh/plugins/plugin.zsh\n');
        await File(childFile).writeAsString('echo plugin\n');

        final rootEntry = createEntry(
          'directory',
          rootDirectory,
          '.config/zsh',
          'normal',
        );
        final childEntry = createEntry(
          'directory',
          childDirectory,
          '.config/zsh/plugins',
          'normal',
        );
        final existingKeys = <String>{};
        final keyToLocalPath = <String, String>{};

        final deletedLocalCount = await countDeletedLocalNodes(
          rootEntry,
          {buildDirectoryKey('.config/zsh'), '.config/zsh/.zshrc'},
          createConfig([rootEntry, childEntry]),
          existingKeys,
          keyToLocalPath,
        );

        expect(deletedLocalCount, 0);
        expect(existingKeys, {
          buildDirectoryKey('.config/zsh'),
          '.config/zsh/.zshrc',
        });
        expect(
          keyToLocalPath.containsKey('.config/zsh/plugins/plugin.zsh'),
          false,
        );
      },
    );

    test('does not count a platform-specific child local file as a stale '
        'parent path', () async {
      final workspace = await createWorkspace();
      final rootDirectory = p.join(workspace, '.config', 'zsh');
      final platformFile = p.join(rootDirectory, 'platform.zsh');
      final otherFile = p.join(rootDirectory, 'other.zsh');

      await Directory(rootDirectory).create(recursive: true);
      await File(platformFile).writeAsString('local platform\n');
      await File(otherFile).writeAsString('other\n');

      final rootEntry = createEntry(
        'directory',
        rootDirectory,
        '.config/zsh',
        'normal',
      );
      final childEntry = createEntry(
        'file',
        platformFile,
        '.config/zsh/platform.wsl.zsh',
        'normal',
      );
      final existingKeys = <String>{};
      final keyToLocalPath = <String, String>{};

      final deletedLocalCount = await countDeletedLocalNodes(
        rootEntry,
        {
          buildDirectoryKey('.config/zsh'),
          '.config/zsh/other.zsh',
          '.config/zsh/platform.wsl.zsh',
        },
        createConfig([rootEntry, childEntry]),
        existingKeys,
        keyToLocalPath,
      );

      expect(deletedLocalCount, 0);
      expect(existingKeys, {
        buildDirectoryKey('.config/zsh'),
        '.config/zsh/other.zsh',
      });
      expect(keyToLocalPath.containsKey('.config/zsh/platform.zsh'), false);
    });

    test('should not throw EINVAL when a symlink node in snapshot exists as a '
        'directory locally', () async {
      final workspace = await createWorkspace();
      final appDirectory = p.join(workspace, '.claude');
      final skillsPath = p.join(appDirectory, 'skills');

      await Directory(skillsPath).create(recursive: true);

      final entry = createEntry('directory', appDirectory, '.claude', 'normal');

      final snapshot = DirectoryEntryMaterialization(
        desiredKeys: {'.claude/skills'},
        nodes: const <String, FileLikeSnapshotNode>{
          'skills': SymlinkSnapshotNode(linkTarget: '/some/target'),
        },
      );

      final changedPaths = await collectChangedLocalPaths(entry, snapshot);

      expect(changedPaths, contains(skillsPath));
    });
  });
}
