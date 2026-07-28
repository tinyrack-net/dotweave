import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/status.dart';
import 'package:dotweave/src/services/track.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/posix_chmod.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/sync_fixture.dart';

// Port of `sync.service.test.ts` (part C): the tests from "reports and prunes
// orphaned empty directory artifact roots after entry removal" through
// "updates repository artifacts when only the executable bit changes".
//
// The A/B/C split follows the order of the (now-deleted) TS source, and this
// part is the most mixed of the three. Four unrelated subjects, in order:
//
// - empty-directory-root pruning and profile-namespace pruning (:49-:1021)
// - file and directory permissions on pull (:1022-:1416)
// - profile assignment (:1417-:1497)
// - pull reconciliation and deletion (:1498-:1889)
// - push skipping unchanged artifacts (:1890-end)

/// Mirror of the TS `(await lstat(path)).ino` identity comparisons. Dart's
/// `FileStat` does not expose the inode, so the node identity is read through
/// `fsutil file queryFileID` on Windows (the NTFS file ID Node reports as
/// `ino`) and `stat` on POSIX.
Future<String> _readFileIdentity(String path) async {
  final ProcessResult result;

  if (Platform.isWindows) {
    result = await Process.run('fsutil', ['file', 'queryFileID', path]);
  } else if (Platform.isMacOS) {
    result = await Process.run('stat', ['-f', '%i', path]);
  } else {
    result = await Process.run('stat', ['-c', '%i', path]);
  }

  if (result.exitCode != 0) {
    throw Exception(
      'failed to read the file identity of $path: ${result.stderr}',
    );
  }

  return (result.stdout as String).trim();
}

