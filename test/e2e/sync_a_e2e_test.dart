// Dart port of `tests/sync.e2e.test.ts` (the 14 `it` blocks
// from "generates a default age identity for bare init" through "sets mode
// on tracked roots via track command").
//
// The three `itWithPty` interactive-prompt tests in that range are not
// ported: they drive the CLI through a pseudo-terminal (`createPtySession`),
// which the Dart e2e harness has no equivalent for.
//
// `toMatchObject` on parsed JSON becomes per-key subset checks; execa's
// rejection on non-zero exit codes maps to `reject: false` where the TS test
// expects a failure.

@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/sync_schema.dart';
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

  group('sync CLI e2e', () {
    test('generates a default age identity for bare init', () async {
      final result = await ctx.runCli(['init'], env: ctx.baseEnv);

      expect(result.stdout, contains('age: generated a new local identity'));
      expect(
        await File(p.join(ctx.xdgDir, 'dotweave', 'keys.txt')).readAsString(),
        contains('AGE-SECRET-KEY-'),
      );

      final settings =
          jsonDecode(
                await File(
                  p.join(ctx.xdgDir, 'dotweave', 'settings.jsonc'),
                ).readAsString(),
              )
              as Map<String, Object?>;

      expect(settings, containsPair('activeProfile', 'default'));
      expect(settings, containsPair('version', 3));
      expect(settings, isNot(contains('age')));

      final manifest =
          jsonDecode(
                await File(
                  p.join(
                    ctx.xdgDir,
                    'dotweave',
                    'repository',
                    'manifest.jsonc',
                  ),
                ).readAsString(),
              )
              as Map<String, Object?>;
      final age = manifest['age']! as Map<String, Object?>;
      final recipients = age['recipients']! as List<Object?>;

      expect(recipients, hasLength(1));
      expect(recipients.single, matches(RegExp('^age1')));
      expect(manifest['entries'], isEmpty);
      expect(manifest['version'], 9);

      expect(
        await File(
          p.join(ctx.xdgDir, 'dotweave', 'repository', '.gitattributes'),
        ).readAsString(),
        '* -text\n',
      );
    });

    test('accepts a supplied age key file during init without a precreated '
        'identity file', () async {
      final sourceRepository = p.join(ctx.workspace, 'remote-sync');
      final keyFile = p.join(ctx.workspace, 'import.agekey');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.runGit(['init', '-b', 'main', sourceRepository]);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');

      final result = await ctx.runCli([
        'init',
        sourceRepository,
        '--key-file',
        keyFile,
      ]);

      expect(stripAnsi(result.stdout), contains('Sync directory initialized'));
      expect(
        stripAnsi(result.stdout),
        contains('age: using existing identity'),
      );
      expect(
        await File(p.join(ctx.xdgDir, 'dotweave', 'keys.txt')).readAsString(),
        '${ageKeys.identity}\n',
      );
    });

    test(
      'does not warn about an existing config when cloning a repository with '
      'an existing manifest',
      () async {
        final sourceRepository = p.join(ctx.workspace, 'remote-sync');
        final keyFile = p.join(ctx.workspace, 'manifest.agekey');
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
        await File(keyFile).writeAsString('${ageKeys.identity}\n');

        final result = await ctx.runCli([
          'init',
          sourceRepository,
          '--key-file',
          keyFile,
        ]);

        expect(
          stripAnsi(result.stdout),
          contains('Sync directory initialized'),
        );
        expect(
          stripAnsi(result.stdout),
          isNot(contains('Sync directory already initialized')),
        );
      },
    );

    test('rejects an invalid supplied age key file during init', () async {
      final keyFile = p.join(ctx.workspace, 'invalid.agekey');
      await File(keyFile).writeAsString('not-a-key\n');

      final result = await ctx.runCli([
        'init',
        '--key-file',
        keyFile,
      ], reject: false);

      expect(result.exitCode, isNot(0));
      expect(stripAnsi(result.stderr), contains('Invalid age private key'));
    });

    test('accepts an age key file when no identity file exists', () async {
      final sourceRepository = p.join(ctx.workspace, 'remote-sync');
      final keyFile = p.join(ctx.workspace, 'missing-identity.agekey');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.runGit(['init', '-b', 'main', sourceRepository]);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');

      final result = await ctx.runCli([
        'init',
        sourceRepository,
        '--key-file',
        keyFile,
      ]);

      expect(stripAnsi(result.stdout), contains('Sync directory initialized'));
      expect(
        await File(p.join(ctx.xdgDir, 'dotweave', 'keys.txt')).readAsString(),
        '${ageKeys.identity}\n',
      );
    });

    test(
      'does not warn about an existing config when cloning a repository with '
      'an existing manifest and passing a key file',
      () async {
        final sourceRepository = p.join(ctx.workspace, 'remote-sync');
        final keyFile = p.join(ctx.workspace, 'manifest-explicit.agekey');
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
        await File(keyFile).writeAsString('${ageKeys.identity}\n');

        final result = await ctx.runCli([
          'init',
          sourceRepository,
          '--key-file',
          keyFile,
        ]);

        expect(
          stripAnsi(result.stdout),
          contains('Sync directory initialized'),
        );
        expect(
          stripAnsi(result.stdout),
          isNot(contains('Sync directory already initialized')),
        );
      },
    );

    test('tracks roots, sets modes, and untracks from the CLI', () async {
      final bundleDirectory = p.join(ctx.homeDir, '.config', 'mytool');
      final publicFile = p.join(bundleDirectory, 'public.json');
      final cacheDirectory = p.join(bundleDirectory, 'cache');
      final syncDirectory = p.join(ctx.xdgDir, 'dotweave', 'repository');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(cacheDirectory).create(recursive: true);
      await File(publicFile).writeAsString('{}\n');
      await File(p.join(cacheDirectory, 'state.txt')).writeAsString('cache\n');

      await ctx.runCli(['init']);

      final trackResult = await ctx.runCli([
        'track',
        bundleDirectory,
        '--mode',
        'secret',
      ]);
      final exactRuleResult = await ctx.runCli([
        'track',
        publicFile,
        '--mode',
        'normal',
      ]);
      final subtreeRuleResult = await ctx.runCli([
        'track',
        cacheDirectory,
        '--mode',
        'ignore',
      ]);
      final configAfterSetEntries = parseManifestEntries(
        await File(p.join(syncDirectory, 'manifest.jsonc')).readAsString(),
      );

      expect(
        stripAnsi(trackResult.stdout),
        contains('Started tracking .config/mytool'),
      );
      expect(stripAnsi(trackResult.stdout), contains('mode'));
      expect(stripAnsi(trackResult.stdout), contains('secret'));
      expect(
        stripAnsi(exactRuleResult.stdout),
        contains('Started tracking .config/mytool/public.json'),
      );
      expect(
        stripAnsi(subtreeRuleResult.stdout),
        matches(RegExp(r'mode\s+ignore')),
      );
      expect(configAfterSetEntries, hasLength(3));
      expect(configAfterSetEntries[0], containsPair('kind', 'directory'));
      expect(
        configAfterSetEntries[0],
        containsPair('localPath', {'default': '~/.config/mytool'}),
      );
      expect(
        configAfterSetEntries[0],
        containsPair('mode', {'default': 'secret'}),
      );
      expect(configAfterSetEntries[1], containsPair('kind', 'directory'));
      expect(
        configAfterSetEntries[1],
        containsPair('localPath', {'default': '~/.config/mytool/cache'}),
      );
      expect(
        configAfterSetEntries[1],
        containsPair('mode', {'default': 'ignore'}),
      );
      expect(configAfterSetEntries[2], containsPair('kind', 'file'));
      expect(
        configAfterSetEntries[2],
        containsPair('localPath', {'default': '~/.config/mytool/public.json'}),
      );

      final untrackResult = await ctx.runCli(['untrack', '.config/mytool']);

      expect(
        stripAnsi(untrackResult.stdout),
        contains('Stopped tracking .config/mytool'),
      );

      await ctx.runCli(['untrack', '.config/mytool/cache']);
      await ctx.runCli(['untrack', '.config/mytool/public.json']);

      final untrackEntries = readManifestJson(
        await File(p.join(syncDirectory, 'manifest.jsonc')).readAsString(),
      ).entries;

      expect(untrackEntries, equals(<Object?>[]));
    });

    test(
      'syncs with the default profile namespace using push and pull',
      () async {
        final zshDirectory = p.join(ctx.homeDir, '.config', 'zsh');
        final sharedFile = p.join(zshDirectory, 'zshrc');
        final secretsFile = p.join(zshDirectory, 'secrets.zsh');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(zshDirectory).create(recursive: true);
        await File(sharedFile).writeAsString('export PATH=\$PATH:\$HOME/bin\n');
        await File(secretsFile).writeAsString('export TOKEN=work\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', zshDirectory]);
        await ctx.runCli(['track', secretsFile, '--mode', 'secret']);

        await ctx.runCli(['push']);

        expect(
          await File(
            p.join(
              ctx.xdgDir,
              'dotweave',
              'repository',
              'profiles',
              'default',
              '.config',
              'zsh',
              'zshrc',
            ),
          ).readAsString(),
          contains('PATH'),
        );
        expect(
          await File(
            p.join(
              ctx.xdgDir,
              'dotweave',
              'repository',
              'profiles',
              'default',
              '.config',
              'zsh',
              'secrets.zsh.dotweave.secret',
            ),
          ).readAsString(),
          contains('BEGIN AGE ENCRYPTED FILE'),
        );

        await File(secretsFile).writeAsString('local-change\n');
        await ctx.runCli(['pull', '-y']);

        expect(await File(secretsFile).readAsString(), contains('TOKEN=work'));
      },
    );

    test('restores secret directory files on another checkout when secret '
        'artifacts match repository ignore rules', () async {
      final sourceRepository = p.join(ctx.workspace, 'remote-sync.git');
      final keyFile = p.join(ctx.workspace, 'vivident.agekey');
      final syncDirectory = p.join(ctx.xdgDir, 'dotweave', 'repository');
      final vividentDirectory = p.join(ctx.homeDir, '.vivident');
      final secondHomeDirectory = p.join(ctx.workspace, 'home-second');
      final secondXdgDirectory = p.join(ctx.workspace, 'xdg-second');
      final secondLocalAppDataDirectory = p.join(
        ctx.workspace,
        'local-appdata-second',
      );
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.runGit(['init', '--bare', '-b', 'main', sourceRepository]);
      await ctx.writeIdentityFile(ageKeys.identity);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');
      await Directory(vividentDirectory).create(recursive: true);
      await Directory(secondHomeDirectory).create(recursive: true);
      await File(
        p.join(vividentDirectory, 'config.json'),
      ).writeAsString('{"theme":"dark"}\n');
      await File(
        p.join(vividentDirectory, 'state.txt'),
      ).writeAsString('window=main\n');

      await ctx.runCli(['init', sourceRepository]);
      await File(
        p.join(syncDirectory, '.gitignore'),
      ).writeAsString('*.dotweave.secret\n');
      await ctx.runCli(['track', vividentDirectory, '--mode', 'secret']);
      await ctx.runCli(['push']);

      expect(
        await File(
          p.join(
            syncDirectory,
            'profiles',
            'default',
            '.vivident',
            'config.json.dotweave.secret',
          ),
        ).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );
      expect(
        await File(
          p.join(
            syncDirectory,
            'profiles',
            'default',
            '.vivident',
            'state.txt.dotweave.secret',
          ),
        ).readAsString(),
        contains('BEGIN AGE ENCRYPTED FILE'),
      );

      final ignoredStatus = await ctx.runGit([
        'status',
        '--ignored',
        '--short',
        '--untracked-files=all',
      ], syncDirectory);
      expect(
        ignoredStatus.stdout,
        isNot(
          contains('!! profiles/default/.vivident/config.json.dotweave.secret'),
        ),
      );
      expect(
        ignoredStatus.stdout,
        isNot(
          contains('!! profiles/default/.vivident/state.txt.dotweave.secret'),
        ),
      );

      await ctx.runGit(['add', '.'], syncDirectory);
      await ctx.runGit([
        'commit',
        '-m',
        'sync vivident directory',
      ], syncDirectory);
      await ctx.runGit(['push', '-u', 'origin', 'main'], syncDirectory);

      final secondEnv = {
        'APPDATA': secondXdgDirectory,
        'HOME': secondHomeDirectory,
        'LOCALAPPDATA': secondLocalAppDataDirectory,
        'USERPROFILE': secondHomeDirectory,
        'XDG_CONFIG_HOME': secondXdgDirectory,
      };

      await ctx.runCli([
        'init',
        sourceRepository,
        '--key-file',
        keyFile,
      ], env: secondEnv);
      await ctx.runCli(['pull', '-y'], env: secondEnv);

      expect(
        await File(
          p.join(secondHomeDirectory, '.vivident', 'config.json'),
        ).readAsString(),
        '{"theme":"dark"}\n',
      );
      expect(
        await File(
          p.join(secondHomeDirectory, '.vivident', 'state.txt'),
        ).readAsString(),
        'window=main\n',
      );
    });

    test(
      'status reports a removed default entry artifact before push',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'prune-status');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('enabled = true\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', configDir]);
        await ctx.runCli(['push']);

        await File(
          p.join(ctx.xdgDir, 'dotweave', 'repository', 'manifest.jsonc'),
        ).writeAsString(
          formatSyncConfig(
            createInitialSyncConfig(AgeConfig(recipients: [ageKeys.recipient])),
          ),
        );

        final status = await ctx.runCli(['status']);
        final output = stripAnsi(status.stdout);

        expect(output, contains('Push changes (repository)'));
        expect(output, contains('Delete (1)'));
        expect(output, contains('.config/prune-status/config.toml'));
      },
    );

    test('push prunes a removed default entry artifact', () async {
      final configDir = p.join(ctx.homeDir, '.config', 'prune-push');
      final configFile = p.join(configDir, 'config.toml');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(configDir).create(recursive: true);
      await File(configFile).writeAsString('enabled = true\n');

      await ctx.runCli(['init']);
      await ctx.runCli(['track', configDir]);
      await ctx.runCli(['push']);

      final artifact = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.config',
        'prune-push',
        'config.toml',
      );
      expect(await File(artifact).readAsString(), 'enabled = true\n');

      await File(
        p.join(ctx.xdgDir, 'dotweave', 'repository', 'manifest.jsonc'),
      ).writeAsString(
        formatSyncConfig(
          createInitialSyncConfig(AgeConfig(recipients: [ageKeys.recipient])),
        ),
      );

      final result = await ctx.runCli(['push']);

      expect(stripAnsi(result.stdout), contains('1 stale artifacts removed'));
      expectPathAbsent(artifact);
    });

    test(
      'push --profile work prunes a non-default profile artifact after final '
      'entry removal',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'work-prune');
        final configFile = p.join(configDir, 'config.toml');
        final ageKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(ageKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(configFile).writeAsString('workspace = true\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['profile', 'add', 'work']);
        await ctx.runCli(['track', configDir, '--profile', 'work']);
        await ctx.runCli(['push', '--profile', 'work']);

        final artifact = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'work',
          '.config',
          'work-prune',
          'config.toml',
        );
        expect(await File(artifact).readAsString(), 'workspace = true\n');

        final base = createInitialSyncConfig(
          AgeConfig(recipients: [ageKeys.recipient]),
        );

        await File(
          p.join(ctx.xdgDir, 'dotweave', 'repository', 'manifest.jsonc'),
        ).writeAsString(
          formatSyncConfig(
            RawSyncConfig(
              version: base.version,
              repositoryFormat: base.repositoryFormat,
              age: base.age,
              profiles: ['work'],
              entries: [],
            ),
          ),
        );

        final result = await ctx.runCli(['push', '--profile', 'work']);

        expect(stripAnsi(result.stdout), contains('1 stale artifacts removed'));
        expectPathAbsent(artifact);
      },
    );

    test(
      'fails cleanly when pulling a secret artifact with the wrong identity',
      () async {
        final configDir = p.join(ctx.homeDir, '.config', 'wrong-identity');
        final secretFile = p.join(configDir, 'token.env');
        final originalKeys = await ctx.createAgeKeyPair();
        final wrongKeys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(originalKeys.identity);
        await Directory(configDir).create(recursive: true);
        await File(secretFile).writeAsString('TOKEN=remote\n');

        await ctx.runCli(['init']);
        await ctx.runCli(['track', secretFile, '--mode', 'secret']);
        await ctx.runCli(['push']);

        await File(secretFile).writeAsString('local-survivor\n');
        await ctx.writeIdentityFile(wrongKeys.identity);

        final result = await ctx.runCli(['pull', '-y'], reject: false);
        final stderr = stripAnsi(result.stderr);
        final siblingNames = await Directory(
          configDir,
        ).list().map((entity) => p.basename(entity.path)).toList();

        expect(result.exitCode, isNot(0));
        expect(
          stderr,
          contains('Failed to decrypt a secret repository artifact'),
        );
        expect(stderr, contains('Identity file:'));
        expect(stderr, contains('matches one of its recipients'));
        expect(await File(secretFile).readAsString(), 'local-survivor\n');
        expect(
          siblingNames.where((name) => name.contains('.dotweave-sync-')),
          isEmpty,
        );
      },
    );

    test('sets mode on tracked roots via track command', () async {
      final bundleDirectory = p.join(ctx.homeDir, '.config', 'mytool');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(bundleDirectory).create(recursive: true);

      await ctx.runCli(['init']);
      await ctx.runCli(['track', bundleDirectory]);

      final result = await ctx.runCli([
        'track',
        bundleDirectory,
        '--mode',
        'secret',
      ]);

      expect(result.exitCode, 0);
      expect(
        stripAnsi(result.stdout),
        contains('Updated tracking for .config/mytool'),
      );
      expect(stripAnsi(result.stdout), contains('mode'));
      expect(stripAnsi(result.stdout), contains('secret'));
    });
  });
}
