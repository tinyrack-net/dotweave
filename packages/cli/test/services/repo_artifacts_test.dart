import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/posix_chmod.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-repo-artifacts-',
    );

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  ResolvedSyncConfigEntry createConfigEntry({
    PlatformStringValue configuredLocalPath = const PlatformStringValue(
      defaultValue: '~/.config/app',
    ),
    PlatformSyncMode configuredMode = const PlatformSyncMode(
      defaultValue: 'normal',
    ),
    ConfiguredSyncRepoPath? configuredRepoPath,
    SyncConfigEntryKind kind = 'directory',
    String localPath = '/home/user/.config/app',
    SyncMode mode = 'normal',
    List<String> profiles = const [],
    bool profilesExplicit = false,
    String repoPath = '.config/app',
  }) {
    return ResolvedSyncConfigEntry(
      configuredLocalPath: configuredLocalPath,
      configuredMode: configuredMode,
      configuredRepoPath: configuredRepoPath,
      kind: kind,
      localPath: localPath,
      mode: mode,
      modeExplicit: true,
      permissionExplicit: false,
      profiles: profiles,
      profilesExplicit: profilesExplicit,
      repoPath: repoPath,
    );
  }

  EffectiveSyncConfig createConfig(
    ResolvedSyncConfigEntry entry, [
    String? activeProfile,
  ]) {
    return EffectiveSyncConfig(
      activeProfile: activeProfile,
      age: const RuntimeAgeConfig(identityFile: 'keys.txt', recipients: []),
      entries: [entry],
      profiles: const [],
      version: AppConstants.sync.configVersion,
    );
  }

  ArtifactOwnershipConfig ownershipOf(EffectiveSyncConfig config) {
    return (entries: config.entries, profiles: config.profiles);
  }

  tearDown(() async {
    while (temporaryDirectories.isNotEmpty) {
      final directory = temporaryDirectories.removeLast();

      if (await Directory(directory).exists()) {
        await Directory(directory).delete(recursive: true);
      }
    }
  });

  group('repo-artifacts service', () {
    test('collects artifact profiles from entries', () {
      final entries = [
        createConfigEntry(profiles: ['profile-a', 'profile-b']),
        createConfigEntry(profiles: ['profile-b', 'profile-c']),
      ];
      final profiles = collectArtifactProfiles(entries);
      expect(profiles.contains(AppConstants.sync.defaultProfile), isTrue);
      expect(profiles.contains('profile-a'), isTrue);
      expect(profiles.contains('profile-b'), isTrue);
      expect(profiles.contains('profile-c'), isTrue);
      expect(profiles.length, 4);
    });

    test('builds artifact keys correctly', () {
      expect(
        buildArtifactKey(
          const DirectoryRepoArtifact(profile: 'default', repoPath: 'config'),
        ),
        'default/config/',
      );

      expect(
        buildArtifactKey(
          FileRepoArtifact(
            category: 'plain',
            contents: Uint8List(0),
            executable: false,
            profile: 'default',
            repoPath: 'file.txt',
          ),
        ),
        'default/file.txt',
      );
    });

    test(
      'keeps artifact keys logical while resolving physical profiles paths',
      () {
        expect(
          buildArtifactKey(
            FileRepoArtifact(
              category: 'plain',
              contents: Uint8List(0),
              executable: false,
              profile: 'work',
              repoPath: '.gitconfig',
            ),
          ),
          'work/.gitconfig',
        );

        expect(
          buildArtifactKey(
            const DirectoryRepoArtifact(
              profile: 'work',
              repoPath: '.config/app',
            ),
          ),
          'work/.config/app/',
        );

        expect(
          buildArtifactKey(
            FileRepoArtifact(
              category: 'secret',
              contents: Uint8List(0),
              executable: false,
              profile: 'work',
              repoPath: '.ssh/id',
            ),
          ),
          'work/.ssh/id${AppConstants.sync.secretArtifactSuffix}',
        );

        expect(
          resolveArtifactRelativePath(
            category: 'plain',
            profile: 'work',
            repoPath: '.gitconfig',
          ),
          'profiles/work/.gitconfig',
        );

        expect(
          resolveArtifactRelativePath(
            category: 'secret',
            profile: 'work',
            repoPath: '.ssh/id',
          ),
          'profiles/work/.ssh/id${AppConstants.sync.secretArtifactSuffix}',
        );
      },
    );

    test('identifies secret artifact paths', () {
      expect(
        isSecretArtifactPath(
          'file.txt${AppConstants.sync.secretArtifactSuffix}',
        ),
        isTrue,
      );
      expect(isSecretArtifactPath('file.txt'), isFalse);
    });

    test('strips secret artifact suffix', () {
      final path = 'file.txt${AppConstants.sync.secretArtifactSuffix}';
      expect(stripSecretArtifactSuffix(path), 'file.txt');
      expect(stripSecretArtifactSuffix('file.txt'), isNull);
    });

    test('resolves artifact relative paths', () {
      expect(
        resolveArtifactRelativePath(
          category: 'plain',
          profile: 'work',
          repoPath: 'config',
        ),
        'profiles/work/config',
      );

      expect(
        resolveArtifactRelativePath(
          category: 'secret',
          profile: 'work',
          repoPath: 'secrets.json',
        ),
        'profiles/work/secrets.json${AppConstants.sync.secretArtifactSuffix}',
      );
    });

    test('parses artifact relative paths', () {
      const relativePath = 'profiles/home/.bashrc';
      final parsed = parseArtifactRelativePath(relativePath);
      expect(parsed.profile, 'home');
      expect(parsed.repoPath, '.bashrc');
      expect(parsed.secret, isFalse);

      final secretPath =
          'profiles/work/token${AppConstants.sync.secretArtifactSuffix}';
      final parsedSecret = parseArtifactRelativePath(secretPath);
      expect(parsedSecret.profile, 'work');
      expect(parsedSecret.repoPath, 'token');
      expect(parsedSecret.secret, isTrue);
    });

    test('parses only physical profiles artifact paths', () {
      expect(parseArtifactRelativePath('profiles/work/.gitconfig'), (
        profile: 'work',
        repoPath: '.gitconfig',
        secret: false,
        symlink: false,
      ));

      expect(
        parseArtifactRelativePath(
          'profiles/work/.ssh/id${AppConstants.sync.secretArtifactSuffix}',
        ),
        (profile: 'work', repoPath: '.ssh/id', secret: true, symlink: false),
      );

      expect(
        parseArtifactRelativePath(
          'profiles/work/.claude/skills'
          '${AppConstants.sync.symlinkArtifactSuffix}',
        ),
        (
          profile: 'work',
          repoPath: '.claude/skills',
          secret: false,
          symlink: true,
        ),
      );

      expect(
        () => parseArtifactRelativePath('docs/readme.md'),
        throwsA(isA<DotweaveError>()),
      );
      expect(
        () => parseArtifactRelativePath('work/.gitconfig'),
        throwsA(isA<DotweaveError>()),
      );
    });

    test('classifies all-platform ignored artifacts as prunable', () {
      final entry = createConfigEntry(
        configuredMode: const PlatformSyncMode(defaultValue: 'ignore'),
        mode: 'ignore',
        repoPath: '.config/app/settings.json',
        kind: 'file',
      );
      final config = createConfig(entry);

      expect(
        classifyArtifactOwnership(
          config,
          ownershipOf(config),
          parseArtifactRelativePath(
            'profiles/default/.config/app/settings.json',
          ),
          'file',
        ),
        'ignored-prunable',
      );
    });

    test('classifies platform-ignored artifacts owned by another platform as '
        'protected', () {
      final entry = createConfigEntry(
        configuredMode: const PlatformSyncMode(
          defaultValue: 'normal',
          win: 'ignore',
        ),
        configuredRepoPath: const PlatformStringValue(
          defaultValue: '.config/app',
          win: 'AppData/Roaming/app',
        ),
        mode: 'ignore',
        repoPath: 'AppData/Roaming/app',
      );
      final config = createConfig(entry);

      expect(
        classifyArtifactOwnership(
          config,
          ownershipOf(config),
          parseArtifactRelativePath(
            'profiles/default/.config/app/settings.json',
          ),
          'file',
        ),
        'platform-protected',
      );
    });

    test('classifies platform-specific ignored artifacts without another owner '
        'as prunable', () {
      final entry = createConfigEntry(
        configuredMode: const PlatformSyncMode(
          defaultValue: 'normal',
          win: 'ignore',
        ),
        configuredRepoPath: const PlatformStringValue(
          defaultValue: '.config/app',
          win: 'AppData/Roaming/app',
        ),
        mode: 'ignore',
        repoPath: 'AppData/Roaming/app',
      );
      final config = createConfig(entry);

      expect(
        classifyArtifactOwnership(
          config,
          ownershipOf(config),
          parseArtifactRelativePath(
            'profiles/default/AppData/Roaming/app/settings.json',
          ),
          'file',
        ),
        'ignored-prunable',
      );
    });

    test(
      'classifies WSL-ignored linux/default artifacts as platform-protected',
      () {
        final entry = createConfigEntry(
          configuredMode: const PlatformSyncMode(
            defaultValue: 'normal',
            linux: 'secret',
            wsl: 'ignore',
          ),
          configuredRepoPath: const PlatformStringValue(
            defaultValue: '.config/app',
            linux: '.config/app',
            wsl: 'Ubuntu/app',
          ),
          mode: 'ignore',
          repoPath: 'Ubuntu/app',
        );
        final config = createConfig(entry);

        expect(
          classifyArtifactOwnership(
            config,
            ownershipOf(config),
            parseArtifactRelativePath(
              'profiles/default/.config/app/settings.json',
            ),
            'file',
          ),
          'platform-protected',
        );
      },
    );

    test(
      'classifies inactive-profile artifacts with an entry as protected',
      () {
        final entry = createConfigEntry(
          configuredMode: const PlatformSyncMode(defaultValue: 'ignore'),
          kind: 'file',
          mode: 'ignore',
          profiles: ['work'],
          profilesExplicit: true,
          repoPath: '.gitconfig',
        );
        final config = createConfig(entry);

        expect(
          classifyArtifactOwnership(
            config,
            ownershipOf(config),
            parseArtifactRelativePath('profiles/work/.gitconfig'),
            'file',
          ),
          'platform-protected',
        );
      },
    );

    test('collects physical profiles artifacts as logical keys', () async {
      final workspace = await createWorkspace();
      final config = EffectiveSyncConfig(
        activeProfile: AppConstants.sync.defaultProfile,
        age: const RuntimeAgeConfig(identityFile: 'keys.txt', recipients: []),
        entries: const [],
        profiles: const [],
        version: AppConstants.sync.configVersion,
      );

      await Directory(
        p.join(workspace, 'profiles', 'work', '.config', 'app'),
      ).create(recursive: true);
      await File(
        p.join(workspace, 'profiles', 'work', '.gitconfig'),
      ).writeAsString('data');
      await File(
        p.join(
          workspace,
          'profiles',
          'work',
          '.config',
          'app',
          'settings.json',
        ),
      ).writeAsString('{}\n');
      await Directory(p.join(workspace, 'docs')).create(recursive: true);
      await File(
        p.join(workspace, 'docs', 'readme.md'),
      ).writeAsString('support docs\n');
      await Directory(
        p.join(workspace, 'profiles', '.github'),
      ).create(recursive: true);
      await File(
        p.join(workspace, 'profiles', '.github', 'workflow.yml'),
      ).writeAsString('name\n');

      expect(await collectExistingArtifactKeys(workspace, config), {
        'work/.config/app/settings.json',
        'work/.gitconfig',
      });
    });

    test(
      'treats non-executable artifact permission noise as current',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final artifactDirectory = p.join(workspace, 'profiles', 'default');
        final artifactPath = p.join(artifactDirectory, 'file.txt');

        await Directory(artifactDirectory).create(recursive: true);
        await File(artifactPath).writeAsString('data\n');
        posixChmod(artifactPath, 0x180); // 0o600

        expect(
          await isRepoArtifactCurrent(
            workspace,
            FileRepoArtifact(
              category: 'plain',
              contents: Uint8List.fromList(utf8.encode('data\n')),
              executable: false,
              profile: 'default',
              repoPath: 'file.txt',
            ),
          ),
          isTrue,
        );
      },
    );

    test(
      'treats executable artifacts as current when the executable bit matches',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final artifactDirectory = p.join(workspace, 'profiles', 'default');
        final artifactPath = p.join(artifactDirectory, 'tool');

        await Directory(artifactDirectory).create(recursive: true);
        await File(artifactPath).writeAsString('#!/bin/sh\n');
        posixChmod(artifactPath, 0x1ED); // 0o755

        expect(
          await isRepoArtifactCurrent(
            workspace,
            FileRepoArtifact(
              category: 'plain',
              contents: Uint8List.fromList(utf8.encode('#!/bin/sh\n')),
              executable: true,
              profile: 'default',
              repoPath: 'tool',
            ),
          ),
          isTrue,
        );
      },
    );

    test(
      'reports executable artifact drift when the executable bit differs',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final artifactDirectory = p.join(workspace, 'profiles', 'default');
        final artifactPath = p.join(artifactDirectory, 'tool');

        await Directory(artifactDirectory).create(recursive: true);
        await File(artifactPath).writeAsString('#!/bin/sh\n');
        posixChmod(artifactPath, 0x1A4); // 0o644

        expect(
          await isRepoArtifactCurrent(
            workspace,
            FileRepoArtifact(
              category: 'plain',
              contents: Uint8List.fromList(utf8.encode('#!/bin/sh\n')),
              executable: true,
              profile: 'default',
              repoPath: 'tool',
            ),
          ),
          isFalse,
        );
      },
    );
  });
}
