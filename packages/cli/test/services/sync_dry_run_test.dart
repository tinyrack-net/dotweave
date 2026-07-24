import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/status.dart';
import 'package:dotweave/src/services/sync_mode.dart';
import 'package:dotweave/src/services/track.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/sync_fixture.dart';

// Port of `sync.dry-run.test.ts`: dry-run push/pull/status flows against a
// real isolated workspace.

void main() {
  tearDown(cleanUpSyncFixture);

  group('sync dry runs', () {
    test(
      'reports push changes without mutating repository artifacts',
      () async {
        final workspace = await createWorkspace('dotweave-dry-run-');
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final bundleDirectory = p.join(homeDirectory, 'bundle');
        final plainFile = p.join(bundleDirectory, 'plain.txt');
        final secretFile = p.join(bundleDirectory, 'token.txt');
        final ageKeys = await createAgeKeyPair();
        final cwd = homeDirectory;

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(bundleDirectory).create(recursive: true);
        await File(plainFile).writeAsString('plain\n');
        await File(secretFile).writeAsString('secret\n');

        setEnvironment(homeDirectory, xdgConfigHome);
        await initializeSyncDirectory(
          InitRequest(recipients: [ageKeys.recipient]),
        );
        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('normal'),
            target: bundleDirectory,
          ),
          cwd,
        );
        await setTargetMode(
          SetModeRequest(mode: 'secret', target: secretFile),
          cwd,
        );

        final result = await pushChanges(const PushRequest(dryRun: true));

        expect(result.dryRun, isTrue);
        expect(result.directoryCount, 1);
        expect(result.plainFileCount, 1);
        expect(result.encryptedFileCount, 1);
        await expectLater(
          File(
            p.join(
              xdgConfigHome,
              'dotweave',
              'sync',
              'default',
              'bundle',
              'plain.txt',
            ),
          ).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
        await expectLater(
          File(
            p.join(
              xdgConfigHome,
              'dotweave',
              'sync',
              'default',
              'bundle',
              'token.txt${AppConstants.sync.secretArtifactSuffix}',
            ),
          ).readAsString(),
          throwsA(isA<PathNotFoundException>()),
        );
      },
    );

    test('does not repair managed secret artifact ignore rules during push '
        'dry-run', () async {
      final workspace = await createWorkspace('dotweave-dry-run-');
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final secretDirectory = p.join(homeDirectory, '.vivident');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(secretDirectory).create(recursive: true);
      await File(p.join(secretDirectory, 'config.json')).writeAsString('{}\n');

      setEnvironment(homeDirectory, xdgConfigHome);
      await initializeSyncDirectory(
        InitRequest(recipients: [ageKeys.recipient]),
      );
      await File(
        p.join(xdgConfigHome, 'dotweave', 'repository', '.gitignore'),
      ).writeAsString('*.dotweave.secret\n');
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('secret'),
          target: secretDirectory,
        ),
        homeDirectory,
      );

      final result = await pushChanges(const PushRequest(dryRun: true));

      expect(result.dryRun, isTrue);
      expect(
        await File(
          p.join(xdgConfigHome, 'dotweave', 'repository', '.gitignore'),
        ).readAsString(),
        '*.dotweave.secret\n',
      );
    });

    test('reports pull changes without mutating local files', () async {
      final workspace = await createWorkspace('dotweave-dry-run-');
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final bundleDirectory = p.join(homeDirectory, 'bundle');
      final plainFile = p.join(bundleDirectory, 'plain.txt');
      final extraFile = p.join(bundleDirectory, 'extra.txt');
      final ageKeys = await createAgeKeyPair();
      final cwd = homeDirectory;

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(bundleDirectory).create(recursive: true);
      await File(plainFile).writeAsString('plain\n');

      setEnvironment(homeDirectory, xdgConfigHome);
      await initializeSyncDirectory(
        InitRequest(recipients: [ageKeys.recipient]),
      );
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: bundleDirectory,
        ),
        cwd,
      );
      await pushChanges(const PushRequest(dryRun: false));

      await File(plainFile).writeAsString('changed locally\n');
      await File(extraFile).writeAsString('leave me\n');

      final result = await pullChanges(const PullRequest(dryRun: true));

      expect(result.dryRun, isTrue);
      expect(result.plainFileCount, 1);
      expect(result.deletedLocalCount, greaterThanOrEqualTo(1));
      expect(await File(plainFile).readAsString(), 'changed locally\n');
      expect(await File(extraFile).readAsString(), 'leave me\n');
    });

    test('reports status planning progress', () async {
      final workspace = await createWorkspace('dotweave-dry-run-');
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final bundleDirectory = p.join(homeDirectory, 'bundle');
      final plainFile = p.join(bundleDirectory, 'plain.txt');
      final ageKeys = await createAgeKeyPair();
      final cwd = homeDirectory;

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      await Directory(bundleDirectory).create(recursive: true);
      await File(plainFile).writeAsString('plain\n');

      setEnvironment(homeDirectory, xdgConfigHome);
      await initializeSyncDirectory(
        InitRequest(recipients: [ageKeys.recipient]),
      );
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: bundleDirectory,
        ),
        cwd,
      );
      final result = await getStatus();

      expect(result.entryCount, 1);
    });
  });
}
