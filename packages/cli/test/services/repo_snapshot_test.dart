import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/crypto/age/age.dart';
import 'package:dotweave/src/lib/crypto.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/file_mode.dart';
import 'package:dotweave/src/lib/posix_chmod.dart';
import 'package:dotweave/src/services/local_snapshot.dart';
import 'package:dotweave/src/services/repo_snapshot.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-repo-snapshot-',
    );

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  ResolvedSyncConfigEntry createEntry({
    SyncConfigEntryKind kind = 'file',
    required String localPath,
    SyncMode mode = 'normal',
    int? permission,
    List<String> profiles = const ['work'],
    required String repoPath,
  }) {
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
      profiles: profiles,
      profilesExplicit: profiles.isNotEmpty,
      repoPath: repoPath,
    );
  }

  EffectiveSyncConfig createConfig(
    List<ResolvedSyncConfigEntry> entries, {
    String? activeProfile = 'work',
    String identityFile = 'id.txt',
    List<String> recipients = const ['key1'],
  }) {
    return EffectiveSyncConfig(
      activeProfile: activeProfile,
      age: RuntimeAgeConfig(identityFile: identityFile, recipients: recipients),
      entries: entries,
      version: AppConstants.sync.configVersion,
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

  group('repo-snapshot service', () {
    test('scans repository and builds snapshot', () async {
      final workspace = await createWorkspace();

      await Directory(
        p.join(workspace, 'profiles', 'work'),
      ).create(recursive: true);
      await File(
        p.join(workspace, 'profiles', 'work', 'config.json'),
      ).writeAsString('data');

      final config = createConfig([
        createEntry(
          localPath: '/home/user/config.json',
          repoPath: 'config.json',
        ),
      ]);

      final snapshot = await buildRepositorySnapshot(workspace, config);

      expect(snapshot.length, 1);
      expect(snapshot['config.json'], isNotNull);
      expect(snapshot['config.json']?.type, 'file');
    });

    test(
      'derives executable metadata from explicit manifest permission',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final artifactPath = p.join(
          workspace,
          'profiles',
          'work',
          'config.json',
        );

        await Directory(
          p.join(workspace, 'profiles', 'work'),
        ).create(recursive: true);
        await File(artifactPath).writeAsString('data');
        posixChmod(artifactPath, 0x1ED); // 0o755

        final config = createConfig([
          createEntry(
            localPath: '/home/user/config.json',
            permission: 0x180, // 0o600
            repoPath: 'config.json',
          ),
        ]);

        final snapshot = await buildRepositorySnapshot(workspace, config);
        final node = snapshot['config.json'];

        expect(node, isA<FileSnapshotNode>());
        expect((node! as FileSnapshotNode).executable, isFalse);
        expect(node.type, 'file');
      },
    );

    test('handles directory entries', () async {
      final workspace = await createWorkspace();

      await Directory(
        p.join(workspace, 'profiles', 'work', 'dotconfig'),
      ).create(recursive: true);

      final config = createConfig([
        createEntry(
          kind: 'directory',
          localPath: '/home/user/.config',
          repoPath: 'dotconfig',
        ),
      ]);

      final snapshot = await buildRepositorySnapshot(workspace, config);

      expect(snapshot['dotconfig']?.type, 'directory');
    });

    test('reads symlink entries from the repository', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();

      await Directory(
        p.join(workspace, 'profiles', 'work'),
      ).create(recursive: true);
      await Link(
        p.join(workspace, 'profiles', 'work', 'link'),
      ).create('/target/path');

      final config = createConfig([
        createEntry(localPath: '/home/user/link', repoPath: 'link'),
      ]);

      final snapshot = await buildRepositorySnapshot(workspace, config);
      final node = snapshot['link'];

      expect(node, isA<SymlinkSnapshotNode>());
      expect(node!.type, 'symlink');
      expect((node as SymlinkSnapshotNode).linkTarget, '/target/path');
    });

    test('reads encrypted secret file entries', () async {
      final workspace = await createWorkspace();
      final identity = generateIdentity();
      final recipient = await identityToRecipient(identity);
      final identityFile = p.join(workspace, 'id.txt');

      await File(identityFile).writeAsString('$identity\n');
      await Directory(
        p.join(workspace, 'profiles', 'work'),
      ).create(recursive: true);
      await File(
        p.join(
          workspace,
          'profiles',
          'work',
          'secret.conf${AppConstants.sync.secretArtifactSuffix}',
        ),
      ).writeAsString(
        await encryptSecretFile(Uint8List.fromList([1, 2, 3]), [recipient]),
      );

      final config = createConfig(
        [
          createEntry(
            localPath: '/home/user/secret.conf',
            mode: 'secret',
            repoPath: 'secret.conf',
          ),
        ],
        identityFile: identityFile,
        recipients: [recipient],
      );

      final snapshot = await buildRepositorySnapshot(workspace, config);
      final node = snapshot['secret.conf'];

      expect(node, isA<FileSnapshotNode>());

      final fileNode = node! as FileSnapshotNode;

      expect(fileNode.type, 'file');
      expect(fileNode.secret, isTrue);
      expect(fileNode.contents, Uint8List.fromList([1, 2, 3]));
    });

    test(
      'skips entries when resolveSyncRule returns undefined (profile mismatch)',
      () async {
        final workspace = await createWorkspace();

        await Directory(
          p.join(workspace, 'profiles', 'personal'),
        ).create(recursive: true);
        await File(
          p.join(workspace, 'profiles', 'personal', 'personal.conf'),
        ).writeAsString('data');

        final config = createConfig([
          createEntry(
            localPath: '/home/user/personal.conf',
            profiles: ['personal'],
            repoPath: 'personal.conf',
          ),
        ]);

        final snapshot = await buildRepositorySnapshot(workspace, config);

        expect(snapshot.containsKey('personal.conf'), isFalse);
      },
    );

    test('handles multiple profile directories in the repository', () async {
      final workspace = await createWorkspace();

      await Directory(
        p.join(workspace, 'profiles', 'work'),
      ).create(recursive: true);
      await Directory(
        p.join(workspace, 'profiles', 'default'),
      ).create(recursive: true);
      await File(
        p.join(workspace, 'profiles', 'work', 'work.conf'),
      ).writeAsString('data');
      await File(
        p.join(workspace, 'profiles', 'default', 'common.conf'),
      ).writeAsString('data');

      final config = createConfig([
        createEntry(localPath: '/home/user/work.conf', repoPath: 'work.conf'),
        createEntry(
          localPath: '/home/user/common.conf',
          profiles: const [],
          repoPath: 'common.conf',
        ),
      ]);

      final snapshot = await buildRepositorySnapshot(workspace, config);

      expect(snapshot['work.conf'], isNotNull);
      expect(snapshot['common.conf'], isNotNull);
    });

    test('derives executable metadata from file mode when permission is not '
        'explicit', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final artifactPath = p.join(workspace, 'profiles', 'work', 'script.sh');

      await Directory(
        p.join(workspace, 'profiles', 'work'),
      ).create(recursive: true);
      await File(artifactPath).writeAsString('#!/bin/sh');
      posixChmod(artifactPath, 0x1ED); // 0o755

      final config = createConfig([
        createEntry(localPath: '/home/user/script.sh', repoPath: 'script.sh'),
      ]);

      final snapshot = await buildRepositorySnapshot(workspace, config);
      final node = snapshot['script.sh'];

      expect(node, isA<FileSnapshotNode>());
      expect(node!.type, 'file');
      expect((node as FileSnapshotNode).executable, isTrue);
    });

    test('handles empty repository directory gracefully', () async {
      final workspace = await createWorkspace();

      await Directory(
        p.join(workspace, 'profiles', 'default'),
      ).create(recursive: true);

      final config = createConfig(const []);

      final snapshot = await buildRepositorySnapshot(workspace, config);

      expect(snapshot.length, 0);
    });

    test('detects SECRET_STORED_PLAIN for a file marked secret but stored as '
        'plain', () async {
      final workspace = await createWorkspace();

      await Directory(
        p.join(workspace, 'profiles', 'work'),
      ).create(recursive: true);
      await File(
        p.join(workspace, 'profiles', 'work', 'secret.conf'),
      ).writeAsString('data');

      final config = createConfig([
        createEntry(
          localPath: '/home/user/secret.conf',
          mode: 'secret',
          repoPath: 'secret.conf',
        ),
      ]);

      await expectLater(
        buildRepositorySnapshot(workspace, config),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.code,
            'code',
            'SECRET_STORED_PLAIN',
          ),
        ),
      );
    });
  });
}
