import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/sync_fixture.dart';

// The invariant: a file entry owns every repository path it is *configured* to
// use, on every platform key -- not only the one that resolves here. A
// directory entry that happens to contain one of those paths does not adopt it
// in either direction.
//
// Without that, `collectChildEntryPaths` claims only the resolved repo path
// plus the one implied by the child's localPath, so the remaining variants are
// unowned and the directory parent takes them: `pull` writes another machine's
// artifact into HOME, and `push` overwrites the artifact that machine stored.
// The child's own `mode: ignore` cannot prevent either, because on the parent's
// side those paths belong to the parent.
//
// `classifyArtifactOwnership` carries the other half. Ownership there runs
// through `findOwningSyncEntry`, which also sees only resolved repo paths, so
// the directory parent is reported as owner and the artifact is pruned the
// first time this machine pushes without a local counterpart.

/// The entry pair from the original bug report: `ignore` everywhere except WSL.
Object buildManifest(String recipient) {
  return {
    'version': 8,
    'age': {
      'recipients': [recipient],
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
          'mac': '.config/zsh/platform.mac.zsh',
          'wsl': '.config/zsh/platform.wsl.zsh',
        },
        'mode': {'default': 'ignore', 'wsl': 'normal'},
      },
    ],
  };
}

/// The same entry pair with every platform syncing, so each machine reads and
/// writes its own repository variant through one local filename.
Object buildSyncedManifest(String recipient) {
  return {
    'version': 8,
    'age': {
      'recipients': [recipient],
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
          'mac': '.config/zsh/platform.mac.zsh',
          'wsl': '.config/zsh/platform.wsl.zsh',
        },
        'mode': {'default': 'normal'},
      },
    ],
  };
}

/// The file entry alone, with no directory parent covering `.config/zsh`.
Object buildManifestWithoutDirectoryParent(String recipient) {
  return {
    'version': 8,
    'age': {
      'recipients': [recipient],
    },
    'entries': [
      {
        'kind': 'file',
        'localPath': {'default': '~/.config/zsh/platform.zsh'},
        'repoPath': {
          'default': '.config/zsh/platform.zsh',
          'mac': '.config/zsh/platform.mac.zsh',
          'wsl': '.config/zsh/platform.wsl.zsh',
        },
        'mode': {'default': 'ignore', 'wsl': 'normal'},
      },
    ],
  };
}

/// An isolated workspace whose repository already holds every platform's
/// variant of the entry, as it would after each machine pushed. [localFiles]
/// is keyed by name within `~/.config/zsh`.
Future<({String repoZshDir, String zshDir})> setUpWorkspace(
  Object Function(String recipient) manifest, {
  Map<String, String> localFiles = const {},
}) async {
  final workspace = await createWorkspace();
  final homeDirectory = p.join(workspace, 'home');
  final xdgConfigHome = p.join(workspace, 'xdg');
  final zshDirectory = p.join(homeDirectory, '.config', 'zsh');
  final ageKeys = await createAgeKeyPair();

  setEnvironment(homeDirectory, xdgConfigHome);
  await writeIdentityFile(xdgConfigHome, ageKeys.identity);
  await Directory(zshDirectory).create(recursive: true);

  for (final MapEntry(key: name, value: contents) in localFiles.entries) {
    await File(p.join(zshDirectory, name)).writeAsString(contents);
  }

  await initializeSyncDirectory(
    InitRequest(
      identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
      recipients: [ageKeys.recipient],
    ),
  );

  await File(
    p.join(xdgConfigHome, 'dotweave', 'repository', 'manifest.jsonc'),
  ).writeAsString(jsonStringify(manifest(ageKeys.recipient)));

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
    p.join(repositoryZshDirectory, 'platform.mac.zsh'),
  ).writeAsString('mac artifact\n');
  await File(
    p.join(repositoryZshDirectory, 'platform.wsl.zsh'),
  ).writeAsString('wsl artifact\n');
  await File(
    p.join(repositoryZshDirectory, 'other.zsh'),
  ).writeAsString('other\n');

  return (repoZshDir: repositoryZshDirectory, zshDir: zshDirectory);
}

