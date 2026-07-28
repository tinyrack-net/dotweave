// Dart port of `tests/sync.e2e.test.ts` (part B: the `it`
// blocks from "previews push changes without writing artifacts when
// --dry-run is used" through the end of the file).
//
// The TS `itWithPty` tests in this range drive a real pseudo-terminal via
// `createPtySession` so the CLI takes the interactive confirmation path
// (`Apply these changes? [y/N]`); their Dart ports live in
// `sync_pty_e2e_test.dart` (tagged `pty`, built on `test/helpers/pty.dart`).

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

/// Mirror of the TS `formatSyncConfig({ ...createInitialSyncConfig({
/// recipients }), entries })` spread.
String formatManifestWithEntries(
  String recipient,
  List<SyncConfigEntry> entries,
) {
  final initial = createInitialSyncConfig(AgeConfig(recipients: [recipient]));

  return formatSyncConfig(
    RawSyncConfig(
      version: initial.version,
      repositoryFormat: initial.repositoryFormat,
      age: initial.age,
      profiles: initial.profiles,
      entries: entries,
    ),
  );
}

/// Mirror of the TS `chmod(path, mode)` (POSIX-only tests).
Future<void> chmod(String path, String mode) async {
  final result = await Process.run('chmod', [mode, path], runInShell: false);

  if (result.exitCode != 0) {
    throw Exception('chmod $mode $path failed: ${result.stderr}');
  }
}

