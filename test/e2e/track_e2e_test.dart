// Dart port of `tests/track.e2e.test.ts`.
//
// `toMatchObject` on manifest entries becomes per-key `containsPair` subset
// checks (nested override maps are compared exactly, matching what the track
// command writes).

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

void main() {
  late SyncE2EContext ctx;

  Future<List<Map<String, Object?>>> readManifestEntries() async {
    return parseManifestEntries(
      await File(
        p.join(ctx.xdgDir, 'dotweave', 'repository', 'manifest.jsonc'),
      ).readAsString(),
    );
  }

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('track CLI manifest e2e', () {
    test('tracks an existing file with secret mode and permission', () async {
      final sshDirectory = p.join(ctx.homeDir, '.ssh');
      final configFile = p.join(sshDirectory, 'config');

      await Directory(sshDirectory).create(recursive: true);
      await File(
        configFile,
      ).writeAsString('Host example\n  HostName example.com\n');

      await ctx.runCli(['init']);
      await ctx.runCli([
        'track',
        '~/.ssh/config',
        '--mode',
        'secret',
        '--permission',
        '0600',
      ]);

      final entries = await readManifestEntries();

      expect(entries, hasLength(1));
      expect(entries[0], containsPair('kind', 'file'));
      expect(
        entries[0],
        containsPair('localPath', {'default': '~/.ssh/config'}),
      );
      expect(entries[0], containsPair('mode', {'default': 'secret'}));
      expect(entries[0], containsPair('permission', {'default': '0600'}));
    });

    test('tracks a missing file when kind is explicit', () async {
      await ctx.runCli(['init']);
      await ctx.runCli([
        'track',
        '~/.config/future.toml',
        '--kind',
        'file',
        '--mode',
        'normal',
      ]);

      final entries = await readManifestEntries();

      expect(entries, hasLength(1));
      expect(entries[0], containsPair('kind', 'file'));
      expect(
        entries[0],
        containsPair('localPath', {'default': '~/.config/future.toml'}),
      );
      expect(entries[0], containsPair('mode', {'default': 'normal'}));
    });

    test(
      'fails with a hint when tracking a missing target without kind',
      () async {
        await ctx.runCli(['init']);

        final result = await ctx.runCli([
          'track',
          '~/.config/future.toml',
        ], reject: false);

        expect(result.exitCode, isNot(0));
        expect(
          stripAnsi(result.stderr),
          contains('Pass --kind file or --kind directory'),
        );
      },
    );

    test(
      'writes platform overrides for local path, repo path, and mode',
      () async {
        await ctx.runCli(['init']);
        await ctx.runCli([
          'track',
          '~/.config/tool',
          '--kind',
          'directory',
          '--local',
          'win=%APPDATA%/Tool',
          '--repo',
          '.config/tool',
          '--repo',
          'win=AppData/Roaming/Tool',
          '--mode',
          'normal',
          '--mode',
          'win=ignore',
        ]);

        final entries = await readManifestEntries();

        expect(entries, hasLength(1));
        expect(entries[0], containsPair('kind', 'directory'));
        expect(
          entries[0],
          containsPair('localPath', {
            'default': '~/.config/tool',
            'win': '%APPDATA%/Tool',
          }),
        );
        expect(
          entries[0],
          containsPair('mode', {'default': 'normal', 'win': 'ignore'}),
        );
        expect(
          entries[0],
          containsPair('repoPath', {
            'default': '.config/tool',
            'win': 'AppData/Roaming/Tool',
          }),
        );
      },
    );

    test('rejects removed --repo-path flag', () async {
      final result = await ctx.runCli([
        'track',
        '~/.gitconfig',
        '--repo-path',
        '.gitconfig',
      ], reject: false);

      expect(result.exitCode, isNot(0));
      expect(
        stripAnsi(result.stderr),
        contains('No flag registered for --repo-path'),
      );
    });
  });
}
