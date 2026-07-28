// Dart port of `tests/profile.e2e.test.ts`.
//
// `expect(settings.activeProfile).toBeUndefined()` becomes a null check on
// the parsed settings map, and `await expect(readFile(...)).rejects.toThrow()`
// becomes an `expectLater(..., throwsA(isA<FileSystemException>()))` on
// `File.readAsString`.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

void main() {
  late SyncE2EContext ctx;

  Future<({String homeFile, String sharedFile, String workFile})>
  setupProfilePullFixture() async {
    final sharedDir = p.join(ctx.homeDir, '.config', 'shared');
    final workFile = p.join(ctx.homeDir, '.gitconfig-work');
    final homeFile = p.join(ctx.homeDir, '.gitconfig-home');
    final sharedFile = p.join(sharedDir, 'tool.conf');
    final ageKeys = await ctx.createAgeKeyPair();

    await ctx.writeIdentityFile(ageKeys.identity);
    await Directory(sharedDir).create(recursive: true);
    await File(workFile).writeAsString('work = initial\n');
    await File(homeFile).writeAsString('home = initial\n');
    await File(sharedFile).writeAsString('shared = initial\n');

    await ctx.runCli(['init']);
    await ctx.runCli(['profile', 'add', 'work']);
    await ctx.runCli(['profile', 'add', 'home']);
    await ctx.runCli(['track', workFile, '--profile', 'work']);
    await ctx.runCli(['track', homeFile, '--profile', 'home']);
    await ctx.runCli(['track', sharedFile]);
    await ctx.runCli(['push']);
    await ctx.runCli(['push', '--profile', 'work']);
    await ctx.runCli(['push', '--profile', 'home']);

    await File(
      p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'work',
        '.gitconfig-work',
      ),
    ).writeAsString('work = repository\n');
    await File(
      p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'home',
        '.gitconfig-home',
      ),
    ).writeAsString('home = repository\n');
    await File(
      p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'shared',
        'tool.conf',
      ),
    ).writeAsString('shared = repository\n');
    await File(workFile).writeAsString('work = local\n');
    await File(homeFile).writeAsString('home = local\n');
    await File(sharedFile).writeAsString('shared = local\n');

    return (homeFile: homeFile, sharedFile: sharedFile, workFile: workFile);
  }

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('profile CLI e2e', () {
    test(
      'lists the active profile and available profiles after init',
      () async {
        final ageKeys = await ctx.createAgeKeyPair();
        await ctx.writeIdentityFile(ageKeys.identity);
        await ctx.runCli(['init']);

        final result = await ctx.runCli(['profile', 'list']);

        expect(result.exitCode, 0);
        final out = stripAnsi(result.stdout);
        expect(out, contains('Profiles'));
        expect(out, contains('default'));
      },
    );

    test('sets and reads back the active profile via profile use', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);
      await ctx.runCli(['init']);
      await ctx.runCli(['profile', 'add', 'work']);

      final setResult = await ctx.runCli(['profile', 'use', 'work']);

      expect(setResult.exitCode, 0);
      expect(
        stripAnsi(setResult.stdout),
        contains('Active profile set to work'),
      );

      final settings = readSettingsJson(
        await File(
          p.join(ctx.xdgDir, 'dotweave', 'settings.jsonc'),
        ).readAsString(),
      );

      expect(settings['activeProfile'], 'work');
    });

    test(
      'clears the active profile when profile use is called without a name',
      () async {
        final ageKeys = await ctx.createAgeKeyPair();
        await ctx.writeIdentityFile(ageKeys.identity);
        await ctx.runCli(['init']);
        await ctx.runCli(['profile', 'add', 'work']);
        await ctx.runCli(['profile', 'use', 'work']);

        final clearResult = await ctx.runCli(['profile', 'use']);

        expect(clearResult.exitCode, 0);
        expect(
          stripAnsi(clearResult.stdout),
          contains('Active profile cleared'),
        );

        final settings = readSettingsJson(
          await File(
            p.join(ctx.xdgDir, 'dotweave', 'settings.jsonc'),
          ).readAsString(),
        );

        expect(settings['activeProfile'], isNull);
      },
    );

    test(
      'lists profile assignments after tracking entries with --profile',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'workapp');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('token = secret\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['profile', 'add', 'work']);
        await ctx.runCli(['track', configDir, '--profile', 'work']);

        final result = await ctx.runCli(['profile', 'list']);

        expect(result.exitCode, 0);
      },
    );

    test(
      'pushes and pulls only profile-scoped entries with --profile flag',
      () async {
        final workDir = p.join(ctx.homeDir, '.config', 'work');
        final homeDir2 = p.join(ctx.homeDir, '.config', 'personal');
        final workFile = p.join(workDir, 'work.conf');
        final personalFile = p.join(homeDir2, 'personal.conf');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(workDir).create(recursive: true);
        await Directory(homeDir2).create(recursive: true);
        await File(workFile).writeAsString('office = true\n');
        await File(personalFile).writeAsString('home = true\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['profile', 'add', 'work']);
        await ctx.runCli(['profile', 'add', 'home']);
        await ctx.runCli(['track', workDir, '--profile', 'work']);
        await ctx.runCli(['track', homeDir2, '--profile', 'home']);

        // Push only the work profile
        final pushResult = await ctx.runCli(['push', '--profile', 'work']);

        expect(pushResult.exitCode, 0);
        expect(stripAnsi(pushResult.stdout), contains('Push complete'));

        // Work artifact should exist in the repository
        final workArtifact = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'work',
          '.config',
          'work',
          'work.conf',
        );
        expect(
          await File(workArtifact).readAsString(),
          contains('office = true'),
        );

        // Personal artifact should NOT have been pushed
        final personalArtifact = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'home',
          '.config',
          'personal',
          'personal.conf',
        );
        await expectLater(
          File(personalArtifact).readAsString(),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test(
      'pull --profile work applies work and default artifacts only',
      () async {
        final fixture = await setupProfilePullFixture();

        final result = await ctx.runCli(['pull', '--profile', 'work', '-y']);

        expect(result.exitCode, 0);
        expect(
          await File(fixture.workFile).readAsString(),
          'work = repository\n',
        );
        expect(
          await File(fixture.sharedFile).readAsString(),
          'shared = repository\n',
        );
        expect(await File(fixture.homeFile).readAsString(), 'home = local\n');
      },
    );

    test('pull -y uses the active work profile', () async {
      final fixture = await setupProfilePullFixture();

      await ctx.runCli(['profile', 'use', 'work']);
      final result = await ctx.runCli(['pull', '-y']);

      expect(result.exitCode, 0);
      expect(
        await File(fixture.workFile).readAsString(),
        'work = repository\n',
      );
      expect(
        await File(fixture.sharedFile).readAsString(),
        'shared = repository\n',
      );
      expect(await File(fixture.homeFile).readAsString(), 'home = local\n');
    });

    test(
      'pull -y with active home profile does not apply work artifacts',
      () async {
        final fixture = await setupProfilePullFixture();

        await ctx.runCli(['profile', 'use', 'home']);
        final result = await ctx.runCli(['pull', '-y']);

        expect(result.exitCode, 0);
        expect(
          await File(fixture.homeFile).readAsString(),
          'home = repository\n',
        );
        expect(
          await File(fixture.sharedFile).readAsString(),
          'shared = repository\n',
        );
        expect(await File(fixture.workFile).readAsString(), 'work = local\n');
      },
    );

    test('pull --profile overrides the active profile', () async {
      final fixture = await setupProfilePullFixture();

      await ctx.runCli(['profile', 'use', 'home']);
      final result = await ctx.runCli(['pull', '--profile', 'work', '-y']);

      expect(result.exitCode, 0);
      expect(
        await File(fixture.workFile).readAsString(),
        'work = repository\n',
      );
      expect(
        await File(fixture.sharedFile).readAsString(),
        'shared = repository\n',
      );
      expect(await File(fixture.homeFile).readAsString(), 'home = local\n');
    });

    test(
      'pull -y without an active named profile applies default artifacts only',
      () async {
        final fixture = await setupProfilePullFixture();

        await ctx.runCli(['profile', 'use']);
        final result = await ctx.runCli(['pull', '-y']);

        expect(result.exitCode, 0);
        expect(
          await File(fixture.sharedFile).readAsString(),
          'shared = repository\n',
        );
        expect(await File(fixture.workFile).readAsString(), 'work = local\n');
        expect(await File(fixture.homeFile).readAsString(), 'home = local\n');
      },
    );

    test('rejects invalid profile names with special characters', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);
      await ctx.runCli(['init']);

      final spaceResult = await ctx.runCli([
        'profile',
        'use',
        'invalid name',
      ], reject: false);
      expect(spaceResult.exitCode, isNot(0));
      expect(spaceResult.stderr, contains('unsupported characters'));

      final slashResult = await ctx.runCli([
        'profile',
        'use',
        'name/with/slashes',
      ], reject: false);
      expect(slashResult.exitCode, isNot(0));
      expect(slashResult.stderr, contains('unsupported characters'));
    });

    test('rejects profile use for a non-existent profile', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);
      await ctx.runCli(['init']);

      final result = await ctx.runCli([
        'profile',
        'use',
        'ghost',
      ], reject: false);

      expect(result.exitCode, isNot(0));
      expect(stripAnsi(result.stderr), contains("Unknown profile 'ghost'"));
    });

    test('lists default when no entries have explicit profiles', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'myapp');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(
        p.join(configDir, 'config.toml'),
      ).writeAsString('key = value\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);

      final result = await ctx.runCli(['profile', 'list']);

      expect(result.exitCode, 0);
      final out = stripAnsi(result.stdout);
      expect(out, contains('Profiles'));
      expect(out, contains('default'));
    });

    test('adds and removes unused profiles in the manifest registry', () async {
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await ctx.runCli(['init']);
      await ctx.runCli(['profile', 'add', 'work']);

      final manifestPath = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );
      var manifest = readManifestJson(await File(manifestPath).readAsString());
      expect(manifest.profiles, ['work']);

      final removeResult = await ctx.runCli(['profile', 'remove', 'work']);

      expect(removeResult.exitCode, 0);
      manifest = readManifestJson(await File(manifestPath).readAsString());
      expect(manifest.profiles, isEmpty);
    });

    test(
      'rejects removing profiles that are still referenced by entries',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'workapp');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(
          p.join(configDir, 'config.toml'),
        ).writeAsString('token = secret\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['profile', 'add', 'work']);
        await ctx.runCli(['track', configDir, '--profile', 'work']);

        final result = await ctx.runCli([
          'profile',
          'remove',
          'work',
        ], reject: false);

        expect(result.exitCode, isNot(0));
        expect(
          stripAnsi(result.stderr),
          contains(
            "Cannot remove profile 'work' because it is still referenced by "
            '1 sync entry.',
          ),
        );

        final manifestPath = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'manifest.jsonc',
        );
        final manifest = readManifestJson(
          await File(manifestPath).readAsString(),
        );
        expect(manifest.profiles, ['work']);
        expect((manifest.entries[0] as Map<String, Object?>)['profiles'], [
          'work',
        ]);
      },
    );

    test('rejects removing the active profile', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);
      await ctx.runCli(['init']);
      await ctx.runCli(['profile', 'add', 'work']);
      await ctx.runCli(['profile', 'use', 'work']);

      final result = await ctx.runCli([
        'profile',
        'remove',
        'work',
      ], reject: false);

      expect(result.exitCode, isNot(0));
      expect(
        stripAnsi(result.stderr),
        contains("Cannot remove active profile 'work'"),
      );
    });
  });
}
