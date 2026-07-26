import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/status.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/sync_fixture.dart';

// Port of `sync.service.test.ts` (part B): the tests from "prunes orphaned
// non-default-profile artifacts after the last profile entry is removed"
// through "preserves inactive parent-owned empty child directories".
//
// Of the three parts this is the one with a single subject: what push and
// status do to repository artifacts that no manifest entry owns any more.
// Orphan pruning across profiles, secrets, and symlinks; replacing a stale
// directory root with a file or symlink; and the preservation rules that stop
// all of that from eating artifacts another profile or parent still owns.

/// Mirror of `(await lstat(path)).isDirectory()).toBe(true)`.
void _expectDirectory(String path) {
  expect(
    FileSystemEntity.typeSync(path, followLinks: false),
    FileSystemEntityType.directory,
  );
}

/// Mirror of `(await lstat(path)).isFile()).toBe(true)`.
void _expectFile(String path) {
  expect(
    FileSystemEntity.typeSync(path, followLinks: false),
    FileSystemEntityType.file,
  );
}

void main() {
  tearDown(cleanUpSyncFixture);

  group('sync service: orphan pruning and stale root replacement', () {
    test('prunes orphaned non-default-profile artifacts after the last '
        'profile entry is removed', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\n  name = Work\n');

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
          'profiles': ['work'],
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal'},
              'profiles': ['work'],
            },
          ],
        }),
      );

      await pushChanges(const PushRequest(dryRun: false, profile: 'work'));

      final artifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'work',
        '.gitconfig',
      );
      expect(
        await File(artifactPath).readAsString(),
        '[user]\n  name = Work\n',
      );

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'profiles': ['work'],
          'entries': <Object?>[],
        }),
      );

      final result = await pushChanges(
        const PushRequest(dryRun: false, profile: 'work'),
      );

      expect(result.deletedArtifactCount, 1);
      expectPathAbsent(artifactPath);
    });

    test('status reports the same non-default orphan deletion that push will '
        'apply', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\n  name = Work\n');

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
          'profiles': ['work'],
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal'},
              'profiles': ['work'],
            },
          ],
        }),
      );

      await pushChanges(const PushRequest(dryRun: false, profile: 'work'));

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'profiles': ['work'],
          'entries': <Object?>[],
        }),
      );

      final status = await getStatus(profile: 'work');

      expect(status.push.deletedArtifactCount, 1);
      expect(status.push.preview, contains('work/.gitconfig'));
    });

    test('default-profile status preserves work-profile artifacts while the '
        'work entry exists', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\n  name = Work\n');

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
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal'},
              'profiles': ['work'],
            },
          ],
        }),
      );

      await pushChanges(const PushRequest(dryRun: false, profile: 'work'));

      final status = await getStatus();

      expect(status.push.deletedArtifactCount, 0);
      expect(status.push.preview, isNot(contains('work/.gitconfig')));
    });

    test('prunes orphaned secret artifacts after manifest entries are '
        'removed', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final secretFile = p.join(homeDirectory, '.ssh', 'id_rsa');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(p.join(homeDirectory, '.ssh')).create(recursive: true);
      await File(secretFile).writeAsString('fake-private-key\n');

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
              'localPath': {'default': '~/.ssh/id_rsa'},
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
        '.ssh',
        'id_rsa.dotweave.secret',
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
          'entries': <Object?>[],
        }),
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 1);
      expectPathAbsent(artifactPath);
    });

    test('prunes orphaned symlink artifacts after manifest entries are '
        'removed', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final zshrc = p.join(homeDirectory, '.zshrc');
      final zshenv = p.join(homeDirectory, '.zshenv');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(zshrc).writeAsString(
        r'export PATH=~/.local/bin:$PATH'
        '\n',
      );
      await createSymlink('.zshrc', zshenv);

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
              'localPath': {'default': '~/.zshenv'},
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
        '.zshenv',
      );
      await expectSymlinkArtifact(artifactPath, '.zshrc');

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': <Object?>[],
        }),
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 1);
      expectPathAbsent(symlinkArtifactPath(artifactPath));
    });

    test('preserves directory-owned nested artifacts after a child entry is '
        'removed', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'app');
      final settingsFile = p.join(appDirectory, 'settings.json');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(appDirectory).create(recursive: true);
      await File(settingsFile).writeAsString('{"theme":"dark"}\n');

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
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/app/settings.json'},
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
        '.config',
        'app',
        'settings.json',
      );
      expect(await File(artifactPath).readAsString(), '{"theme":"dark"}\n');

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

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 0);
      expect(await File(artifactPath).readAsString(), '{"theme":"dark"}\n');
    });

    test('does not let a file entry preserve nested artifacts', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

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
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'repoPath': {'default': '.config/app'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final nestedArtifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'app',
        'settings.json',
      );
      await Directory(p.dirname(nestedArtifactPath)).create(recursive: true);
      await File(nestedArtifactPath).writeAsString('{"stale":true}\n');

      final result = await pushChanges(const PushRequest(dryRun: true));

      expect(result.deletedArtifactCount, 1);
    });

    test('prunes stale empty child directories under an active parent '
        'directory entry', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(
        homeDirectory,
        '.config',
        'active-empty-child',
      );
      final staleChildDirectory = p.join(appDirectory, 'old-empty');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(staleChildDirectory).create(recursive: true);

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
              'localPath': {'default': '~/.config/active-empty-child'},
              'repoPath': {'default': '.config/active-empty-child'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/active-empty-child/old-empty',
              },
              'repoPath': {'default': '.config/active-empty-child/old-empty'},
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
        '.config',
        'active-empty-child',
      );
      final childArtifactPath = p.join(artifactPath, 'old-empty');
      _expectDirectory(childArtifactPath);

      await Directory(staleChildDirectory).delete(recursive: true);
      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/active-empty-child'},
              'repoPath': {'default': '.config/active-empty-child'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final status = await getStatus();
      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(status.push.deletedArtifactCount, 1);
      expect(status.push.changes.added, <String>[]);
      expect(status.push.changes.modified, <String>[]);
      expect(status.push.changes.deleted, [
        'default/.config/active-empty-child/old-empty/',
      ]);
      expect(dryRunResult.deletedArtifactCount, 1);
      expect(result.deletedArtifactCount, 1);
      expectPathAbsent(childArtifactPath);
      _expectDirectory(artifactPath);
    });

    test('preserves child artifacts through a remaining parent directory '
        'entry', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'overlap-app');
      final childFile = p.join(appDirectory, 'child.json');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(appDirectory).create(recursive: true);
      await File(childFile).writeAsString('{"child":true}\n');

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
              'localPath': {'default': '~/.config/overlap-app'},
              'repoPath': {'default': 'apps/overlap'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/overlap-app/child.json'},
              'repoPath': {'default': 'apps/overlap/child.json'},
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
        'apps',
        'overlap',
        'child.json',
      );
      expect(await File(artifactPath).readAsString(), '{"child":true}\n');

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/overlap-app'},
              'repoPath': {'default': 'apps/overlap'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 0);
      expect(await File(artifactPath).readAsString(), '{"child":true}\n');
    });

    test('replaces a stale repository directory root with a file artifact '
        'during push', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'transition-app');
      final childFile = p.join(appDirectory, 'settings.json');
      final replacementFile = p.join(homeDirectory, '.transition-app-file');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(appDirectory).create(recursive: true);
      await File(childFile).writeAsString('{"stale":true}\n');
      await File(replacementFile).writeAsString('replacement file\n');

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
              'localPath': {'default': '~/.config/transition-app'},
              'repoPath': {'default': '.config/transition-app'},
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
        '.config',
        'transition-app',
      );
      expect(
        await File(p.join(artifactPath, 'settings.json')).readAsString(),
        '{"stale":true}\n',
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
              'localPath': {'default': '~/.transition-app-file'},
              'repoPath': {'default': '.config/transition-app'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 1);
      _expectFile(artifactPath);
      expect(await File(artifactPath).readAsString(), 'replacement file\n');
    });

    test('reports an empty repository directory root replacement '
        'consistently', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final emptyDirectory = p.join(
        homeDirectory,
        '.config',
        'empty-transition',
      );
      final replacementFile = p.join(homeDirectory, '.empty-transition-file');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(emptyDirectory).create(recursive: true);
      await File(replacementFile).writeAsString('replacement file\n');

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
              'localPath': {'default': '~/.config/empty-transition'},
              'repoPath': {'default': '.config/empty-transition'},
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
        '.config',
        'empty-transition',
      );
      _expectDirectory(artifactPath);

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.empty-transition-file'},
              'repoPath': {'default': '.config/empty-transition'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final status = await getStatus();
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(dryRunResult.deletedArtifactCount, 1);
      expect(status.push.deletedArtifactCount, 1);
      expect(status.push.changes.added, ['.config/empty-transition']);
      expect(status.push.changes.modified, <String>[]);
      expect(status.push.changes.deleted, [
        'default/.config/empty-transition/',
      ]);
      expect(result.deletedArtifactCount, 1);
      _expectFile(artifactPath);
      expect(await File(artifactPath).readAsString(), 'replacement file\n');
    });

    test('replaces a stale repository directory root with a symlink artifact '
        'during push', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'transition-link');
      final childFile = p.join(appDirectory, 'settings.json');
      final linkTarget = p.join(homeDirectory, '.transition-link-target');
      final replacementLink = p.join(homeDirectory, '.transition-link');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(appDirectory).create(recursive: true);
      await File(childFile).writeAsString('{"stale":true}\n');
      await File(linkTarget).writeAsString('replacement link target\n');
      await createSymlink('.transition-link-target', replacementLink);

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
              'localPath': {'default': '~/.config/transition-link'},
              'repoPath': {'default': '.config/transition-link'},
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
        '.config',
        'transition-link',
      );
      expect(
        await File(p.join(artifactPath, 'settings.json')).readAsString(),
        '{"stale":true}\n',
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
              'localPath': {'default': '~/.transition-link'},
              'repoPath': {'default': '.config/transition-link'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 1);
      await expectSymlinkArtifact(artifactPath, '.transition-link-target');
    });

    test('replaces a repository directory root containing only stale empty '
        'descendants with a file artifact', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'empty-child-file');
      final childDirectory = p.join(appDirectory, 'child');
      final replacementFile = p.join(
        homeDirectory,
        '.empty-child-file-replacement',
      );
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(childDirectory).create(recursive: true);
      await File(replacementFile).writeAsString('replacement file\n');

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
              'localPath': {'default': '~/.config/empty-child-file'},
              'repoPath': {'default': '.config/empty-child-file'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/empty-child-file/child'},
              'repoPath': {'default': '.config/empty-child-file/child'},
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
        '.config',
        'empty-child-file',
      );
      final childArtifactPath = p.join(artifactPath, 'child');
      _expectDirectory(childArtifactPath);

      await Directory(appDirectory).delete(recursive: true);
      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.empty-child-file-replacement'},
              'repoPath': {'default': '.config/empty-child-file'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final status = await getStatus();
      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(status.push.deletedArtifactCount, 1);
      expect(status.push.changes.added, ['.config/empty-child-file']);
      expect(status.push.changes.modified, <String>[]);
      expect(status.push.changes.deleted, [
        'default/.config/empty-child-file/child/',
      ]);
      expect(dryRunResult.deletedArtifactCount, 1);
      expect(result.deletedArtifactCount, 1);
      _expectFile(artifactPath);
      expect(await File(artifactPath).readAsString(), 'replacement file\n');
    });

    test('replaces a repository directory root containing only stale empty '
        'descendants with a symlink artifact', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(homeDirectory, '.config', 'empty-child-link');
      final childDirectory = p.join(appDirectory, 'child');
      final linkTarget = p.join(homeDirectory, '.empty-child-link-target');
      final replacementLink = p.join(
        homeDirectory,
        '.empty-child-link-replacement',
      );
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(childDirectory).create(recursive: true);
      await File(linkTarget).writeAsString('replacement target\n');
      await createSymlink('.empty-child-link-target', replacementLink);

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
              'localPath': {'default': '~/.config/empty-child-link'},
              'repoPath': {'default': '.config/empty-child-link'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/empty-child-link/child'},
              'repoPath': {'default': '.config/empty-child-link/child'},
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
        '.config',
        'empty-child-link',
      );
      final childArtifactPath = p.join(artifactPath, 'child');
      _expectDirectory(childArtifactPath);

      await Directory(appDirectory).delete(recursive: true);
      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.empty-child-link-replacement'},
              'repoPath': {'default': '.config/empty-child-link'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final status = await getStatus();
      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(status.push.deletedArtifactCount, 1);
      expect(status.push.changes.added, ['.config/empty-child-link']);
      expect(status.push.changes.modified, <String>[]);
      expect(status.push.changes.deleted, [
        'default/.config/empty-child-link/child/',
      ]);
      expect(dryRunResult.deletedArtifactCount, 1);
      expect(result.deletedArtifactCount, 1);
      await expectSymlinkArtifact(artifactPath, '.empty-child-link-target');
    });

    test('replaces an existing symlink artifact with a file artifact without '
        'following the symlink target', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final symlinkSource = p.join(homeDirectory, '.link-replacement-source');
      final symlinkTarget = p.join(homeDirectory, '.link-replacement-target');
      final replacementFile = p.join(homeDirectory, '.link-replacement-file');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(symlinkTarget).writeAsString('local target content\n');
      await File(replacementFile).writeAsString('replacement file\n');
      await createSymlink(symlinkTarget, symlinkSource);

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
              'localPath': {'default': '~/.link-replacement-source'},
              'repoPath': {'default': '.config/link-replacement'},
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
        '.config',
        'link-replacement',
      );
      await expectSymlinkArtifact(artifactPath, symlinkTarget);

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.link-replacement-file'},
              'repoPath': {'default': '.config/link-replacement'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final status = await getStatus();
      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final result = await pushChanges(const PushRequest(dryRun: false));

      // The symlink is stored as a separate `.dotweave.symlink` metadata file,
      // so switching the entry to a regular file adds the plain artifact and
      // prunes the stale symlink metadata file (rather than an in-place
      // modify).
      expect(status.push.changes.added, ['.config/link-replacement']);
      expect(status.push.changes.modified, <String>[]);
      expect(status.push.changes.deleted, [
        symlinkArtifactPath('default/.config/link-replacement'),
      ]);
      expect(dryRunResult.deletedArtifactCount, 1);
      expect(result.deletedArtifactCount, 1);
      _expectFile(artifactPath);
      expect(await File(artifactPath).readAsString(), 'replacement file\n');
      expect(
        await File(symlinkTarget).readAsString(),
        'local target content\n',
      );
      expectPathAbsent(symlinkArtifactPath(artifactPath));
    });

    test('preserves still-owned inactive nested directory artifacts from file '
        'replacement', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(
        homeDirectory,
        '.config',
        'inactive-child-file',
      );
      final childDirectory = p.join(appDirectory, 'child');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(childDirectory).create(recursive: true);

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
              'localPath': {'default': '~/.config/inactive-child-file'},
              'repoPath': {'default': '.config/inactive-child-file'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/inactive-child-file/child',
                'win': '~/AppData/Roaming/inactive-child-file/child',
              },
              'repoPath': {'default': '.config/inactive-child-file/child'},
              'mode': {'default': 'normal', 'win': 'ignore'},
            },
          ],
        }),
      );

      mockCurrentPlatformKey(PlatformKey.linux);
      await pushChanges(const PushRequest(dryRun: false));

      final artifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'inactive-child-file',
      );
      final childArtifactPath = p.join(artifactPath, 'child');
      _expectDirectory(childArtifactPath);

      await Directory(appDirectory).delete(recursive: true);
      await File(appDirectory).writeAsString('replacement file\n');
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
                'default': '~/.config/inactive-child-file/child',
                'win': '~/AppData/Roaming/inactive-child-file/child',
              },
              'repoPath': {'default': '.config/inactive-child-file/child'},
              'mode': {'default': 'normal', 'win': 'ignore'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/inactive-child-file'},
              'repoPath': {'default': '.config/inactive-child-file'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      mockCurrentPlatformKey(PlatformKey.win);
      final status = await getStatus();
      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(status.push.changes.added, <String>[]);
      expect(status.push.changes.modified, <String>[]);
      expect(status.push.changes.deleted, <String>[]);
      expect(dryRunResult.deletedArtifactCount, 0);
      expect(result.deletedArtifactCount, 0);
      _expectDirectory(artifactPath);
      _expectDirectory(childArtifactPath);
      await expectLater(
        File(artifactPath).readAsString(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('preserves still-owned inactive nested directory artifacts from '
        'symlink replacement', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final appDirectory = p.join(
        homeDirectory,
        '.config',
        'inactive-child-link',
      );
      final childDirectory = p.join(appDirectory, 'child');
      final linkTarget = p.join(homeDirectory, '.inactive-child-link-target');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(childDirectory).create(recursive: true);
      await File(linkTarget).writeAsString('replacement target\n');

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
              'localPath': {'default': '~/.config/inactive-child-link'},
              'repoPath': {'default': '.config/inactive-child-link'},
              'mode': {'default': 'normal'},
            },
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/inactive-child-link/child',
                'win': '~/AppData/Roaming/inactive-child-link/child',
              },
              'repoPath': {'default': '.config/inactive-child-link/child'},
              'mode': {'default': 'normal', 'win': 'ignore'},
            },
          ],
        }),
      );

      mockCurrentPlatformKey(PlatformKey.linux);
      await pushChanges(const PushRequest(dryRun: false));

      final artifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'inactive-child-link',
      );
      final childArtifactPath = p.join(artifactPath, 'child');
      _expectDirectory(childArtifactPath);

      await Directory(appDirectory).delete(recursive: true);
      await createSymlink('.inactive-child-link-target', appDirectory);
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
                'default': '~/.config/inactive-child-link/child',
                'win': '~/AppData/Roaming/inactive-child-link/child',
              },
              'repoPath': {'default': '.config/inactive-child-link/child'},
              'mode': {'default': 'normal', 'win': 'ignore'},
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.config/inactive-child-link'},
              'repoPath': {'default': '.config/inactive-child-link'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      mockCurrentPlatformKey(PlatformKey.win);
      final status = await getStatus();
      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final result = await pushChanges(const PushRequest(dryRun: false));

      // The symlink is stored as a separate `.dotweave.symlink` metadata file,
      // so it is simply added alongside the still-owned nested directory
      // artifacts, which are preserved untouched (no directory-root
      // replacement occurs).
      expect(status.push.changes.added, ['.config/inactive-child-link']);
      expect(status.push.changes.modified, <String>[]);
      expect(status.push.changes.deleted, <String>[]);
      expect(dryRunResult.deletedArtifactCount, 0);
      expect(result.deletedArtifactCount, 0);
      _expectDirectory(artifactPath);
      _expectDirectory(childArtifactPath);
      await expectLater(
        Link(artifactPath).target(),
        throwsA(isA<FileSystemException>()),
      );
      await expectSymlinkArtifact(artifactPath, '.inactive-child-link-target');
    });

    test('preserves inactive profile-owned nested artifacts during default '
        'parent replacements', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final parentDirectory = p.join(homeDirectory, '.config', 'profile-ns');
      final childDirectory = p.join(
        parentDirectory,
        'profiles',
        'work',
        'state',
      );
      final childFile = p.join(childDirectory, 'settings.json');
      final linkTarget = p.join(homeDirectory, '.profile-ns-link-target');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(childDirectory).create(recursive: true);
      await File(
        p.join(parentDirectory, 'default.txt'),
      ).writeAsString('default dir\n');
      await File(childFile).writeAsString('{"profile":"work"}\n');
      await File(linkTarget).writeAsString('replacement link target\n');

      await initializeSyncDirectory(
        InitRequest(
          identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
          recipients: [ageKeys.recipient],
        ),
      );

      final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
      final manifestPath = p.join(syncDirectory, 'manifest.jsonc');
      Future<void> writeProfileManifest(
        Map<String, Object?> defaultEntry,
      ) async {
        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'profiles': ['work'],
            'entries': [
              defaultEntry,
              {
                'kind': 'directory',
                'localPath': {
                  'default': '~/.config/profile-ns/profiles/work/state',
                },
                'repoPath': {'default': 'apps/profile-ns/profiles/work/state'},
                'mode': {'default': 'normal'},
                'profiles': ['work'],
              },
              {
                'kind': 'file',
                'localPath': {
                  'default':
                      '~/.config/profile-ns/profiles/work/state/settings.json',
                },
                'repoPath': {
                  'default':
                      'apps/profile-ns/profiles/work/state/settings.json',
                },
                'mode': {'default': 'normal'},
                'profiles': ['work'],
              },
            ],
          }),
        );
      }

      await writeProfileManifest({
        'kind': 'directory',
        'localPath': {'default': '~/.config/profile-ns'},
        'repoPath': {'default': 'apps/profile-ns'},
        'mode': {'default': 'normal'},
        'profiles': ['default'],
      });

      await pushChanges(const PushRequest(dryRun: false));
      await pushChanges(const PushRequest(dryRun: false, profile: 'work'));

      final defaultArtifactPath = p.join(
        syncDirectory,
        'profiles',
        'default',
        'apps',
        'profile-ns',
      );
      final workChildArtifactPath = p.join(
        syncDirectory,
        'profiles',
        'work',
        'apps',
        'profile-ns',
        'profiles',
        'work',
        'state',
      );
      final workFileArtifactPath = p.join(
        workChildArtifactPath,
        'settings.json',
      );
      expect(
        await File(workFileArtifactPath).readAsString(),
        '{"profile":"work"}\n',
      );

      await Directory(parentDirectory).delete(recursive: true);
      await File(parentDirectory).writeAsString('replacement file\n');
      await writeProfileManifest({
        'kind': 'file',
        'localPath': {'default': '~/.config/profile-ns'},
        'repoPath': {'default': 'apps/profile-ns'},
        'mode': {'default': 'normal'},
        'profiles': ['default'],
      });

      final fileStatus = await getStatus();
      final fileDryRunResult = await pushChanges(
        const PushRequest(dryRun: true),
      );
      final fileResult = await pushChanges(const PushRequest(dryRun: false));

      expect(fileStatus.push.deletedArtifactCount, 2);
      expect(fileStatus.push.changes.added, ['apps/profile-ns']);
      expect(fileStatus.push.changes.modified, <String>[]);
      expect(fileStatus.push.changes.deleted, [
        'default/apps/profile-ns/default.txt',
        'default/apps/profile-ns/profiles/work/state/settings.json',
      ]);
      expect(fileDryRunResult.deletedArtifactCount, 2);
      expect(fileResult.deletedArtifactCount, 2);
      _expectFile(defaultArtifactPath);
      expect(
        await File(defaultArtifactPath).readAsString(),
        'replacement file\n',
      );
      _expectDirectory(workChildArtifactPath);
      expect(
        await File(workFileArtifactPath).readAsString(),
        '{"profile":"work"}\n',
      );

      await File(parentDirectory).delete();
      await Directory(childDirectory).create(recursive: true);
      await File(
        childFile,
      ).writeAsString('{"profile":"work","updated":true}\n');

      final explicitWorkResult = await pushChanges(
        const PushRequest(dryRun: false, profile: 'work'),
      );

      expect(explicitWorkResult.deletedArtifactCount, 0);
      expect(
        await File(workFileArtifactPath).readAsString(),
        '{"profile":"work","updated":true}\n',
      );

      await Directory(parentDirectory).delete(recursive: true);
      await createSymlink('.profile-ns-link-target', parentDirectory);

      final linkStatus = await getStatus();
      final linkDryRunResult = await pushChanges(
        const PushRequest(dryRun: true),
      );
      final linkResult = await pushChanges(const PushRequest(dryRun: false));

      // File -> symlink transition: the symlink metadata file is added and the
      // stale plain-file artifact is pruned (the work-owned nested artifacts
      // under the work profile stay untouched).
      expect(linkStatus.push.deletedArtifactCount, 1);
      expect(linkStatus.push.changes.added, ['apps/profile-ns']);
      expect(linkStatus.push.changes.modified, <String>[]);
      expect(linkStatus.push.changes.deleted, ['default/apps/profile-ns']);
      expect(linkDryRunResult.deletedArtifactCount, 1);
      expect(linkResult.deletedArtifactCount, 1);
      await expectSymlinkArtifact(
        defaultArtifactPath,
        '.profile-ns-link-target',
      );
      expect(
        await File(workFileArtifactPath).readAsString(),
        '{"profile":"work","updated":true}\n',
      );

      await Link(parentDirectory).delete();
      await Directory(childDirectory).create(recursive: true);
      await File(childFile).writeAsString('{"profile":"work","active":true}\n');
      await setActiveProfile('work');

      final activeWorkResult = await pushChanges(
        const PushRequest(dryRun: false),
      );

      expect(activeWorkResult.deletedArtifactCount, 0);
      expect(
        await File(workFileArtifactPath).readAsString(),
        '{"profile":"work","active":true}\n',
      );
    });

    test('reports and prunes stale empty directory roots now configured as '
        'missing file sources', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final emptyDirectory = p.join(
        homeDirectory,
        '.config',
        'missing-file-root',
      );
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(emptyDirectory).create(recursive: true);

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
              'localPath': {'default': '~/.config/missing-file-root'},
              'repoPath': {'default': '.config/missing-file-root'},
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
        '.config',
        'missing-file-root',
      );
      _expectDirectory(artifactPath);

      await Directory(emptyDirectory).delete(recursive: true);
      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.missing-file-root'},
              'repoPath': {'default': '.config/missing-file-root'},
              'mode': {'default': 'normal'},
            },
          ],
        }),
      );

      final status = await getStatus();
      final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(status.push.changes.deleted, [
        'default/.config/missing-file-root/',
      ]);
      expect(dryRunResult.deletedArtifactCount, 1);
      expect(result.deletedArtifactCount, 1);
      expectPathAbsent(artifactPath);
    });

    test('preserves inactive profile artifacts when pushing the default '
        'profile', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final gitconfig = p.join(homeDirectory, '.gitconfig');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(homeDirectory).create(recursive: true);
      await File(gitconfig).writeAsString('[user]\n  name = Work\n');

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
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'mode': {'default': 'normal'},
              'profiles': ['work'],
            },
          ],
        }),
      );

      await pushChanges(const PushRequest(dryRun: false, profile: 'work'));

      final artifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'work',
        '.gitconfig',
      );
      expect(
        await File(artifactPath).readAsString(),
        '[user]\n  name = Work\n',
      );

      final result = await pushChanges(const PushRequest(dryRun: false));

      expect(result.deletedArtifactCount, 0);
      expect(
        await File(artifactPath).readAsString(),
        '[user]\n  name = Work\n',
      );
    });

    test('preserves still-owned inactive empty directory roots', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final emptyDirectory = p.join(homeDirectory, '.config', 'inactive-empty');
      final workFile = p.join(homeDirectory, '.work-profile-file');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(emptyDirectory).create(recursive: true);
      await File(workFile).writeAsString('work profile\n');

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
          'profiles': ['work'],
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/inactive-empty'},
              'repoPath': {'default': '.config/inactive-empty'},
              'mode': {'default': 'normal'},
              'profiles': ['default'],
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
        'inactive-empty',
      );
      _expectDirectory(artifactPath);

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'profiles': ['work'],
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/inactive-empty'},
              'repoPath': {'default': '.config/inactive-empty'},
              'mode': {'default': 'normal'},
              'profiles': ['default'],
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.work-profile-file'},
              'repoPath': {'default': '.work-profile-file'},
              'mode': {'default': 'normal'},
              'profiles': ['work'],
            },
          ],
        }),
      );

      final dryRunResult = await pushChanges(
        const PushRequest(dryRun: true, profile: 'work'),
      );
      final result = await pushChanges(
        const PushRequest(dryRun: false, profile: 'work'),
      );

      expect(dryRunResult.deletedArtifactCount, 0);
      expect(result.deletedArtifactCount, 0);
      _expectDirectory(artifactPath);
    });

    test('preserves inactive parent-owned empty child directories', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final parentDirectory = p.join(
        homeDirectory,
        '.config',
        'inactive-parent-empty-child',
      );
      final childDirectory = p.join(parentDirectory, 'child');
      final workFile = p.join(homeDirectory, '.inactive-parent-work-file');
      final ageKeys = await createAgeKeyPair();
      setEnvironment(homeDirectory, xdgConfigHome);

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(childDirectory).create(recursive: true);
      await File(workFile).writeAsString('work profile\n');

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
          'profiles': ['work'],
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/inactive-parent-empty-child'},
              'repoPath': {'default': '.config/inactive-parent-empty-child'},
              'mode': {'default': 'normal'},
              'profiles': ['default'],
            },
            {
              'kind': 'directory',
              'localPath': {
                'default': '~/.config/inactive-parent-empty-child/child',
              },
              'repoPath': {
                'default': '.config/inactive-parent-empty-child/child',
              },
              'mode': {'default': 'normal'},
              'profiles': ['default'],
            },
          ],
        }),
      );

      await pushChanges(const PushRequest(dryRun: false));

      final childArtifactPath = p.join(
        xdgConfigHome,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'inactive-parent-empty-child',
        'child',
      );
      _expectDirectory(childArtifactPath);

      await File(manifestPath).writeAsString(
        jsonStringify({
          'version': 8,
          'age': {
            'recipients': [ageKeys.recipient],
          },
          'profiles': ['work'],
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/inactive-parent-empty-child'},
              'repoPath': {'default': '.config/inactive-parent-empty-child'},
              'mode': {'default': 'normal'},
              'profiles': ['default'],
            },
            {
              'kind': 'file',
              'localPath': {'default': '~/.inactive-parent-work-file'},
              'repoPath': {'default': '.inactive-parent-work-file'},
              'mode': {'default': 'normal'},
              'profiles': ['work'],
            },
          ],
        }),
      );

      final status = await getStatus(profile: 'work');
      final dryRunResult = await pushChanges(
        const PushRequest(dryRun: true, profile: 'work'),
      );
      final result = await pushChanges(
        const PushRequest(dryRun: false, profile: 'work'),
      );

      expect(status.push.deletedArtifactCount, 0);
      expect(dryRunResult.deletedArtifactCount, 0);
      expect(result.deletedArtifactCount, 0);
      _expectDirectory(childArtifactPath);
    });
  });
}