void main() {
  tearDown(cleanUpSyncFixture);

  group(
    'sync service: profile namespaces, permissions, and pull reconciliation',
    () {
      test('reports and prunes orphaned empty directory artifact roots after '
          'entry removal', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final emptyDirectory = p.join(homeDirectory, '.config', 'orphan-empty');
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
                'localPath': {'default': '~/.config/orphan-empty'},
                'repoPath': {'default': '.config/orphan-empty'},
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
          'orphan-empty',
        );
        expect(
          FileSystemEntity.typeSync(artifactPath, followLinks: false),
          FileSystemEntityType.directory,
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

        final status = await getStatus();
        final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(status.push.changes.deleted, ['default/.config/orphan-empty/']);
        expect(dryRunResult.deletedArtifactCount, 1);
        expect(result.deletedArtifactCount, 1);
        expectPathAbsent(artifactPath);
      });

      test('preserves platform-variant-owned inactive empty directory roots '
          'during replacement push', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final replacementFile = p.join(
          homeDirectory,
          '.config',
          'variant-empty',
        );
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(
          p.join(homeDirectory, '.config'),
        ).create(recursive: true);

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
                'localPath': {
                  'default': '~/.config/variant-empty',
                  'win': '~/AppData/Roaming/variant-empty',
                },
                'repoPath': {
                  'default': '.config/variant-empty',
                  'win': 'AppData/Roaming/variant-empty',
                },
                'mode': {'default': 'normal', 'win': 'ignore'},
              },
            ],
          }),
        );

        mockCurrentPlatformKey(PlatformKey.linux);
        await Directory(replacementFile).create(recursive: true);
        await pushChanges(const PushRequest(dryRun: false));

        final artifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'variant-empty',
        );
        expect(
          FileSystemEntity.typeSync(artifactPath, followLinks: false),
          FileSystemEntityType.directory,
        );

        await Directory(replacementFile).delete(recursive: true);
        await File(replacementFile).writeAsString('replacement\n');
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
                  'default': '~/.config/variant-empty',
                  'win': '~/AppData/Roaming/variant-empty',
                },
                'repoPath': {
                  'default': '.config/variant-empty',
                  'win': 'AppData/Roaming/variant-empty',
                },
                'mode': {'default': 'normal', 'win': 'ignore'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/variant-empty'},
                'repoPath': {'default': '.config/variant-empty'},
                'mode': {'default': 'normal'},
              },
            ],
          }),
        );

        mockCurrentPlatformKey(PlatformKey.win);
        final status = await getStatus();
        final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(status.push.preview, isNot(contains('.config/variant-empty')));
        expect(status.push.changes.added, <String>[]);
        expect(status.push.changes.modified, <String>[]);
        expect(status.push.changes.deleted, <String>[]);
        expect(dryRunResult.deletedArtifactCount, 0);
        expect(result.deletedArtifactCount, 0);
        expect(
          FileSystemEntity.typeSync(artifactPath, followLinks: false),
          FileSystemEntityType.directory,
        );
        await expectLater(
          File(artifactPath).readAsString(),
          throwsA(isA<FileSystemException>()),
        );
      });

      test('preserves platform-variant-owned inactive empty directory roots '
          'from symlink replacement artifacts', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final replacementPath = p.join(
          homeDirectory,
          '.config',
          'variant-link',
        );
        final linkTarget = p.join(homeDirectory, 'target.txt');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(
          p.join(homeDirectory, '.config'),
        ).create(recursive: true);
        await File(linkTarget).writeAsString('target\n');

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
                'localPath': {
                  'default': '~/.config/variant-link',
                  'win': '~/AppData/Roaming/variant-link',
                },
                'repoPath': {
                  'default': '.config/variant-link',
                  'win': 'AppData/Roaming/variant-link',
                },
                'mode': {'default': 'normal', 'win': 'ignore'},
              },
            ],
          }),
        );

        mockCurrentPlatformKey(PlatformKey.linux);
        await Directory(replacementPath).create(recursive: true);
        await File(
          p.join(replacementPath, 'owned.txt'),
        ).writeAsString('owned\n');
        await pushChanges(const PushRequest(dryRun: false));

        final artifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'variant-link',
        );
        final ownedArtifactPath = p.join(artifactPath, 'owned.txt');
        expect(
          FileSystemEntity.typeSync(artifactPath, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(await File(ownedArtifactPath).readAsString(), 'owned\n');

        await Directory(replacementPath).delete(recursive: true);
        await createSymlink(linkTarget, replacementPath);
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
                  'default': '~/.config/variant-link',
                  'win': '~/AppData/Roaming/variant-link',
                },
                'repoPath': {
                  'default': '.config/variant-link',
                  'win': 'AppData/Roaming/variant-link',
                },
                'mode': {'default': 'normal', 'win': 'ignore'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.config/variant-link'},
                'repoPath': {'default': '.config/variant-link'},
                'mode': {'default': 'normal'},
              },
            ],
          }),
        );

        mockCurrentPlatformKey(PlatformKey.win);
        final status = await getStatus();
        final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
        final result = await pushChanges(const PushRequest(dryRun: false));

        // The symlink is added as a separate `.dotweave.symlink` metadata file;
        // the platform-variant-owned inactive directory root is preserved
        // untouched.
        expect(status.push.changes.added, ['.config/variant-link']);
        expect(status.push.changes.modified, <String>[]);
        expect(status.push.changes.deleted, <String>[]);
        expect(dryRunResult.deletedArtifactCount, 0);
        expect(result.deletedArtifactCount, 0);
        expect(
          FileSystemEntity.typeSync(artifactPath, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(await File(ownedArtifactPath).readAsString(), 'owned\n');
        await expectLater(
          Link(artifactPath).target(),
          throwsA(isA<FileSystemException>()),
        );
        await expectSymlinkArtifact(artifactPath, linkTarget);
      });

      test('prunes registered profile artifacts when no entries own '
          'them', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(homeDirectory).create(recursive: true);

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
            'entries': <Object?>[],
          }),
        );

        final artifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'work',
          '.gitconfig',
        );
        await Directory(p.dirname(artifactPath)).create(recursive: true);
        await File(artifactPath).writeAsString('[user]\n  name = Stale\n');

        final result = await pushChanges(
          const PushRequest(dryRun: false, profile: 'work'),
        );

        expect(result.deletedArtifactCount, 1);
        expectPathAbsent(artifactPath);
      });

      test('status and push prune artifacts from profile namespaces removed '
          'from the manifest', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final gitconfig = p.join(homeDirectory, '.gitconfig');
        final emptyDirectory = p.join(
          homeDirectory,
          '.config',
          'removed-profile-empty',
        );
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(emptyDirectory).create(recursive: true);
        await File(gitconfig).writeAsString('[user]\n  name = Removed\n');

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
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/removed-profile-empty'},
                'repoPath': {'default': '.config/removed-profile-empty'},
                'mode': {'default': 'normal'},
                'profiles': ['work'],
              },
            ],
          }),
        );

        await pushChanges(const PushRequest(dryRun: false, profile: 'work'));

        final fileArtifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'work',
          '.gitconfig',
        );
        final emptyDirectoryArtifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'work',
          '.config',
          'removed-profile-empty',
        );
        expect(
          await File(fileArtifactPath).readAsString(),
          '[user]\n  name = Removed\n',
        );
        expect(
          FileSystemEntity.typeSync(
            emptyDirectoryArtifactPath,
            followLinks: false,
          ),
          FileSystemEntityType.directory,
        );

        final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');

        await runGit(['add', '.'], syncDirectory);
        await runGit([
          'commit',
          '-m',
          'store work profile artifacts',
        ], syncDirectory);

        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'profiles': <Object?>[],
            'entries': <Object?>[],
          }),
        );

        final status = await getStatus();
        final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(status.push.changes.deleted, [
          'work/.config/removed-profile-empty/',
          'work/.gitconfig',
        ]);
        expect(status.push.deletedArtifactCount, 2);
        expect(status.push.preview, [
          'work/.config/removed-profile-empty/',
          'work/.gitconfig',
        ]);
        expect(dryRunResult.deletedArtifactCount, 2);
        expect(result.deletedArtifactCount, 2);
        expectPathAbsent(fileArtifactPath);
        expectPathAbsent(emptyDirectoryArtifactPath);
      });

      test(
        'ignores repository support directories when pruning removed profile '
        'namespaces',
        () async {
          final workspace = await createWorkspace();
          final homeDirectory = p.join(workspace, 'home');
          final xdgConfigHome = p.join(workspace, 'xdg');
          final gitconfig = p.join(homeDirectory, '.gitconfig');
          final ageKeys = await createAgeKeyPair();
          setEnvironment(homeDirectory, xdgConfigHome);

          await writeIdentityFile(xdgConfigHome, ageKeys.identity);
          await Directory(homeDirectory).create(recursive: true);
          await File(gitconfig).writeAsString('[user]\n  name = Removed\n');

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

          final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');

          await runGit(['add', '.'], syncDirectory);
          await runGit([
            'commit',
            '-m',
            'store work profile artifacts',
          ], syncDirectory);

          final workflowPath = p.join(
            xdgConfigHome,
            'dotweave',
            'repository',
            '.github',
            'workflows',
            'ci.yml',
          );
          await Directory(p.dirname(workflowPath)).create(recursive: true);
          await File(workflowPath).writeAsString('name: CI\n');

          final docsPath = p.join(
            xdgConfigHome,
            'dotweave',
            'repository',
            'docs',
            'index.md',
          );
          final scriptPath = p.join(
            xdgConfigHome,
            'dotweave',
            'repository',
            'scripts',
            'bootstrap.sh',
          );
          final removedProfileArtifactPath = p.join(
            xdgConfigHome,
            'dotweave',
            'repository',
            'profiles',
            'work',
            '.gitconfig',
          );

          await Directory(p.dirname(docsPath)).create(recursive: true);
          await Directory(p.dirname(scriptPath)).create(recursive: true);
          await File(docsPath).writeAsString('# Docs\n');
          await File(scriptPath).writeAsString('#!/usr/bin/env sh\n');

          await File(manifestPath).writeAsString(
            jsonStringify({
              'version': 8,
              'age': {
                'recipients': [ageKeys.recipient],
              },
              'profiles': <Object?>[],
              'entries': <Object?>[],
            }),
          );

          final status = await getStatus();
          final dryRunResult = await pushChanges(
            const PushRequest(dryRun: true),
          );
          final result = await pushChanges(const PushRequest(dryRun: false));

          expect(status.push.changes.deleted, ['work/.gitconfig']);
          expect(status.push.changes.deleted, isNot(contains('docs/index.md')));
          expect(
            status.push.changes.deleted,
            isNot(contains('scripts/bootstrap.sh')),
          );
          expect(status.push.deletedArtifactCount, 1);
          expect(status.push.preview, ['work/.gitconfig']);
          expect(dryRunResult.deletedArtifactCount, 1);
          expect(result.deletedArtifactCount, 1);
          expect(await File(workflowPath).readAsString(), 'name: CI\n');
          expect(await File(docsPath).readAsString(), '# Docs\n');
          expect(await File(scriptPath).readAsString(), '#!/usr/bin/env sh\n');
          expectPathAbsent(removedProfileArtifactPath);
        },
      );

      test('ignores invalid committed profile namespaces when pruning removed '
          'profile artifacts', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final gitconfig = p.join(homeDirectory, '.gitconfig');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(homeDirectory).create(recursive: true);
        await File(gitconfig).writeAsString('[user]\n  name = Removed\n');

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );

        final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
        final manifestPath = p.join(syncDirectory, 'manifest.jsonc');

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

        final removedProfileArtifactPath = p.join(
          syncDirectory,
          'profiles',
          'work',
          '.gitconfig',
        );
        final outsideDocsPath = p.normalize(
          p.join(syncDirectory, '..', 'docs', 'index.md'),
        );
        final workflowPath = p.join(
          syncDirectory,
          '.github',
          'workflows',
          'ci.yml',
        );

        await Directory(p.dirname(outsideDocsPath)).create(recursive: true);
        await Directory(p.dirname(workflowPath)).create(recursive: true);
        await File(outsideDocsPath).writeAsString('# Outside docs\n');
        await File(workflowPath).writeAsString('name: CI\n');
        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'profiles': ['work', '..', '../docs', '.github'],
            'entries': [
              {
                'kind': 'file',
                'localPath': {'default': '~/.gitconfig'},
                'mode': {'default': 'normal'},
                'profiles': ['work'],
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.ignored'},
                'mode': {'default': 'normal'},
                'profiles': ['../docs'],
              },
            ],
          }),
        );

        await runGit(['add', '.'], syncDirectory);
        await runGit([
          'commit',
          '-m',
          'store invalid committed profiles',
        ], syncDirectory);

        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'profiles': <Object?>[],
            'entries': <Object?>[],
          }),
        );

        final status = await getStatus();
        final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(status.push.changes.deleted, ['work/.gitconfig']);
        expect(status.push.deletedArtifactCount, 1);
        expect(status.push.preview, ['work/.gitconfig']);
        expect(dryRunResult.deletedArtifactCount, 1);
        expect(result.deletedArtifactCount, 1);
        expectPathAbsent(removedProfileArtifactPath);
        expect(await File(outsideDocsPath).readAsString(), '# Outside docs\n');
        expect(await File(workflowPath).readAsString(), 'name: CI\n');
      });

      test('replaces a stale child directory with a file while the parent '
          'directory remains configured', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final parentDirectory = p.join(
          homeDirectory,
          '.config',
          'overlap-file',
        );
        final childDirectory = p.join(parentDirectory, 'child');
        final replacementFile = p.join(homeDirectory, '.overlap-file-child');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(childDirectory).create(recursive: true);
        await File(
          p.join(childDirectory, 'settings.json'),
        ).writeAsString('{"stale":true}\n');
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
                'localPath': {'default': '~/.config/overlap-file'},
                'repoPath': {'default': 'apps/overlap-file'},
                'mode': {'default': 'normal'},
              },
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/overlap-file/child'},
                'repoPath': {'default': 'apps/overlap-file/child'},
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
          'overlap-file',
          'child',
        );
        expect(
          await File(p.join(artifactPath, 'settings.json')).readAsString(),
          '{"stale":true}\n',
        );

        await Directory(childDirectory).delete(recursive: true);
        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/overlap-file'},
                'repoPath': {'default': 'apps/overlap-file'},
                'mode': {'default': 'normal'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.overlap-file-child'},
                'repoPath': {'default': 'apps/overlap-file/child'},
                'mode': {'default': 'normal'},
              },
            ],
          }),
        );

        final status = await getStatus();
        final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(
          status.push.changes.deleted,
          contains('default/apps/overlap-file/child/settings.json'),
        );
        expect(dryRunResult.deletedArtifactCount, 1);
        expect(result.deletedArtifactCount, 1);
        expect(
          FileSystemEntity.typeSync(artifactPath, followLinks: false),
          FileSystemEntityType.file,
        );
        expect(await File(artifactPath).readAsString(), 'replacement file\n');
      });

      test('replaces a stale child directory with a symlink while the parent '
          'directory remains configured', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final parentDirectory = p.join(
          homeDirectory,
          '.config',
          'overlap-link',
        );
        final childDirectory = p.join(parentDirectory, 'child');
        final linkTarget = p.join(homeDirectory, '.overlap-link-target');
        final replacementLink = p.join(homeDirectory, '.overlap-link-child');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(childDirectory).create(recursive: true);
        await File(
          p.join(childDirectory, 'settings.json'),
        ).writeAsString('{"stale":true}\n');
        await File(linkTarget).writeAsString('replacement link target\n');
        await createSymlink('.overlap-link-target', replacementLink);

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
                'localPath': {'default': '~/.config/overlap-link'},
                'repoPath': {'default': 'apps/overlap-link'},
                'mode': {'default': 'normal'},
              },
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/overlap-link/child'},
                'repoPath': {'default': 'apps/overlap-link/child'},
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
          'overlap-link',
          'child',
        );
        expect(
          await File(p.join(artifactPath, 'settings.json')).readAsString(),
          '{"stale":true}\n',
        );

        await Directory(childDirectory).delete(recursive: true);
        await File(manifestPath).writeAsString(
          jsonStringify({
            'version': 8,
            'age': {
              'recipients': [ageKeys.recipient],
            },
            'entries': [
              {
                'kind': 'directory',
                'localPath': {'default': '~/.config/overlap-link'},
                'repoPath': {'default': 'apps/overlap-link'},
                'mode': {'default': 'normal'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.overlap-link-child'},
                'repoPath': {'default': 'apps/overlap-link/child'},
                'mode': {'default': 'normal'},
              },
            ],
          }),
        );

        final status = await getStatus();
        final dryRunResult = await pushChanges(const PushRequest(dryRun: true));
        final result = await pushChanges(const PushRequest(dryRun: false));

        expect(
          status.push.changes.deleted,
          contains('default/apps/overlap-link/child/settings.json'),
        );
        expect(dryRunResult.deletedArtifactCount, 1);
        expect(result.deletedArtifactCount, 1);
        await expectSymlinkArtifact(artifactPath, '.overlap-link-target');
      });

      test('restores file permission from entry permission on pull', () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final sshDirectory = p.join(homeDirectory, '.ssh');
        final keyFile = p.join(sshDirectory, 'id_rsa');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(sshDirectory).create(recursive: true);
        await File(keyFile).writeAsString('fake-private-key\n');

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
                'localPath': {'default': '~/.ssh/id_rsa'},
                'mode': {'default': 'secret'},
                'permission': {'default': '0600'},
              },
            ],
          }),
        );

        await pushChanges(const PushRequest(dryRun: false));
        await File(keyFile).writeAsString('modified-content\n');
        await pullChanges(const PullRequest(dryRun: false));

        expect(await File(keyFile).readAsString(), 'fake-private-key\n');
        final stats = await File(keyFile).stat();
        expect(stats.mode & 0x1FF, 0x180); // mode & 0o777 == 0o600
      });

      test(
        'restores directory entry permission to child files and a searchable '
        'directory on pull',
        () async {
          if (Platform.isWindows) {
            return;
          }

          final workspace = await createWorkspace();
          final homeDirectory = p.join(workspace, 'home');
          final xdgConfigHome = p.join(workspace, 'xdg');
          final sshDirectory = p.join(homeDirectory, '.ssh');
          final keyFile = p.join(sshDirectory, 'id_rsa');
          final configFile = p.join(sshDirectory, 'config');
          final ageKeys = await createAgeKeyPair();
          setEnvironment(homeDirectory, xdgConfigHome);

          await writeIdentityFile(xdgConfigHome, ageKeys.identity);
          await Directory(sshDirectory).create(recursive: true);
          await File(keyFile).writeAsString('fake-private-key\n');
          await File(
            configFile,
          ).writeAsString('Host *\n  AddKeysToAgent yes\n');

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
                  'localPath': {'default': '~/.ssh'},
                  'mode': {'default': 'normal'},
                  'permission': {'default': '0600'},
                },
              ],
            }),
          );

          await pushChanges(const PushRequest(dryRun: false));
          await Directory(sshDirectory).delete(recursive: true);
          await pullChanges(const PullRequest(dryRun: false));

          expect(await File(keyFile).readAsString(), 'fake-private-key\n');
          expect(
            await File(configFile).readAsString(),
            'Host *\n  AddKeysToAgent yes\n',
          );

          final directoryStats = await Directory(sshDirectory).stat();
          expect(directoryStats.mode & 0x1FF, 0x1C0); // mode & 0o777 == 0o700

          final keyStats = await File(keyFile).stat();
          expect(keyStats.mode & 0x1FF, 0x180); // mode & 0o777 == 0o600

          final configStats = await File(configFile).stat();
          expect(configStats.mode & 0x1FF, 0x180); // mode & 0o777 == 0o600
        },
      );

      test('preserves ignored local files inside permissioned directories on '
          'pull', () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final sshDirectory = p.join(homeDirectory, '.ssh');
        final keyFile = p.join(sshDirectory, 'id_rsa');
        final ignoredFile = p.join(sshDirectory, 'known_hosts.local');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(sshDirectory).create(recursive: true);
        await File(keyFile).writeAsString('fake-private-key\n');
        await File(ignoredFile).writeAsString('initial-local-state\n');

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
                'localPath': {'default': '~/.ssh'},
                'mode': {'default': 'normal'},
                'permission': {'default': '0600'},
              },
              {
                'kind': 'file',
                'localPath': {'default': '~/.ssh/known_hosts.local'},
                'mode': {'default': 'ignore'},
              },
            ],
          }),
        );

        await pushChanges(const PushRequest(dryRun: false));
        await File(keyFile).writeAsString('modified-content\n');
        await File(ignoredFile).writeAsString('preserved-local-state\n');
        await pullChanges(const PullRequest(dryRun: false));

        expect(await File(keyFile).readAsString(), 'fake-private-key\n');
        expect(
          await File(ignoredFile).readAsString(),
          'preserved-local-state\n',
        );

        final directoryStats = await Directory(sshDirectory).stat();
        expect(directoryStats.mode & 0x1FF, 0x1C0); // mode & 0o777 == 0o700

        final keyStats = await File(keyFile).stat();
        expect(keyStats.mode & 0x1FF, 0x180); // mode & 0o777 == 0o600
      });

      test('pull updates only changed files without replacing the tracked '
          'directory', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final appDirectory = p.join(homeDirectory, '.config', 'myapp');
        final configFile = p.join(appDirectory, 'config.json');
        final settingsFile = p.join(appDirectory, 'settings.json');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(appDirectory).create(recursive: true);
        await File(configFile).writeAsString('{"version":1}\n');
        await File(settingsFile).writeAsString('{"theme":"dark"}\n');

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
            target: appDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final localDirectoryBefore = await _readFileIdentity(appDirectory);
        final localConfigBefore = await _readFileIdentity(configFile);
        final repoSettingsFile = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'myapp',
          'settings.json',
        );

        await File(repoSettingsFile).writeAsString('{"theme":"light"}\n');
        await pullChanges(const PullRequest(dryRun: false));

        final localDirectoryAfter = await _readFileIdentity(appDirectory);
        final localConfigAfter = await _readFileIdentity(configFile);

        expect(localDirectoryAfter, localDirectoryBefore);
        expect(localConfigAfter, localConfigBefore);
        expect(await File(configFile).readAsString(), '{"version":1}\n');
        expect(await File(settingsFile).readAsString(), '{"theme":"light"}\n');
      });

      test('pull reconciles nested directories without recreating unchanged '
          'ancestors', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final appDirectory = p.join(homeDirectory, '.config', 'myapp');
        final themesDirectory = p.join(appDirectory, 'themes');
        final nestedThemeFile = p.join(themesDirectory, 'dark.json');
        final siblingFile = p.join(appDirectory, 'settings.json');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(themesDirectory).create(recursive: true);
        await File(nestedThemeFile).writeAsString('{"accent":"blue"}\n');
        await File(siblingFile).writeAsString('{"font":"mono"}\n');

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
            target: appDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final appDirectoryBefore = await _readFileIdentity(appDirectory);
        final themesDirectoryBefore = await _readFileIdentity(themesDirectory);
        final siblingFileBefore = await _readFileIdentity(siblingFile);
        final repoNestedThemeFile = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'myapp',
          'themes',
          'dark.json',
        );

        await File(repoNestedThemeFile).writeAsString('{"accent":"amber"}\n');
        await pullChanges(const PullRequest(dryRun: false));

        final appDirectoryAfter = await _readFileIdentity(appDirectory);
        final themesDirectoryAfter = await _readFileIdentity(themesDirectory);
        final siblingFileAfter = await _readFileIdentity(siblingFile);

        expect(appDirectoryAfter, appDirectoryBefore);
        expect(themesDirectoryAfter, themesDirectoryBefore);
        expect(siblingFileAfter, siblingFileBefore);
        expect(
          await File(nestedThemeFile).readAsString(),
          '{"accent":"amber"}\n',
        );
        expect(await File(siblingFile).readAsString(), '{"font":"mono"}\n');
      });

      test('uses default executable mode when permission is not set', () async {
        if (Platform.isWindows) {
          return;
        }

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

        await trackTarget(
          TrackRequest(mode: const TrackModeValue('normal'), target: gitconfig),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));
        await File(gitconfig).delete();
        await pullChanges(const PullRequest(dryRun: false));

        final stats = await File(gitconfig).stat();
        expect(stats.mode & 0x1FF, 0x1A4); // mode & 0o777 == 0o644
      });

      test('preserves permission field in config through round-trip', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final keyFile = p.join(homeDirectory, '.ssh', 'id_rsa');
        final ageKeys = await createAgeKeyPair();
        setEnvironment(homeDirectory, xdgConfigHome);

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(p.join(homeDirectory, '.ssh')).create(recursive: true);
        await File(keyFile).writeAsString('key-content\n');

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
                'localPath': {'default': '~/.ssh/id_rsa'},
                'mode': {'default': 'secret'},
                'permission': {'default': '0600'},
              },
            ],
          }),
        );

        await pushChanges(const PushRequest(dryRun: false));

        final permissionEntries = parseManifestEntries(
          await File(manifestPath).readAsString(),
        );

        expect(permissionEntries[0]['permission'], {'default': '0600'});
      });

      test('assigns and unassigns profiles to entries', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final gitconfig = p.join(homeDirectory, '.gitconfig');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(homeDirectory).create(recursive: true);
        await File(gitconfig).writeAsString('[user]\nname=test\n');

        setEnvironment(homeDirectory, xdgConfigHome);
        final cwd = homeDirectory;

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );
        await trackTarget(
          TrackRequest(mode: const TrackModeValue('normal'), target: gitconfig),
          cwd,
        );
        await addProfile('work');

        final assignResult = await assignProfiles(
          AssignProfilesRequest(
            target: gitconfig,
            profiles: const ['default', 'work'],
          ),
          cwd,
        );

        expect(assignResult.action, 'assigned');
        expect(assignResult.profiles, ['default', 'work']);

        final profileEntries = parseManifestEntries(
          await File(
            p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
          ).readAsString(),
        );

        expect(profileEntries[0]['profiles'], ['default', 'work']);

        final listResult = await listProfiles();

        expect(listResult.availableProfiles, ['default', 'work']);
        expect(listResult.assignments, [
          ProfileAssignment(
            entryLocalPath: gitconfig,
            entryRepoPath: '.gitconfig',
            profiles: const ['default', 'work'],
          ),
        ]);

        final reassignResult = await assignProfiles(
          AssignProfilesRequest(target: gitconfig, profiles: const ['default']),
          cwd,
        );

        expect(reassignResult.action, 'assigned');
        expect(reassignResult.profiles, ['default']);

        final clearResult = await assignProfiles(
          AssignProfilesRequest(target: gitconfig, profiles: const []),
          cwd,
        );

        expect(clearResult.action, 'assigned');
        expect(clearResult.profiles, <String>[]);

        final profileEntriesAfter = parseManifestEntries(
          await File(
            p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
          ).readAsString(),
        );

        expect(profileEntriesAfter[0]['profiles'], isNull);
      });

      test('deletes local files that were removed from repository during '
          'pull', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final appDirectory = p.join(homeDirectory, '.config', 'myapp');
        final fileA = p.join(appDirectory, 'config.json');
        final fileB = p.join(appDirectory, 'settings.json');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(appDirectory).create(recursive: true);
        await File(fileA).writeAsString('{"key": "value"}\n');
        await File(fileB).writeAsString('{"setting": "value"}\n');

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
            target: appDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final repoPathA = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'myapp',
          'config.json',
        );
        final repoPathB = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'myapp',
          'settings.json',
        );

        expect(
          await File(repoPathA).readAsString(),
          contains('"key": "value"'),
        );
        expect(
          await File(repoPathB).readAsString(),
          contains('"setting": "value"'),
        );

        await File(repoPathB).delete();

        await pullChanges(const PullRequest(dryRun: false));

        expect(await File(fileA).readAsString(), contains('"key": "value"'));
        await expectLater(
          File(fileB).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
      });

      test('deletes local files when entire tracked directory is removed from '
          'repository', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final sshDirectory = p.join(homeDirectory, '.ssh');
        final keyFile = p.join(sshDirectory, 'id_rsa');
        final configFile = p.join(sshDirectory, 'config');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(sshDirectory).create(recursive: true);
        await File(keyFile).writeAsString('fake-private-key\n');
        await File(configFile).writeAsString('Host *\n  AddKeysToAgent yes\n');

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
            target: sshDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final repoSshDir = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.ssh',
        );

        expect(
          await File(p.join(repoSshDir, 'id_rsa')).readAsString(),
          contains('fake-private-key'),
        );

        await Directory(repoSshDir).delete(recursive: true);

        final result = await pullChanges(const PullRequest(dryRun: false));

        expect(result.deletedLocalCount, greaterThanOrEqualTo(1));
        await expectLater(
          File(keyFile).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
        await expectLater(
          File(configFile).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
      });

      test('prunes stale empty managed directories during pull', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final appDirectory = p.join(homeDirectory, '.config', 'bundle');
        final cacheDirectory = p.join(appDirectory, 'cache');
        final cacheFile = p.join(cacheDirectory, 'old.txt');
        final keepFile = p.join(appDirectory, 'keep.txt');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(cacheDirectory).create(recursive: true);
        await File(cacheFile).writeAsString('old\n');
        await File(keepFile).writeAsString('keep\n');

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
            target: appDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final repoCacheFile = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'bundle',
          'cache',
          'old.txt',
        );
        final repoCacheDirectory = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'bundle',
          'cache',
        );
        await File(repoCacheFile).delete();
        await Directory(repoCacheDirectory).delete(recursive: true);

        await pullChanges(const PullRequest(dryRun: false));

        await expectLater(
          File(cacheFile).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
        expectPathAbsent(cacheDirectory);
        expect(await File(keepFile).readAsString(), 'keep\n');
      });

      test('pull replaces a tracked file with a directory when the repository '
          'type changes', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final appDirectory = p.join(homeDirectory, '.config', 'app');
        final currentPath = p.join(appDirectory, 'current');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(appDirectory).create(recursive: true);
        await File(currentPath).writeAsString('v1\n');

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
            target: appDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final repoCurrentPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'app',
          'current',
        );

        await File(repoCurrentPath).delete();
        await Directory(repoCurrentPath).create(recursive: true);
        await File(p.join(repoCurrentPath, 'index.txt')).writeAsString('v2\n');

        await pullChanges(const PullRequest(dryRun: false));

        expect(
          FileSystemEntity.typeSync(currentPath, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(
          await File(p.join(currentPath, 'index.txt')).readAsString(),
          'v2\n',
        );
      });

      test('pull replaces a tracked symlink with a file when the repository '
          'type changes', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final appDirectory = p.join(homeDirectory, '.config', 'app');
        final targetFile = p.join(appDirectory, 'target.txt');
        final currentPath = p.join(appDirectory, 'current');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(appDirectory).create(recursive: true);
        await File(targetFile).writeAsString('target\n');
        await createSymlink('./target.txt', currentPath);

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
            target: appDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final repoCurrentPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'app',
          'current',
        );

        // Simulate the repository changing the entry from a symlink to a
        // regular file: drop the `.dotweave.symlink` metadata file and add a
        // plain file.
        await File(symlinkArtifactPath(repoCurrentPath)).delete();
        await File(repoCurrentPath).writeAsString('plain\n');

        await pullChanges(const PullRequest(dryRun: false));

        expect(
          FileSystemEntity.typeSync(currentPath, followLinks: false),
          FileSystemEntityType.file,
        );
        expect(await File(currentPath).readAsString(), 'plain\n');
      });

      test('reports deleted local count in pull result', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final bundleDirectory = p.join(homeDirectory, '.config', 'bundle');
        final file1 = p.join(bundleDirectory, 'file1.txt');
        final file2 = p.join(bundleDirectory, 'file2.txt');
        final file3 = p.join(bundleDirectory, 'file3.txt');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(bundleDirectory).create(recursive: true);
        await File(file1).writeAsString('content1\n');
        await File(file2).writeAsString('content2\n');
        await File(file3).writeAsString('content3\n');

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
            target: bundleDirectory,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final repoFile2 = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'bundle',
          'file2.txt',
        );
        final repoFile3 = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'bundle',
          'file3.txt',
        );

        await File(repoFile2).delete();
        await File(repoFile3).delete();

        final result = await pullChanges(const PullRequest(dryRun: false));

        expect(result.deletedLocalCount, 2);
        expect(await File(file1).readAsString(), 'content1\n');
        await expectLater(
          File(file2).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
        await expectLater(
          File(file3).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
      });

      test('skips rewriting unchanged plain artifacts on push', () async {
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

        await pushChanges(const PushRequest(dryRun: false));

        final artifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.gitconfig',
        );
        final beforeStats = await File(artifactPath).stat();

        await Future<void>.delayed(const Duration(milliseconds: 20));
        await pushChanges(const PushRequest(dryRun: false));

        final afterStats = await File(artifactPath).stat();

        expect(afterStats.modified, beforeStats.modified);
        expect(await File(artifactPath).readAsString(), '[user]\nname=test\n');
      });

      test('skips recreating unchanged symlink artifacts on push', () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final zshenv = p.join(homeDirectory, '.zshenv');
        final zshrc = p.join(homeDirectory, '.zshrc');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(homeDirectory).create(recursive: true);
        await File(zshrc).writeAsString(
          r'export PATH=~/.local/bin:$PATH'
          '\n',
        );
        await createSymlink('.zshrc', zshenv);

        setEnvironment(homeDirectory, xdgConfigHome);

        await initializeSyncDirectory(
          InitRequest(
            identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
            recipients: [ageKeys.recipient],
          ),
        );
        await trackTarget(
          TrackRequest(mode: const TrackModeValue('normal'), target: zshenv),
          homeDirectory,
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
        final metaPath = symlinkArtifactPath(artifactPath);
        final beforeIdentity = await _readFileIdentity(metaPath);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        await pushChanges(const PushRequest(dryRun: false));

        final afterIdentity = await _readFileIdentity(metaPath);

        expect(afterIdentity, beforeIdentity);
        await expectSymlinkArtifact(artifactPath, '.zshrc');
      });

      test('updates repository artifacts when only the executable bit '
          'changes', () async {
        if (Platform.isWindows) {
          return;
        }

        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final scriptPath = p.join(homeDirectory, 'bin', 'hello.sh');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(p.join(homeDirectory, 'bin')).create(recursive: true);
        await File(scriptPath).writeAsString('#!/bin/sh\necho hello\n');
        posixChmod(scriptPath, 0x1A4); // 0o644

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
            target: scriptPath,
          ),
          homeDirectory,
        );

        await pushChanges(const PushRequest(dryRun: false));

        final artifactPath = p.join(
          xdgConfigHome,
          'dotweave',
          'repository',
          'profiles',
          'default',
          'bin',
          'hello.sh',
        );

        expect(
          (await File(artifactPath).stat()).mode & 0x1FF,
          0x1A4, // mode & 0o777 == 0o644
        );

        posixChmod(scriptPath, 0x1ED); // 0o755
        await pushChanges(const PushRequest(dryRun: false));

        expect(
          (await File(artifactPath).stat()).mode & 0x1FF,
          0x1ED, // mode & 0o777 == 0o755
        );
        expect(
          await File(artifactPath).readAsString(),
          '#!/bin/sh\necho hello\n',
        );
      });
    },
  );
}
