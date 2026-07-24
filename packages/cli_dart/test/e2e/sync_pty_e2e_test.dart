// Dart port of the seven `itWithPty` tests in
// `packages/cli/tests/sync.e2e.test.ts` (the interactive-prompt flows that
// need a real pseudo-terminal).
//
// node-pty is replaced by the POSIX `script`-utility wrapper in
// `test/helpers/pty.dart`, which does not exist on Windows: every test body
// therefore starts with `if (Platform.isWindows) return;` (the TS
// `supportsPtyE2E` / `it.skipIf` gate). The AOT-compiled e2e binary is
// spawned inside the pty directly instead of `node <cliNodeOptions>
// src/index.ts`, with `ctx.baseEnv` layered over the parent environment.
// The TS 10s `waitFor` deadlines are kept as-is.

@Tags(['pty'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dotweave/src/config/sync_schema.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/pty.dart';

void main() {
  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('sync CLI e2e', () {
    test('fails when importing an existing repository without supplying an age '
        'key', () async {
      if (Platform.isWindows) {
        return;
      }

      final sourceRepository = p.join(ctx.workspace, 'remote-sync');

      await ctx.runGit(['init', '-b', 'main', sourceRepository]);
      final session = await startPtySession(
        args: ['init', sourceRepository],
        cwd: ctx.workspace,
        env: ctx.baseEnv,
        file: await resolveE2eBinary(),
      );

      try {
        await session.waitFor(
          'Enter the age private key for the existing repository',
          const Duration(seconds: 10),
        );
        session.write('\r');

        final output = await session.waitFor(
          "Provide your existing age private key with '--key-file'",
          const Duration(seconds: 10),
        );

        expect(
          output,
          contains('Existing repository setup requires an age private key'),
        );
      } finally {
        session.close();
      }
    });

    test(
      'does not warn about an existing config when cloning a repository with '
      'an existing manifest and entering the key interactively',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final sourceRepository = p.join(ctx.workspace, 'remote-sync');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.runGit(['init', '-b', 'main', sourceRepository]);
        await File(p.join(sourceRepository, 'manifest.jsonc')).writeAsString(
          formatSyncConfig(
            createInitialSyncConfig(AgeConfig(recipients: [ageKeys.recipient])),
          ),
        );
        await ctx.runGit(['add', 'manifest.jsonc'], sourceRepository);
        await ctx.runGit([
          'commit',
          '-m',
          'initial manifest',
          '--author',
          'test <test@test.com>',
        ], sourceRepository);

        final session = await startPtySession(
          args: ['init', sourceRepository],
          cwd: ctx.workspace,
          env: ctx.baseEnv,
          file: await resolveE2eBinary(),
        );

        try {
          await session.waitFor(
            'Enter the age private key for the existing repository',
            const Duration(seconds: 10),
          );
          session.write('${ageKeys.identity}\r');

          final output = await session.waitFor(
            'Sync directory initialized',
            const Duration(seconds: 10),
          );

          expect(output, isNot(contains('Sync directory already initialized')));
        } finally {
          session.close();
        }
      },
    );

    test('fails when an empty key is entered interactively for an existing '
        'repository', () async {
      if (Platform.isWindows) {
        return;
      }

      final sourceRepository = p.join(ctx.workspace, 'remote-sync');

      await ctx.runGit(['init', '-b', 'main', sourceRepository]);

      final session = await startPtySession(
        args: ['init', sourceRepository],
        cwd: ctx.workspace,
        env: ctx.baseEnv,
        file: await resolveE2eBinary(),
      );

      try {
        await session.waitFor(
          'Enter the age private key for the existing repository',
          const Duration(seconds: 10),
        );
        session.write('\r');

        final output = await session.waitFor(
          "Provide your existing age private key with '--key-file'",
          const Duration(seconds: 10),
        );

        expect(
          output,
          contains('Existing repository setup requires an age private key'),
        );
      } finally {
        session.close();
      }
    });

    test('cancels pull interactively unless y is entered', () async {
      if (Platform.isWindows) {
        return;
      }

      final configDir = p.join(ctx.homeDir, '.config', 'interactive-pull');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('version = 1\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);
      await File(configFile).writeAsString('version = 2\n');

      final session = await startPtySession(
        args: ['pull'],
        cwd: ctx.workspace,
        env: ctx.baseEnv,
        file: await resolveE2eBinary(),
      );

      try {
        final output = await session.waitFor(
          'Apply these changes? [y/N]',
          const Duration(seconds: 10),
        );

        expect(output, contains(configFile));
        session.write('n\r');

        final cancelledOutput = await session.waitFor(
          'Skipped pull changes',
          const Duration(seconds: 10),
        );

        expect(cancelledOutput, contains(configFile));
        expect(await File(configFile).readAsString(), contains('version = 2'));
      } finally {
        session.close();
      }
    });

    test('cancels pull interactively when empty input is entered', () async {
      if (Platform.isWindows) {
        return;
      }

      final configDir = p.join(ctx.homeDir, '.config', 'interactive-empty');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('version = 1\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);
      await File(configFile).writeAsString('version = 2\n');

      final session = await startPtySession(
        args: ['pull'],
        cwd: ctx.workspace,
        env: ctx.baseEnv,
        file: await resolveE2eBinary(),
      );

      try {
        final output = await session.waitFor(
          'Apply these changes? [y/N]',
          const Duration(seconds: 10),
        );

        expect(output, contains(configFile));
        session.write('\r');

        final cancelledOutput = await session.waitFor(
          'Skipped pull changes',
          const Duration(seconds: 10),
        );

        expect(cancelledOutput, contains(configFile));
        expect(await File(configFile).readAsString(), contains('version = 2'));
      } finally {
        session.close();
      }
    });

    test('applies pull interactively when y is entered', () async {
      if (Platform.isWindows) {
        return;
      }

      final configDir = p.join(ctx.homeDir, '.config', 'interactive-accept');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('version = 1\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);
      await File(configFile).writeAsString('version = 2\n');

      final session = await startPtySession(
        args: ['pull'],
        cwd: ctx.workspace,
        env: ctx.baseEnv,
        file: await resolveE2eBinary(),
      );

      try {
        final output = await session.waitFor(
          'Apply these changes? [y/N]',
          const Duration(seconds: 10),
        );

        expect(output, contains(configFile));
        session.write('y\r');

        final appliedOutput = await session.waitFor(
          'Pull complete',
          const Duration(seconds: 10),
        );

        expect(appliedOutput, contains(configFile));
        expect(await File(configFile).readAsString(), contains('version = 1'));
      } finally {
        session.close();
      }
    });

    test('applies pull interactively when uppercase Y is entered', () async {
      if (Platform.isWindows) {
        return;
      }

      final configDir = p.join(ctx.homeDir, '.config', 'interactive-uppercase');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('version = 1\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);
      await File(configFile).writeAsString('version = 2\n');

      final session = await startPtySession(
        args: ['pull'],
        cwd: ctx.workspace,
        env: ctx.baseEnv,
        file: await resolveE2eBinary(),
      );

      try {
        final output = await session.waitFor(
          'Apply these changes? [y/N]',
          const Duration(seconds: 10),
        );

        expect(output, contains(configFile));
        session.write('Y\r');

        final appliedOutput = await session.waitFor(
          'Pull complete',
          const Duration(seconds: 10),
        );

        expect(appliedOutput, contains(configFile));
        expect(await File(configFile).readAsString(), contains('version = 1'));
      } finally {
        session.close();
      }
    });
  });
}