void main() {
  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('sync CLI e2e', () {
    test(
      'previews push changes without writing artifacts when --dry-run is used',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'dryapp');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('mode = dry\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);

        final result = await ctx.runCli(['push', '--dry-run']);

        expect(result.exitCode, 0);
        expect(stripAnsi(result.stdout), contains('Push preview'));
        expect(stripAnsi(result.stdout), contains('dry run'));

        // The artifact should NOT have been written to the repository
        final artifact = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'dryapp',
          'config.toml',
        );
        expectPathAbsent(artifact);
      },
    );

    test('previews pull changes without overwriting local files when --dry-run '
        'is used', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'pullapp');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('version = 1\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);

      // Modify the local file so it diverges from the repository
      await File(configFile).writeAsString('version = 2\n');

      final result = await ctx.runCli(['pull', '--dry-run']);

      expect(result.exitCode, 0);
      expect(stripAnsi(result.stdout), contains('Pull preview'));
      expect(stripAnsi(result.stdout), contains('dry run'));

      // Local file should still have the modified content
      expect(await File(configFile).readAsString(), contains('version = 2'));
    });

    test(
      'prints that there are no pull changes and exits without prompting',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'steadyapp');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('version = 1\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);
        await ctx.runCli(['push']);

        final result = await ctx.runCli(['pull']);

        expect(result.exitCode, 0);
        expect(stripAnsi(result.stdout), contains('Already up to date'));
      },
    );

    test('ignores repository artifact permission noise when content and '
        'executable intent match', () async {
      if (Platform.isWindows) {
        return;
      }

      final configDir = p.join(ctx.homeDir, '.config', 'permission-noise');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('version = 1\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);

      final artifactFile = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'permission-noise',
        'config.toml',
      );

      await chmod(artifactFile, '600');

      final status = await ctx.runCli(['status']);
      final statusOutput = stripAnsi(status.stdout);

      expect(statusOutput, contains('No push changes'));
      expect(statusOutput, contains('No pull changes'));

      final pull = await ctx.runCli(['pull']);

      expect(stripAnsi(pull.stdout), contains('Already up to date'));
    });

    test('reports local drift from explicit manifest permission', () async {
      if (Platform.isWindows) {
        return;
      }

      final keyFile = p.join(ctx.homeDir, '.ssh', 'id_rsa');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(p.join(ctx.homeDir, '.ssh')).create(recursive: true);
      await File(keyFile).writeAsString('key\n');
      await chmod(keyFile, '600');

      await ctx.runCli(['init']);
      await File(
        p.join(ctx.xdgDir, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        formatManifestWithEntries(ageKeys.recipient, const [
          SyncConfigEntry(
            kind: 'file',
            localPath: PlatformStringValue(defaultValue: '~/.ssh/id_rsa'),
            mode: PlatformSyncMode(defaultValue: 'normal'),
            permission: PlatformPermission(defaultValue: '0600'),
          ),
        ]),
      );
      await ctx.runCli(['push']);
      await chmod(keyFile, '644');

      final status = await ctx.runCli(['status']);
      final pullPreview = await ctx.runCli(['pull', '--dry-run']);

      expect(stripAnsi(status.stdout), contains('No push changes'));
      expect(stripAnsi(status.stdout), contains('Changed (1)'));
      expect(stripAnsi(pullPreview.stdout), contains('Planned pull changes'));
      expect(stripAnsi(pullPreview.stdout), contains(keyFile));
    });

    test(
      'treats opposite Windows text line endings as unchanged during pull',
      () async {
        if (!Platform.isWindows) {
          return;
        }

        final sourceRepository = p.join(ctx.workspace, 'remote-sync');
        final keyFile = p.join(ctx.workspace, 'line-endings-clean.agekey');
        final configDir = p.join(ctx.homeDir, '.config', 'line-endings-clean');
        final configFile = p.join(configDir, 'config.toml');
        final reverseFile = p.join(configDir, 'reverse.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await Directory(
          p.join(
            sourceRepository,
            'profiles',
            'default',
            '.config',
            'line-endings-clean',
          ),
        ).create(recursive: true);
        await Directory(configDir).create(recursive: true);
        await File(p.join(sourceRepository, 'manifest.jsonc')).writeAsString(
          formatManifestWithEntries(ageKeys.recipient, const [
            SyncConfigEntry(
              kind: 'directory',
              localPath: PlatformStringValue(
                defaultValue: '~/.config/line-endings-clean',
              ),
              mode: PlatformSyncMode(defaultValue: 'normal'),
            ),
          ]),
        );
        await File(
          p.join(
            sourceRepository,
            'profiles',
            'default',
            '.config',
            'line-endings-clean',
            'config.toml',
          ),
        ).writeAsString('version = 1\r\nname = test\r\n');
        await File(
          p.join(
            sourceRepository,
            'profiles',
            'default',
            '.config',
            'line-endings-clean',
            'reverse.toml',
          ),
        ).writeAsString('version = 1\nname = test\n');
        await File(configFile).writeAsString('version = 1\nname = test\n');
        await File(reverseFile).writeAsString('version = 1\r\nname = test\r\n');
        await ctx.runGit(['init', '-b', 'main'], sourceRepository);
        await ctx.runGit(['add', '.'], sourceRepository);
        await ctx.runGit([
          'commit',
          '-m',
          'seed normalized line endings',
        ], sourceRepository);
        await File(keyFile).writeAsString('${ageKeys.identity}\n');

        await ctx.runCli(['init', sourceRepository, '--key-file', keyFile]);
        final result = await ctx.runCli(['pull']);

        expect(result.exitCode, 0);
        expect(stripAnsi(result.stdout), contains('Already up to date'));
        expect(
          stripAnsi(result.stdout),
          isNot(contains('Planned pull changes')),
        );
      },
    );

    test('normalizes Windows text line endings without hiding BOM changes '
        'during pull', () async {
      if (!Platform.isWindows) {
        return;
      }

      final sourceRepository = p.join(ctx.workspace, 'remote-sync');
      final keyFile = p.join(ctx.workspace, 'line-endings-bom.agekey');
      final configDir = p.join(ctx.homeDir, '.config', 'line-endings-bom');
      final configFile = p.join(configDir, 'config.toml');
      final bomFile = p.join(configDir, 'bom.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await Directory(
        p.join(
          sourceRepository,
          'profiles',
          'default',
          '.config',
          'line-endings-bom',
        ),
      ).create(recursive: true);
      await Directory(configDir).create(recursive: true);
      await File(p.join(sourceRepository, 'manifest.jsonc')).writeAsString(
        formatManifestWithEntries(ageKeys.recipient, const [
          SyncConfigEntry(
            kind: 'directory',
            localPath: PlatformStringValue(
              defaultValue: '~/.config/line-endings-bom',
            ),
            mode: PlatformSyncMode(defaultValue: 'normal'),
          ),
        ]),
      );
      await File(
        p.join(
          sourceRepository,
          'profiles',
          'default',
          '.config',
          'line-endings-bom',
          'config.toml',
        ),
      ).writeAsString('version = 1\r\nname = test\r\n');
      await File(
        p.join(
          sourceRepository,
          'profiles',
          'default',
          '.config',
          'line-endings-bom',
          'bom.toml',
        ),
        // U+FEFF BOM prefix, mirroring the TS test fixture.
      ).writeAsString('\u{FEFF}version = 1\r\n');
      await File(configFile).writeAsString('version = 1\nname = test\n');
      await File(bomFile).writeAsString('version = 1\n');
      await ctx.runGit(['init', '-b', 'main'], sourceRepository);
      await ctx.runGit(['add', '.'], sourceRepository);
      await ctx.runGit([
        'commit',
        '-m',
        'seed normalized line endings',
      ], sourceRepository);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');

      await ctx.runCli(['init', sourceRepository, '--key-file', keyFile]);
      final result = await ctx.runCli(['pull'], reject: false);

      expect(result.exitCode, isNot(0));
      expect(stripAnsi(result.stdout), contains('Planned pull changes'));
      expect(stripAnsi(result.stdout), contains('bom.toml'));
      expect(stripAnsi(result.stdout), isNot(contains('config.toml')));
    });

    test(
      'fails in non-interactive mode without -y when pull changes exist',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'noninteractive-pull');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('version = 1\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);
        await ctx.runCli(['push']);
        await File(configFile).writeAsString('version = 2\n');

        final result = await ctx.runCli(['pull'], reject: false);

        expect(result.exitCode, isNot(0));
        expect(
          stripAnsi(result.stderr),
          contains('Pull confirmation requires an interactive terminal.'),
        );
        expect(stripAnsi(result.stderr), contains('dotweave pull -y'));
        expect(await File(configFile).readAsString(), contains('version = 2'));
      },
    );

    test('returns a non-zero exit code when pushing without init', () async {
      final result = await ctx.runCli(['push'], reject: false);

      expect(result.exitCode, isNot(0));
      expect(stripAnsi(result.stderr), isNot(''));
    });

    test('returns a non-zero exit code when pulling without init', () async {
      final result = await ctx.runCli(['pull'], reject: false);

      expect(result.exitCode, isNot(0));
      expect(stripAnsi(result.stderr), isNot(''));
    });

    test(
      'deletes local files that were removed from repository during pull',
      () async {
        final appDirectory = p.join(ctx.homeDir, '.config', 'testapp');
        final configFile = p.join(appDirectory, 'config.yaml');
        final dataFile = p.join(appDirectory, 'data.json');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(appDirectory).create(recursive: true);
        await File(configFile).writeAsString('setting: value\n');
        await File(dataFile).writeAsString('{"data": true}\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', appDirectory]);
        await ctx.runCli(['push']);

        final repoConfigFile = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'testapp',
          'config.yaml',
        );
        final repoDataFile = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'testapp',
          'data.json',
        );

        expect(
          await File(repoConfigFile).readAsString(),
          contains('setting: value'),
        );
        expect(
          await File(repoDataFile).readAsString(),
          contains('"data": true'),
        );

        await File(repoDataFile).delete();

        final result = await ctx.runCli(['pull', '-y']);

        expect(result.exitCode, 0);
        expect(stripAnsi(result.stdout), contains('remove'));
        expect(
          await File(configFile).readAsString(),
          contains('setting: value'),
        );
        expectPathAbsent(dataFile);
      },
    );

    test(
      'deletes multiple local files when they are removed from repository',
      () async {
        final notesDirectory = p.join(ctx.homeDir, '.config', 'notes');
        final note1 = p.join(notesDirectory, 'todo.txt');
        final note2 = p.join(notesDirectory, 'ideas.txt');
        final note3 = p.join(notesDirectory, 'reminders.txt');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(notesDirectory).create(recursive: true);
        await File(note1).writeAsString('Buy milk\n');
        await File(note2).writeAsString('New app idea\n');
        await File(note3).writeAsString('Call mom\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', notesDirectory]);
        await ctx.runCli(['push']);

        final repoNote2 = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'notes',
          'ideas.txt',
        );
        final repoNote3 = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'notes',
          'reminders.txt',
        );

        await File(repoNote2).delete();
        await File(repoNote3).delete();

        final result = await ctx.runCli(['pull', '-y']);

        expect(result.exitCode, 0);
        expect(await File(note1).readAsString(), contains('Buy milk'));
        expectPathAbsent(note2);
        expectPathAbsent(note3);
      },
    );

    test(
      'recovers from an interrupted sync that left behind backup files',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'recoveryapp');
        final configFile = p.join(configDir, 'config.json');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('{"version": 1}\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);
        await ctx.runCli(['push']);

        // Simulate an interrupted sync by manually creating a backup file
        final backupFile = p.join(
          configDir,
          '.config.json.dotweave-sync-backup-1234',
        );
        await File(backupFile).writeAsString('{"version": "backup"}\n');

        // Run pull -y, it should still work and ideally clean up stray
        // backup files (replacePathAtomically cleans up backup files in its
        // finally block, but here we are simulating one that stayed because
        // the process was killed)
        final result = await ctx.runCli(['pull', '-y']);

        expect(result.exitCode, 0);
        expect(await File(configFile).readAsString(), contains('"version": 1'));
        // Note: The CLI doesn't currently proactively scan and delete *old*
        // backup files from *previous* runs, but the sync should still
        // succeed.
      },
    );
  });
}