void main() {
  tearDown(cleanUpSyncFixture);

  group('per-platform repoPath overrides under a directory parent', () {
    test(
      'pull on mac does not materialize the wsl repository artifact',
      () async {
        final workspace = await setUpWorkspace(buildManifest);

        mockCurrentPlatformKey(PlatformKey.mac);
        await pullChanges(const PullRequest(dryRun: false));

        // The reported symptom: `platform.wsl.zsh` appeared in the mac home
        // directory even though the entry that owns that repository path
        // resolves to `platform.mac.zsh` on mac and is `ignore` there.
        expectPathAbsent(p.join(workspace.zshDir, 'platform.wsl.zsh'));
        expect(
          await File(p.join(workspace.zshDir, 'other.zsh')).readAsString(),
          'other\n',
        );
      },
    );

    test(
      'pull plan on mac does not list the wsl artifact as an update',
      () async {
        final workspace = await setUpWorkspace(buildManifest);

        mockCurrentPlatformKey(PlatformKey.mac);
        final prepared = await preparePull(const PullRequest(dryRun: true));

        expect(
          prepared.plan.updatedLocalPaths,
          isNot(contains(p.join(workspace.zshDir, 'platform.wsl.zsh'))),
        );
      },
    );

    test(
      'pull on wsl does not materialize the mac repository artifact',
      () async {
        final workspace = await setUpWorkspace(buildManifest);

        mockCurrentPlatformKey(PlatformKey.wsl);
        await pullChanges(const PullRequest(dryRun: false));

        // The mirror image of the reported case: the mac variant leaked into a
        // WSL home directory for the same reason.
        expectPathAbsent(p.join(workspace.zshDir, 'platform.mac.zsh'));
        expect(
          await File(p.join(workspace.zshDir, 'platform.zsh')).readAsString(),
          'wsl artifact\n',
        );
      },
    );

    test(
      'a directory parent is what adopts the foreign platform artifact',
      () async {
        // The control: with no directory entry covering `.config/zsh`, nothing
        // claims `platform.wsl.zsh` and nothing is materialized. The leak was the
        // parent adopting a path the child entry only owns on another platform.
        final workspace = await setUpWorkspace(
          buildManifestWithoutDirectoryParent,
        );

        mockCurrentPlatformKey(PlatformKey.mac);
        await pullChanges(const PullRequest(dryRun: false));

        expectPathAbsent(p.join(workspace.zshDir, 'platform.wsl.zsh'));
      },
    );

    test(
      'pull on mac applies the mac variant under the local filename',
      () async {
        final workspace = await setUpWorkspace(buildSyncedManifest);

        mockCurrentPlatformKey(PlatformKey.mac);
        await pullChanges(const PullRequest(dryRun: false));

        // Each machine reads its own repository variant through one local name.
        expect(
          await File(p.join(workspace.zshDir, 'platform.zsh')).readAsString(),
          'mac artifact\n',
        );
        expectPathAbsent(p.join(workspace.zshDir, 'platform.mac.zsh'));
        expectPathAbsent(p.join(workspace.zshDir, 'platform.wsl.zsh'));
      },
    );

    test('push on mac does not overwrite the wsl artifact from a same-named '
        'local file', () async {
      final workspace = await setUpWorkspace(
        buildSyncedManifest,
        localFiles: {
          'platform.zsh': 'local mac\n',
          'platform.wsl.zsh': 'local junk\n',
          'other.zsh': 'other\n',
        },
      );

      mockCurrentPlatformKey(PlatformKey.mac);
      await pushChanges(const PushRequest(dryRun: false));

      // A local file whose repository path belongs to another platform's
      // override is not this machine's to store there.
      expect(
        await File(
          p.join(workspace.repoZshDir, 'platform.wsl.zsh'),
        ).readAsString(),
        'wsl artifact\n',
      );
      expect(
        await File(
          p.join(workspace.repoZshDir, 'platform.mac.zsh'),
        ).readAsString(),
        'local mac\n',
      );
    });

    test('push on mac does not delete the wsl artifact', () async {
      final workspace = await setUpWorkspace(
        buildSyncedManifest,
        localFiles: {'platform.zsh': 'local mac\n', 'other.zsh': 'other\n'},
      );

      mockCurrentPlatformKey(PlatformKey.mac);
      final result = await pushChanges(const PushRequest(dryRun: false));

      // Once pull stops leaking the file, nothing local corresponds to the wsl
      // variant -- and without platform protection it would be pruned as stale,
      // erasing the other machine's configuration from the repository.
      expect(result.deletedArtifactCount, 0);
      expect(
        await File(
          p.join(workspace.repoZshDir, 'platform.wsl.zsh'),
        ).readAsString(),
        'wsl artifact\n',
      );
    });
  });
}
