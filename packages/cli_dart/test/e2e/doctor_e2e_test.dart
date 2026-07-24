// Dart port of `packages/cli/tests/doctor.e2e.test.ts`.

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

  group('doctor CLI e2e', () {
    test('reports git repository failure before init', () async {
      final result = await ctx.runCli(['doctor'], reject: false);

      expect(result.exitCode, 1);
      expect(stripAnsi(result.stdout), contains('Doctor found issues'));
    });

    test('reports warnings after init with no tracked entries', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);
      await ctx.runCli(['init']);

      final result = await ctx.runCli(['doctor']);

      expect(result.exitCode, 0);
      // The warning summary goes to stderr; the warning icon lines go to
      // stdout
      expect(
        stripAnsi(result.stderr),
        contains('Doctor completed with warnings'),
      );
      expect(stripAnsi(result.stdout), contains('entries'));
    });

    test(
      'passes after init with a tracked entry that exists locally',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'myapp');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('key = value\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);

        final result = await ctx.runCli(['doctor']);

        expect(result.exitCode, 0);
        expect(stripAnsi(result.stdout), contains('Doctor passed'));
      },
    );

    test('does not warn when a tracked path is missing locally but absent '
        'from the current sync state', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'myapp');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('key = value\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configFile]);
      await File(configFile).delete();

      final result = await ctx.runCli(['doctor']);
      final out = stripAnsi(result.stdout);
      final err = stripAnsi(result.stderr);

      expect(result.exitCode, 0);
      expect(err, isNot(contains('Doctor completed with warnings')));
      expect(out, contains('Doctor passed'));
      expect(out, isNot(contains('local – 1 tracked local path is missing')));
    });
  });
}
