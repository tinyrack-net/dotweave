// Dart port of `packages/cli/tests/cli.e2e.test.ts`.
//
// The suite-local `runCli` (used by the "CLI e2e" group) spawns the compiled
// executable with only the minimal pass-through environment, mirroring the TS
// helper that spawns node against `src/index.ts` without env overrides. The
// file-level beforeEach/afterEach hooks apply to every test in the file, as
// they do in vitest.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dotweave/src/cli/root_commands.dart';
import 'package:dotweave/src/util/version.g.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

Future<CliRunResult> _runCli(
  List<String> args, {
  Map<String, String>? env,
  bool reject = true,
}) async {
  final result = await runCompiledCli(args, env: env);

  if (reject && result.exitCode != 0) {
    throw CliRunException(args, result);
  }

  return result;
}

void main() {
  group('CLI e2e', () {
    test('shows the version from the real entrypoint', () async {
      final result = await _runCli(['--version']);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('dotweave/$packageVersion'));
      expect(result.stderr, '');
    });

    test('shows root help with the new command surface', () async {
      final result = await _runCli([]);

      expect(result.exitCode, 0);
      expect(result.stderr, '');

      final rootCommandNames = ['autocomplete', ...rootCommandRoutes.keys];
      for (final commandName in rootCommandNames) {
        expect(result.stdout, contains(commandName));
      }

      expect(result.stdout, contains('Launch a shell in the sync directory'));
    });

    test('shows help for cd, track, and profile use commands', () async {
      final results = await Future.wait([
        _runCli(['cd', '--help']),
        _runCli(['track', '--help']),
        _runCli(['profile', 'use', '--help']),
      ]);
      final cdHelp = results[0];
      final trackHelp = results[1];
      final profileHelp = results[2];

      expect(cdHelp.stdout, contains('USAGE'));
      expect(cdHelp.stdout, contains('Launch a child shell rooted'));

      expect(trackHelp.stdout, contains('USAGE'));
      expect(trackHelp.stdout, contains('--mode'));
      expect(trackHelp.stdout, contains('--profile'));
      expect(trackHelp.stdout, contains('--repo'));

      expect(profileHelp.stdout, contains('Profile name to activate'));
    });

    test('rejects removed --verbose flag', () async {
      final result = await _runCli(['pull', '--verbose'], reject: false);

      expect(result.exitCode & 0xff, 252);
      expect(result.stderr, contains('No flag registered for --verbose'));
    });

    test('returns a non-zero exit code for removed command surfaces', () async {
      final results = await Future.wait([
        _runCli(['add', '~/.gitconfig'], reject: false),
        _runCli(['remove', '~/.gitconfig'], reject: false),
        _runCli(['mode', 'secret', '~/.gitconfig'], reject: false),
        _runCli(['list'], reject: false),
        _runCli(['dir'], reject: false),
      ]);
      final addResult = results[0];
      final removeResult = results[1];
      final modeResult = results[2];
      final listResult = results[3];
      final dirResult = results[4];

      expect(addResult.exitCode, isNot(0));
      expect(addResult.stderr, contains('not found'));
      expect(removeResult.exitCode, isNot(0));
      expect(removeResult.stderr, contains('not found'));
      expect(modeResult.exitCode, isNot(0));
      expect(modeResult.stderr, contains('not found'));
      expect(listResult.exitCode, isNot(0));
      expect(listResult.stderr, contains('not found'));
      expect(dirResult.exitCode, isNot(0));
      expect(dirResult.stderr, contains('not found'));
    });
  });

  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('CLI sync cycle e2e', () {
    test('runs a full init-track-push-pull cycle', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'myapp');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('key = value\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);

      await File(configFile).writeAsString('key = modified\n');
      await ctx.runCli(['pull', '-y']);

      final content = await File(configFile).readAsString();
      expect(content, contains('key = value\n'));
    });

    test('reports status for an initialized repository', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'myapp');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(
        p.join(configDir, 'config.toml'),
      ).writeAsString('key = value\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);

      final result = await ctx.runCli(['status']);

      expect(result.exitCode, 0);
      final out = stripAnsi(result.stdout);
      expect(out, contains('Sync status'));
      expect(out, contains('Push changes'));
      expect(out, contains('Add'));
    });

    test('reports missing git during repository import without blaming '
        'reachability', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      final keyFile = await ctx.writeIdentityFile(ageKeys.identity);

      final result = await ctx.runCli(
        ['init', 'https://example.invalid/dotfiles.git', '--key-file', keyFile],
        env: {'PATH': '', 'Path': ''},
        reject: false,
      );
      final stderr = stripAnsi(result.stderr);

      expect(result.exitCode, 1);
      expect(stderr, contains('Git is not installed or not on PATH.'));
      expect(
        stderr,
        contains(
          'Install Git and ensure the git executable is available on PATH',
        ),
      );
      expect(stderr, isNot(contains('repository source is reachable')));
    });
  });
}
