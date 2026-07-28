// Dart port of `tests/status.e2e.test.ts`.

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

  group('status CLI e2e', () {
    test(
      'reports zero pending changes after init with no tracked entries',
      () async {
        final ageKeys = await ctx.createAgeKeyPair();
        await ctx.writeIdentityFile(ageKeys.identity);
        await ctx.runCli(['init']);

        final result = await ctx.runCli(['status']);

        expect(result.exitCode, 0);
        final out = stripAnsi(result.stdout);
        expect(out, contains('Sync status'));
        expect(out, contains('0 entries'));
        expect(out, contains('Push changes'));
        expect(out, contains('No push changes'));
        expect(out, contains('Pull changes'));
        expect(out, contains('No pull changes'));
      },
    );

    test('reports files pending push after track and before push', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'myapp');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('key = value\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);

      final result = await ctx.runCli(['status']);

      expect(result.exitCode, 0);
      final out = stripAnsi(result.stdout);
      expect(out, contains('Sync status'));
      expect(out, contains('1 entries'));
      // Files to push to repository
      expect(out, contains('Push changes'));
      expect(out, contains('Add'));
      // Pull would remove local files that don't exist in repo yet
      expect(out, contains('Pull changes'));
      expect(out, contains('Remove'));
    });

    test(
      'reports files pending pull after push and local modification',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'myapp');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('key = original\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);
        await ctx.runCli(['push']);

        // Overwrite local file to simulate a diverged local state
        await File(configFile).writeAsString('key = modified\n');

        final result = await ctx.runCli(['status']);

        expect(result.exitCode, 0);
        final out = stripAnsi(result.stdout);
        expect(out, contains('Sync status'));
        // Repository still has original; pull would restore it
        expect(out, contains('Pull changes'));
        expect(out, contains('Changed'));
      },
    );

    test(
      'reports no push changes after syncing local files to the repository',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'myapp');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('key = value\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);
        await ctx.runCli(['push']);

        final result = await ctx.runCli(['status']);

        expect(result.exitCode, 0);
        final out = stripAnsi(result.stdout);
        expect(out, contains('Push changes'));
        expect(out, contains('No push changes'));
      },
    );

    test('reports push and pull changes for tracked entries', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'myapp');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('key = value\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);

      final repoArtifact = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'myapp',
        'config.toml',
      );
      await File(repoArtifact).writeAsString('key = repo-modified\n');

      final result = await ctx.runCli(['status']);

      expect(result.exitCode, 0);
      final out = stripAnsi(result.stdout);
      expect(out, contains('Pull changes'));
      expect(out, contains('Changed'));
    });

    test('reports no changes when repository is up to date', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'myapp');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('key = value\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);
      await ctx.runCli(['pull']);

      final result = await ctx.runCli(['status']);

      expect(result.exitCode, 0);
      final out = stripAnsi(result.stdout);
      expect(out, contains('Push changes'));
      expect(out, contains('No push changes'));
      expect(out, contains('Pull changes'));
      expect(out, contains('No pull changes'));
    });
  });
}
