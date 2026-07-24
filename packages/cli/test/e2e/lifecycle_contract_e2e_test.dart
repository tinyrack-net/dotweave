// Dart port of `packages/cli/tests/lifecycle-contract.e2e.test.ts`.
//
// `await expect(readRepositoryArtifact(...)).rejects.toThrow()` becomes
// `expectLater(..., throwsA(isA<FileSystemException>()))` (the artifact file
// must not exist), and `resolves.toBe(...)` becomes awaiting the read and
// comparing directly.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

void main() {
  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('lifecycle contract e2e', () {
    test('locks normal, secret, ignore, dry-run, pull, and idempotency '
        'behavior', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'lifecycle');
      final cacheDir = p.join(configDir, 'cache');
      final publicFile = p.join(configDir, 'public.toml');
      final secretFile = p.join(configDir, 'secrets.env');
      final ignoredFile = p.join(cacheDir, 'state.txt');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(cacheDir).create(recursive: true);
      await File(publicFile).writeAsString('theme = light\n');
      await File(secretFile).writeAsString('TOKEN=initial\n');
      await File(ignoredFile).writeAsString('cache = initial\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['track', secretFile, '--mode', 'secret']);
      await ctx.runCli(['track', ignoredFile, '--mode', 'ignore']);

      final statusBeforePush = await ctx.runCli(['status']);
      expect(stripAnsi(statusBeforePush.stdout), contains('Push changes'));
      expect(stripAnsi(statusBeforePush.stdout), contains('Add'));

      final dryPush = await ctx.runCli(['push', '--dry-run']);
      expect(stripAnsi(dryPush.stdout), contains('Push preview'));
      await expectLater(
        readRepositoryArtifact(
          ctx.xdgDir,
          'default',
          '.config/lifecycle/public.toml',
        ),
        throwsA(isA<FileSystemException>()),
      );

      await ctx.runCli(['push']);

      expect(
        await readRepositoryArtifact(
          ctx.xdgDir,
          'default',
          '.config/lifecycle/public.toml',
        ),
        'theme = light\n',
      );
      expect(
        await readRepositoryArtifact(
          ctx.xdgDir,
          'default',
          '.config/lifecycle/secrets.env.dotweave.secret',
        ),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );
      await expectLater(
        readRepositoryArtifact(
          ctx.xdgDir,
          'default',
          '.config/lifecycle/cache/state.txt',
        ),
        throwsA(isA<FileSystemException>()),
      );

      final noOpPush = await ctx.runCli(['push']);
      expect(stripAnsi(noOpPush.stdout), contains('Push complete'));
      expect(stripAnsi(noOpPush.stdout), contains('plain: 1'));
      expect(stripAnsi(noOpPush.stdout), contains('encrypted: 1'));

      await File(publicFile).writeAsString('theme = dark\n');
      await File(secretFile).writeAsString('TOKEN=local\n');
      await File(ignoredFile).writeAsString('cache = local\n');

      final dryPull = await ctx.runCli(['pull', '--dry-run']);
      expect(stripAnsi(dryPull.stdout), contains('Pull preview'));
      expect(await File(publicFile).readAsString(), 'theme = dark\n');
      expect(await File(secretFile).readAsString(), 'TOKEN=local\n');

      await ctx.runCli(['pull', '-y']);

      expect(await File(publicFile).readAsString(), 'theme = light\n');
      expect(await File(secretFile).readAsString(), 'TOKEN=initial\n');
      expect(await File(ignoredFile).readAsString(), 'cache = local\n');

      final statusAfterPull = await ctx.runCli(['status']);
      final statusOutput = stripAnsi(statusAfterPull.stdout);
      expect(statusOutput, contains('No push changes'));
      expect(statusOutput, contains('No pull changes'));
    });

    test('restores a normal and secret profile from a bare repository on a '
        'second machine', () async {
      final remoteRepository = p.join(ctx.workspace, 'remote.git');
      final keyFile = p.join(ctx.workspace, 'identity.agekey');
      final configDir = p.join(ctx.homeDir, '.config', 'portable');
      final publicFile = p.join(configDir, 'settings.toml');
      final secretFile = p.join(configDir, 'token.env');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.runGit(['init', '--bare', '-b', 'main', remoteRepository]);
      await ctx.writeIdentityFile(ageKeys.identity);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');
      await Directory(configDir).create(recursive: true);
      await File(publicFile).writeAsString('editor = vim\n');
      await File(secretFile).writeAsString('TOKEN=portable\n');

      await ctx.runCli(['init', remoteRepository]);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['track', secretFile, '--mode', 'secret']);
      await ctx.runCli(['push']);

      final syncDirectory = p.join(ctx.xdgDir, 'dotweave', 'repository');
      await ctx.runGit(['add', '.'], syncDirectory);
      await ctx.runGit(['commit', '-m', 'seed portable config'], syncDirectory);
      await ctx.runGit(['push', '-u', 'origin', 'main'], syncDirectory);

      final second = createMachineEnv(ctx.workspace, 'second', ctx.baseEnv);

      await Directory(second.homeDir).create(recursive: true);
      await ctx.runCli([
        'init',
        remoteRepository,
        '--key-file',
        keyFile,
      ], env: second.env);
      await ctx.runCli(['pull', '-y'], env: second.env);

      expect(
        await File(
          p.join(second.homeDir, '.config', 'portable', 'settings.toml'),
        ).readAsString(),
        'editor = vim\n',
      );
      expect(
        await File(
          p.join(second.homeDir, '.config', 'portable', 'token.env'),
        ).readAsString(),
        'TOKEN=portable\n',
      );
    });
  });
}
