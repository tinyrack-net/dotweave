import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/status.dart';
import 'package:dotweave/src/services/sync_mode.dart';
import 'package:dotweave/src/services/track.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/sync_fixture.dart';

// Port of `sync.service.test.ts` (part A): the tests from "tracks entries in
// v7 config format" through "deletes ignored child artifacts while preserving
// normal directory siblings".

void main() {
  tearDown(cleanUpSyncFixture);

  group('sync service', () {
    test('tracks entries in v7 config format', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final sharedDirectory = p.join(homeDirectory, '.config', 'zsh');
      final workFile = p.join(homeDirectory, '.gitconfig-work');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(sharedDirectory).create(recursive: true);
      await File(
        p.join(sharedDirectory, 'secrets.zsh'),
      ).writeAsString('export TOKEN=work\n');
      await File(workFile).writeAsString('[include]\npath=~/.gitconfig.work\n');

      setEnvironment(homeDirectory, xdgConfigHome);
      final cwd = homeDirectory;

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: sharedDirectory,
        ),
        cwd,
      );
      await trackTarget(
        TrackRequest(mode: const TrackModeValue('secret'), target: workFile),
        cwd,
      );

      final manifestText = await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).readAsString();
      final config = readManifestJson(manifestText);

      expect(config.version, 8);
      expect(
        (jsonDecode(manifestText) as Map<String, Object?>).containsKey('age'),
        isTrue,
      );
      expect(config.entries, [
        {
          'kind': 'directory',
          'localPath': {'default': '~/.config/zsh'},
          'mode': {'default': 'normal'},
        },
        {
          'kind': 'file',
          'localPath': {'default': '~/.gitconfig-work'},
          'mode': {'default': 'secret'},
        },
      ]);
    });

    test('tracks explicit repoPath values and syncs through them', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\nname=test\n');

      setEnvironment(homeDirectory, xdgConfigHome);

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          repoPath: const PartialPlatformStringValue(
            defaultValue: 'profiles/shared/git/main.conf',
          ),
          target: gitconfig,
        ),
        homeDirectory,
      );

      final manifestPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );
      final config = readManifestJson(await File(manifestPath).readAsString());

      expect(config.entries, [
        {
          'kind': 'file',
          'localPath': {'default': '~/.gitconfig'},
          'repoPath': {'default': 'profiles/shared/git/main.conf'},
          'mode': {'default': 'normal'},
        },
      ]);

      await pushChanges(const PushRequest(dryRun: false));

      final artifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'profiles',
        'shared',
        'git',
        'main.conf',
      );

      expect(await File(artifactPath).readAsString(), contains('name=test'));

      await File(gitconfig).writeAsString('[user]\nname=changed\n');
      await pullChanges(const PullRequest(dryRun: false));

      expect(await File(gitconfig).readAsString(), '[user]\nname=test\n');
    });

    test('writes pushed artifacts under physical profiles layout', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\nname=option-b\n');

      setEnvironment(homeDirectory, xdgConfigHome);

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await trackTarget(
        TrackRequest(mode: const TrackModeValue('normal'), target: gitconfig),
        homeDirectory,
      );

      await pushChanges(const PushRequest(dryRun: false));

      final repositoryDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
      );
      final physicalArtifactPath = p.join(
        repositoryDirectory,
        'profiles',
        'default',
        '.gitconfig',
      );
      final oldLayoutArtifactPath = p.join(
        repositoryDirectory,
        'default',
        '.gitconfig',
      );

      expect(
        await File(physicalArtifactPath).readAsString(),
        '[user]\nname=option-b\n',
      );
      expectPathAbsent(oldLayoutArtifactPath);
    });

    test(
      'keeps generated secret directory artifacts visible to git when ignore '
      'rules match secret artifacts',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final vividentDirectory = p.join(homeDirectory, '.vivident');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(vividentDirectory).create(recursive: true);
        await File(
          p.join(vividentDirectory, 'config.json'),
        ).writeAsString('{"theme":"dark"}\n');
        await File(
          p.join(vividentDirectory, 'state.txt'),
        ).writeAsString('window=main\n');

        setEnvironment(homeDirectory, xdgConfigHome);

        final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );
        await File(
          p.join(syncDirectory, '.gitignore'),
        ).writeAsString('*.dotweave.secret\n');

        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('secret'),
            target: vividentDirectory,
          ),
          homeDirectory,
        );
        await pushChanges(const PushRequest(dryRun: false));

        final configArtifactPath = p.join(
          syncDirectory,
          'profiles',
          'default',
          '.vivident',
          'config.json.dotweave.secret',
        );
        final stateArtifactPath = p.join(
          syncDirectory,
          'profiles',
          'default',
          '.vivident',
          'state.txt.dotweave.secret',
        );

        expect(
          await File(configArtifactPath).readAsString(),
          contains('BEGIN AGE ENCRYPTED FILE'),
        );
        expect(
          await File(stateArtifactPath).readAsString(),
          contains('BEGIN AGE ENCRYPTED FILE'),
        );

        final ignoredStatus = await runGit([
          'status',
          '--ignored',
          '--short',
          '--untracked-files=all',
        ], syncDirectory);
        expect(
          ignoredStatus.stdout,
          isNot(
            contains(
              '!! profiles/default/.vivident/config.json.dotweave.secret',
            ),
          ),
        );
        expect(
          ignoredStatus.stdout,
          isNot(
            contains('!! profiles/default/.vivident/state.txt.dotweave.secret'),
          ),
        );

        final status = await runGit([
          'status',
          '--short',
          '--untracked-files=all',
        ], syncDirectory);
        expect(
          status.stdout,
          contains('?? profiles/default/.vivident/config.json.dotweave.secret'),
        );
        expect(
          status.stdout,
          contains('?? profiles/default/.vivident/state.txt.dotweave.secret'),
        );
      },
    );

    test('keeps repository artifact bytes stable under core.autocrlf before '
        'repeated pull', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\nname=test\n');

      setEnvironment(homeDirectory, xdgConfigHome);

      final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await trackTarget(
        TrackRequest(mode: const TrackModeValue('normal'), target: gitconfig),
        homeDirectory,
      );
      await pushChanges(const PushRequest(dryRun: false));

      final artifactPath = p.join(
        syncDirectory,
        'profiles',
        'default',
        '.gitconfig',
      );

      await runGit(['add', '.'], syncDirectory);
      await runGit(['commit', '-m', 'store artifacts'], syncDirectory);
      await runGit(['config', 'core.autocrlf', 'true'], syncDirectory);

      await File(artifactPath).delete();
      await runGit([
        'checkout',
        '--',
        'profiles/default/.gitconfig',
      ], syncDirectory);

      expect(
        await File(p.join(syncDirectory, '.gitattributes')).readAsString(),
        '* -text\n',
      );
      expect(await File(artifactPath).readAsString(), '[user]\nname=test\n');

      await File(gitconfig).writeAsString('[user]\nname=changed\n');

      await pullChanges(const PullRequest(dryRun: false));
      final secondPull = await preparePull(const PullRequest(dryRun: true));

      expect(await File(gitconfig).readAsString(), '[user]\nname=test\n');
      expect(secondPull.plan.updatedLocalPaths, <String>[]);
    });

    test('updates repoPath when re-tracking an existing entry', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\nname=test\n');

      setEnvironment(homeDirectory, xdgConfigHome);

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );
      await trackTarget(
        TrackRequest(mode: const TrackModeValue('normal'), target: gitconfig),
        homeDirectory,
      );

      final result = await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          repoPath: const PartialPlatformStringValue(
            defaultValue: 'profiles/shared/git/main.conf',
          ),
          target: gitconfig,
        ),
        homeDirectory,
      );

      expect(result.alreadyTracked, isTrue);
      expect(result.changed, isTrue);
      expect(result.repoPath, 'profiles/shared/git/main.conf');

      await pushChanges(const PushRequest(dryRun: false));

      final updatedArtifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'profiles',
        'shared',
        'git',
        'main.conf',
      );
      final originalArtifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.gitconfig',
      );

      expect(
        await File(updatedArtifactPath).readAsString(),
        contains('name=test'),
      );
      await expectLater(
        File(originalArtifactPath).readAsString(),
        throwsA(isA<PathNotFoundException>()),
      );
    });

    test(
      'preserves WSL mode overrides when tracking an existing root',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final bundleDirectory = p.join(homeDirectory, '.config', 'mytool');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);
        mockEnv.wslDistroName = 'Ubuntu';
        final cwd = homeDirectory;

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(bundleDirectory).create(recursive: true);

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );
        await File(
          p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
        ).writeAsString(
          jsonStringify({
            'version': 7,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/mytool'},
                'mode': {'default': 'secret', 'wsl': 'secret'},
              },
            ],
          }),
        );

        final result = await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('secret'),
            target: bundleDirectory,
          ),
          cwd,
        );

        final entries = parseManifestEntries(
          await File(
            p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
          ).readAsString(),
        );

        expect(result.alreadyTracked, isTrue);
        expect(result.changed, isFalse);
        expect(entries[0]['mode'], {'default': 'secret', 'wsl': 'secret'});
      },
    );

    test('manages the active profile through the global config', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final sharedDirectory = p.join(homeDirectory, '.config', 'zsh');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(sharedDirectory).create(recursive: true);
      await File(
        p.join(sharedDirectory, 'secrets.zsh'),
      ).writeAsString('export TOKEN=work\n');

      setEnvironment(homeDirectory, xdgConfigHome);
      final cwd = homeDirectory;

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: sharedDirectory,
        ),
        cwd,
      );
      await setTargetMode(
        SetModeRequest(
          mode: 'secret',
          target: p.join(sharedDirectory, 'secrets.zsh'),
        ),
        cwd,
      );
      await addProfile('work');

      final useResult = await setActiveProfile('work');
      expect(useResult.action, 'use');
      expect(useResult.activeProfile, 'work');
      expect(useResult.profile, 'work');

      final clearResult = await clearActiveProfile();
      expect(clearResult.action, 'clear');
    });

    test('stores child overrides under explicit parent repo paths', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'app');
      final publicFile = p.join(appDirectory, 'public.txt');
      final secretFile = p.join(appDirectory, 'secret.txt');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(appDirectory).create(recursive: true);
      await File(publicFile).writeAsString('public\n');
      await File(secretFile).writeAsString('secret\n');

      setEnvironment(homeDirectory, xdgConfigHome);

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          repoPath: const PartialPlatformStringValue(
            defaultValue: 'profiles/shared/app',
          ),
          target: appDirectory,
        ),
        homeDirectory,
      );
      await setTargetMode(
        SetModeRequest(mode: 'secret', target: secretFile),
        homeDirectory,
      );

      final manifestPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );
      final configEntries = parseManifestEntries(
        await File(manifestPath).readAsString(),
      );

      expect(configEntries, [
        {
          'kind': 'directory',
          'localPath': {'default': '~/.config/app'},
          'repoPath': {'default': 'profiles/shared/app'},
          'mode': {'default': 'normal'},
        },
        {
          'kind': 'file',
          'localPath': {'default': '~/.config/app/secret.txt'},
          'repoPath': {'default': 'profiles/shared/app/secret.txt'},
          'mode': {'default': 'secret'},
        },
      ]);

      await pushChanges(const PushRequest(dryRun: false));

      final publicArtifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'profiles',
        'shared',
        'app',
        'public.txt',
      );
      final secretArtifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'profiles',
        'shared',
        'app',
        'secret.txt.dotweave.secret',
      );

      expect(await File(publicArtifactPath).readAsString(), 'public\n');
      expect(
        await File(secretArtifactPath).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );
    });

    test(
      'collapses redundant WSL mode overrides when updating an existing entry '
      'mode',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final gitconfig = p.join(homeDirectory, '.gitconfig');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);
        mockEnv.wslDistroName = 'Ubuntu';
        final cwd = homeDirectory;

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(homeDirectory).create(recursive: true);
        await File(gitconfig).writeAsString('[user]\nname=test\n');

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );
        await File(
          p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
        ).writeAsString(
          jsonStringify({
            'version': 7,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'mode': {'default': 'secret', 'wsl': 'secret'},
              },
            ],
          }),
        );

        final result = await setTargetMode(
          SetModeRequest(mode: 'secret', target: gitconfig),
          cwd,
        );

        final entries = parseManifestEntries(
          await File(
            p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
          ).readAsString(),
        );

        expect(result.action, 'updated');
        expect(entries[0]['mode'], {'default': 'secret'});
      },
    );

    test('pushes and pulls with the active profile', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final sharedFile = p.join(zshDirectory, 'zshrc');
      final secretsFile = p.join(zshDirectory, 'secrets.zsh');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(sharedFile).writeAsString(
        r'export PATH=$PATH:$HOME/bin'
        '\n',
      );
      await File(secretsFile).writeAsString('export TOKEN=work\n');

      setEnvironment(homeDirectory, xdgConfigHome);
      final cwd = homeDirectory;

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: zshDirectory,
        ),
        cwd,
      );
      await setTargetMode(
        SetModeRequest(mode: 'secret', target: secretsFile),
        cwd,
      );

      await pushChanges(const PushRequest(dryRun: false));

      final sharedArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
        'zshrc',
      );
      final secretArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
        'secrets.zsh.dotweave.secret',
      );

      expect(await File(sharedArtifact).readAsString(), contains('PATH'));
      expect(
        await File(secretArtifact).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );

      await File(secretsFile).writeAsString('local-change\n');
      await pullChanges(const PullRequest(dryRun: false));

      expect(await File(secretsFile).readAsString(), contains('TOKEN=work'));

      await setTargetMode(
        SetModeRequest(mode: 'normal', target: secretsFile),
        cwd,
      );

      final entriesAfterModeChange = parseManifestEntries(
        await File(
          p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
        ).readAsString(),
      );
      final secretEntry = entriesAfterModeChange.firstWhere(
        (entry) =>
            (entry['localPath'] as Map<String, Object?>?)?['default'] ==
            '~/.config/zsh/secrets.zsh',
        orElse: () => <String, Object?>{},
      );

      expect(secretEntry['mode'], {'default': 'normal'});
    });

    test('skips Windows-ignored secret artifacts during pull', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final secretsFile = p.join(zshDirectory, 'secrets.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(secretsFile).writeAsString('export TOKEN=linux\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );
      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 7,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal', 'win': 'ignore'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
              'mode': {'default': 'secret', 'win': 'ignore'},
            },
          ],
        }),
      );

      mockCurrentPlatformKey(PlatformKey.linux);
      await pushChanges(const PushRequest(dryRun: false));

      final secretArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
        'secrets.zsh.dotweave.secret',
      );
      expect(
        await File(secretArtifact).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );

      await File(secretsFile).writeAsString('local-change\n');

      mockCurrentPlatformKey(PlatformKey.win);
      final pullResult = await pullChanges(const PullRequest(dryRun: false));
      expect(pullResult.decryptedFileCount, 0);

      expect(await File(secretsFile).readAsString(), 'local-change\n');
    });

    test('prunes orphaned default-profile artifacts after manifest entries are '
        'removed', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfigFile = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfigFile).writeAsString('[user]\n  name = Dotweave\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      final manifestPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 7,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      await pushChanges(const PushRequest(dryRun: false));

      final artifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.gitconfig',
      );
      expect(
        await File(artifactPath).readAsString(),
        '[user]\n  name = Dotweave\n',
      );

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 7,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': <Object?>[],
        }),
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 1);
      expectPathAbsent(artifactPath);
    });

    test(
      'deletes artifacts for entries changed to explicit ignore during push',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final gitconfigFile = p.join(homeDirectory, '.gitconfig');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(homeDirectory).create(recursive: true);
        await File(gitconfigFile).writeAsString('[user]\n  name = Dotweave\n');

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );

        final manifestPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'manifest.jsonc',
        );

        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'mode': {'default': 'normal'},
              },
            ],
          }),
        );

        await pushChanges(const PushRequest(dryRun: false));

        final artifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.gitconfig',
        );
        expect(
          await File(artifactPath).readAsString(),
          '[user]\n  name = Dotweave\n',
        );

        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'mode': {'default': 'ignore'},
              },
            ],
          }),
        );

        final status = await getStatus();
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(status.push.deletedArtifactCount, 1);
        expect(status.push.changes.deleted, ['default/.gitconfig']);
        expect(result.deletedArtifactCount, 1);
        expectPathAbsent(artifactPath);
      },
    );

    test(
      'deletes secret artifacts for entries changed to explicit ignore during '
      'push',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final tokenDirectory = p.join(homeDirectory, '.config', 'app');
        final tokenFile = p.join(tokenDirectory, 'token');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(tokenDirectory).create(recursive: true);
        await File(tokenFile).writeAsString('super-secret\n');

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );

        final manifestPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'manifest.jsonc',
        );

        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/app/token'},
                'mode': {'default': 'secret'},
              },
            ],
          }),
        );

        await pushChanges(const PushRequest(dryRun: false));

        final artifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'app',
          'token.dotweave.secret',
        );
        expect(
          await File(artifactPath).readAsString(),
          contains('BEGIN AGE ENCRYPTED FILE'),
        );

        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/app/token'},
                'mode': {'default': 'ignore'},
              },
            ],
          }),
        );

        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(result.deletedArtifactCount, 1);
        expectPathAbsent(artifactPath);
      },
    );

    test('deletes directory subtree artifacts for entries changed to explicit '
        'ignore during push', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'app');
      final nestedDirectory = p.join(appDirectory, 'nested');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(nestedDirectory).create(recursive: true);
      await File(
        p.join(appDirectory, 'settings.json'),
      ).writeAsString('{"theme":"dark"}\n');
      await File(
        p.join(nestedDirectory, 'theme.json'),
      ).writeAsString('{"accent":"blue"}\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      final manifestPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/app'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      await pushChanges(const PushRequest(dryRun: false));

      final settingsArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'app',
        'settings.json',
      );
      final nestedArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'app',
        'nested',
        'theme.json',
      );
      expect(await File(settingsArtifact).readAsString(), '{"theme":"dark"}\n');
      expect(await File(nestedArtifact).readAsString(), '{"accent":"blue"}\n');

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/app'},
              'mode': {'default': 'ignore'},
            },
          ],
        }),
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 2);
      expectPathAbsent(settingsArtifact);
      expectPathAbsent(nestedArtifact);
    });

    test('does not delete Windows-ignored artifacts during push', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final zshrcFile = p.join(zshDirectory, '.zshrc');
      final secretsFile = p.join(zshDirectory, 'secrets.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(zshrcFile).writeAsString('source ~/.config/zsh/secrets.zsh\n');
      await File(secretsFile).writeAsString('export TOKEN=linux\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );
      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 7,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal', 'win': 'ignore'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/secrets.zsh'},
              'mode': {'default': 'secret', 'win': 'ignore'},
            },
          ],
        }),
      );

      mockCurrentPlatformKey(PlatformKey.linux);
      await pushChanges(const PushRequest(dryRun: false));

      final secretArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
        'secrets.zsh.dotweave.secret',
      );
      final plainArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
        '.zshrc',
      );
      expect(
        await File(plainArtifact).readAsString(),
        'source ~/.config/zsh/secrets.zsh\n',
      );
      expect(
        await File(secretArtifact).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );

      mockCurrentPlatformKey(PlatformKey.win);
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 0);
      expect(
        await File(plainArtifact).readAsString(),
        'source ~/.config/zsh/secrets.zsh\n',
      );
      expect(
        await File(secretArtifact).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );
    });

    test('pushes only the platform-specific child artifact when a directory '
        'parent contains the source file', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final platformFile = p.join(zshDirectory, 'platform.zsh');
      final otherFile = p.join(zshDirectory, 'other.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(platformFile).writeAsString('wsl platform\n');
      await File(otherFile).writeAsString('other\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      final manifestPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'profiles': <Object?>[],
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/platform.zsh'},
              'repoPath': {
                'default': '.config/zsh/platform.zsh',
                'wsl': '.config/zsh/platform.wsl.zsh',
              },
              'mode': {'default': 'ignore', 'wsl': 'normal'},
            },
          ],
        }),
      );

      final repositoryZshDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
      );
      final defaultArtifact = p.join(repositoryZshDirectory, 'platform.zsh');
      final wslArtifact = p.join(repositoryZshDirectory, 'platform.wsl.zsh');
      final otherArtifact = p.join(repositoryZshDirectory, 'other.zsh');

      await Directory(repositoryZshDirectory).create(recursive: true);
      await File(defaultArtifact).writeAsString('stale default artifact\n');

      mockCurrentPlatformKey(PlatformKey.wsl);
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.plainFileCount, 2);
      expect(result.deletedArtifactCount, 1);
      expect(await File(wslArtifact).readAsString(), 'wsl platform\n');
      expect(await File(otherArtifact).readAsString(), 'other\n');
      expectPathAbsent(defaultArtifact);
    });

    test('pushes only the platform-specific child artifact when no default '
        'artifact exists yet', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final platformFile = p.join(zshDirectory, 'platform.zsh');
      final otherFile = p.join(zshDirectory, 'other.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(platformFile).writeAsString('wsl platform\n');
      await File(otherFile).writeAsString('other\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/platform.zsh'},
              'repoPath': {
                'default': '.config/zsh/platform.zsh',
                'wsl': '.config/zsh/platform.wsl.zsh',
              },
              'mode': {'default': 'ignore', 'wsl': 'normal'},
            },
          ],
        }),
      );

      mockCurrentPlatformKey(PlatformKey.wsl);
      final result = await pushChanges(const PushRequest(dryRun: false));

      final repositoryZshDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
      );
      expect(result.plainFileCount, 2);
      expect(result.deletedArtifactCount, 0);
      expect(
        await File(
          p.join(repositoryZshDirectory, 'platform.wsl.zsh'),
        ).readAsString(),
        'wsl platform\n',
      );
      expect(
        await File(p.join(repositoryZshDirectory, 'other.zsh')).readAsString(),
        'other\n',
      );
      expectPathAbsent(p.join(repositoryZshDirectory, 'platform.zsh'));
    });

    test('pushes only the platform-specific secret child artifact when a '
        'directory parent contains the source file', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final platformFile = p.join(zshDirectory, 'platform.zsh');
      final otherFile = p.join(zshDirectory, 'other.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(platformFile).writeAsString('secret wsl platform\n');
      await File(otherFile).writeAsString('other\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/platform.zsh'},
              'repoPath': {
                'default': '.config/zsh/platform.zsh',
                'wsl': '.config/zsh/platform.wsl.zsh',
              },
              'mode': {'default': 'ignore', 'wsl': 'secret'},
            },
          ],
        }),
      );

      final repositoryZshDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
      );
      final defaultPlainArtifact = p.join(
        repositoryZshDirectory,
        'platform.zsh',
      );
      final defaultSecretArtifact = p.join(
        repositoryZshDirectory,
        'platform.zsh.dotweave.secret',
      );
      final wslSecretArtifact = p.join(
        repositoryZshDirectory,
        'platform.wsl.zsh.dotweave.secret',
      );

      await Directory(repositoryZshDirectory).create(recursive: true);
      await File(defaultPlainArtifact).writeAsString('stale plain\n');
      await File(defaultSecretArtifact).writeAsString('stale secret\n');

      mockCurrentPlatformKey(PlatformKey.wsl);
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.plainFileCount, 1);
      expect(result.encryptedFileCount, 1);
      expect(result.deletedArtifactCount, 2);
      expect(
        await File(wslSecretArtifact).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );
      expect(
        await File(p.join(repositoryZshDirectory, 'other.zsh')).readAsString(),
        'other\n',
      );
      expectPathAbsent(defaultPlainArtifact);
      expectPathAbsent(defaultSecretArtifact);
    });

    test('pushes only the platform-specific symlink child artifact when a '
        'directory parent contains the link', () async {
      if (Platform.isWindows) {
        return;
      }

      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final platformFile = p.join(zshDirectory, 'platform.zsh');
      final otherFile = p.join(zshDirectory, 'other.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await createSymlink('.platform-target', platformFile);
      await File(otherFile).writeAsString('other\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/platform.zsh'},
              'repoPath': {
                'default': '.config/zsh/platform.zsh',
                'wsl': '.config/zsh/platform.wsl.zsh',
              },
              'mode': {'default': 'ignore', 'wsl': 'normal'},
            },
          ],
        }),
      );

      final repositoryZshDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
      );
      final defaultArtifact = p.join(repositoryZshDirectory, 'platform.zsh');
      final wslArtifact = p.join(repositoryZshDirectory, 'platform.wsl.zsh');

      await Directory(repositoryZshDirectory).create(recursive: true);
      await File(defaultArtifact).writeAsString('stale default artifact\n');

      mockCurrentPlatformKey(PlatformKey.wsl);
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.plainFileCount, 1);
      expect(result.symlinkCount, 1);
      expect(result.deletedArtifactCount, 1);
      await expectSymlinkArtifact(wslArtifact, '.platform-target');
      expectPathAbsent(defaultArtifact);
    });

    test('reports platform-specific child artifact changes in status without '
        'adding the default-path artifact', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(
        p.join(zshDirectory, 'platform.zsh'),
      ).writeAsString('wsl platform\n');
      await File(p.join(zshDirectory, 'other.zsh')).writeAsString('other\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/platform.zsh'},
              'repoPath': {
                'default': '.config/zsh/platform.zsh',
                'wsl': '.config/zsh/platform.wsl.zsh',
              },
              'mode': {'default': 'ignore', 'wsl': 'normal'},
            },
          ],
        }),
      );

      final repositoryZshDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
      );
      await Directory(repositoryZshDirectory).create(recursive: true);
      await File(
        p.join(repositoryZshDirectory, 'platform.zsh'),
      ).writeAsString('stale\n');

      mockCurrentPlatformKey(PlatformKey.wsl);
      final status = await getStatus();

      expect(
        status.push.changes.added,
        contains('.config/zsh/platform.wsl.zsh'),
      );
      expect(status.push.changes.added, contains('.config/zsh/other.zsh'));
      expect(
        status.push.changes.added,
        isNot(contains('.config/zsh/platform.zsh')),
      );
      expect(
        status.push.changes.deleted,
        contains('default/.config/zsh/platform.zsh'),
      );
    });

    test('pull applies the platform-specific child artifact instead of the '
        'parent default-path artifact', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final platformFile = p.join(zshDirectory, 'platform.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(platformFile).writeAsString('local before\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/platform.zsh'},
              'repoPath': {
                'default': '.config/zsh/platform.zsh',
                'wsl': '.config/zsh/platform.wsl.zsh',
              },
              'mode': {'default': 'ignore', 'wsl': 'normal'},
            },
          ],
        }),
      );

      final repositoryZshDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'zsh',
      );
      await Directory(repositoryZshDirectory).create(recursive: true);
      await File(
        p.join(repositoryZshDirectory, 'platform.zsh'),
      ).writeAsString('default artifact\n');
      await File(
        p.join(repositoryZshDirectory, 'platform.wsl.zsh'),
      ).writeAsString('wsl artifact\n');
      await File(
        p.join(repositoryZshDirectory, 'other.zsh'),
      ).writeAsString('other\n');

      mockCurrentPlatformKey(PlatformKey.wsl);
      final result = await pullChanges(const PullRequest(dryRun: false));

      expect(result.plainFileCount, 2);
      expect(await File(platformFile).readAsString(), 'wsl artifact\n');
      expect(
        await File(p.join(zshDirectory, 'other.zsh')).readAsString(),
        'other\n',
      );
    });

    test('keeps a profiled platform-specific child out of the parent '
        'default-path artifact when pushing that profile', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
      final platformFile = p.join(zshDirectory, 'platform.zsh');
      final otherFile = p.join(zshDirectory, 'other.zsh');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(zshDirectory).create(recursive: true);
      await File(platformFile).writeAsString('work platform\n');
      await File(otherFile).writeAsString('other\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'profiles': ['work'],
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
              'mode': {'default': 'normal'},
              'profiles': ['work'],
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/zsh/platform.zsh'},
              'repoPath': {
                'default': '.config/zsh/platform.zsh',
                'wsl': '.config/zsh/platform.wsl.zsh',
              },
              'mode': {'default': 'ignore', 'wsl': 'normal'},
              'profiles': ['work'],
            },
          ],
        }),
      );

      final workZshDirectory = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'work',
        '.config',
        'zsh',
      );
      final defaultArtifact = p.join(workZshDirectory, 'platform.zsh');
      final wslArtifact = p.join(workZshDirectory, 'platform.wsl.zsh');

      await Directory(workZshDirectory).create(recursive: true);
      await File(
        defaultArtifact,
      ).writeAsString('stale work default artifact\n');

      mockCurrentPlatformKey(PlatformKey.wsl);
      final result = await pushChanges(
        const PushRequest(dryRun: false, profile: 'work'),
      );

      expect(result.plainFileCount, 2);
      expect(result.deletedArtifactCount, 1);
      expect(
        await File(p.join(workZshDirectory, 'other.zsh')).readAsString(),
        'other\n',
      );
      expect(await File(wslArtifact).readAsString(), 'work platform\n');
      expectPathAbsent(defaultArtifact);
    });

    test(
      'does not delete artifacts for platform-ignored entries with different '
      'repo paths',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final appDirectory = p.join(homeDirectory, '.config', 'platform-app');
        final appFile = p.join(appDirectory, 'settings.json');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(appDirectory).create(recursive: true);
        await File(appFile).writeAsString('{"theme":"dark"}\n');

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );

        final manifestPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'manifest.jsonc',
        );

        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 7,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'directory',
                'localPath': {
                  'default': '~/.config/platform-app',
                  'win': '~/AppData/Roaming/platform-app',
                },
                'repoPath': {
                  'default': '.config/platform-app',
                  'win': 'AppData/Roaming/platform-app',
                },
                'mode': {'default': 'normal', 'win': 'ignore'},
              },
            ],
          }),
        );

        mockCurrentPlatformKey(PlatformKey.linux);
        await pushChanges(const PushRequest(dryRun: false));

        final linuxArtifact = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'platform-app',
          'settings.json',
        );
        expect(await File(linuxArtifact).readAsString(), '{"theme":"dark"}\n');

        mockCurrentPlatformKey(PlatformKey.win);
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(result.deletedArtifactCount, 0);
        expect(await File(linuxArtifact).readAsString(), '{"theme":"dark"}\n');
      },
    );

    test('deletes current platform artifacts for entries changed to '
        'platform-specific ignore', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final linuxAppDirectory = p.join(homeDirectory, '.config', 'app');
      final winAppDirectory = p.join(
        homeDirectory,
        'AppData',
        'Roaming',
        'app',
      );
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(linuxAppDirectory).create(recursive: true);
      await Directory(winAppDirectory).create(recursive: true);
      await File(
        p.join(linuxAppDirectory, 'settings.json'),
      ).writeAsString('linux\n');
      await File(
        p.join(winAppDirectory, 'settings.json'),
      ).writeAsString('windows\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      final manifestPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );
      Future<void> writeManifest(Map<String, String> mode) async {
        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'directory',
                'localPath': {
                  'default': '~/.config/app',
                  'win': '~/AppData/Roaming/app',
                },
                'repoPath': {
                  'default': '.config/app',
                  'win': 'AppData/Roaming/app',
                },
                'mode': mode,
              },
            ],
          }),
        );
      }

      await writeManifest({'default': 'normal'});

      mockCurrentPlatformKey(PlatformKey.linux);
      await pushChanges(const PushRequest(dryRun: false));
      mockCurrentPlatformKey(PlatformKey.win);
      await pushChanges(const PushRequest(dryRun: false));

      final linuxArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'app',
        'settings.json',
      );
      final winArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'AppData',
        'Roaming',
        'app',
        'settings.json',
      );
      expect(await File(linuxArtifact).readAsString(), 'linux\n');
      expect(await File(winArtifact).readAsString(), 'windows\n');

      await writeManifest({'default': 'normal', 'win': 'ignore'});

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 1);
      expect(await File(linuxArtifact).readAsString(), 'linux\n');
      expectPathAbsent(winArtifact);
    });

    test('deletes ignored child artifacts while preserving normal directory '
        'siblings', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'app');
      final publicFile = p.join(appDirectory, 'public.json');
      final privateFile = p.join(appDirectory, 'private.json');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(appDirectory).create(recursive: true);
      await File(publicFile).writeAsString('{"public":true}\n');
      await File(privateFile).writeAsString('{"private":true}\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      final manifestPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );
      Future<void> writeManifest(String childMode) async {
        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/app'},
                'mode': {'default': 'normal'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/app/private.json'},
                'mode': {'default': childMode},
              },
            ],
          }),
        );
      }

      await writeManifest('normal');
      await pushChanges(const PushRequest(dryRun: false));

      final publicArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'app',
        'public.json',
      );
      final privateArtifact = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'app',
        'private.json',
      );
      expect(await File(publicArtifact).readAsString(), '{"public":true}\n');
      expect(await File(privateArtifact).readAsString(), '{"private":true}\n');

      await File(publicFile).writeAsString('{"public":"updated"}\n');
      await writeManifest('ignore');

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 1);
      expect(
        await File(publicArtifact).readAsString(),
        '{"public":"updated"}\n',
      );
      expectPathAbsent(privateArtifact);
    });
  });
}
