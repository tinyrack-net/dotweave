import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/util/env.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/git.dart';
import 'package:dotweave_age/dotweave_age.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Port of `../test/helpers/sync-fixture.ts`: the subset used by init.test.ts
// (temporary directories, age key pairs, identity files, and real git runs).

final List<String> _temporaryDirectories = [];

final Map<String, String> _gitTestEnvironment = {
  'GIT_AUTHOR_EMAIL': 'test@example.com',
  'GIT_AUTHOR_NAME': 'Test User',
  'GIT_COMMITTER_EMAIL': 'test@example.com',
  'GIT_COMMITTER_NAME': 'Test User',
  'GIT_CONFIG_COUNT': '1',
  'GIT_CONFIG_KEY_0': 'commit.gpgsign',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_VALUE_0': 'false',
  'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
};

Future<String> _createTemporaryDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);

  return directory.path;
}

Future<String> createWorkspace() async {
  final directory = await _createTemporaryDirectory('dotweave-init-');

  _temporaryDirectories.add(directory);

  return directory;
}

Future<({String identity, String recipient})> createAgeKeyPair() async {
  final identity = generateIdentity();

  return (identity: identity, recipient: await identityToRecipient(identity));
}

Future<String> writeIdentityFile(String xdgConfigHome, String identity) async {
  final dotweaveHomeDirectory = p.join(
    xdgConfigHome,
    AppConstants.xdg.appDirectoryName,
  );
  final identityFile = p.join(dotweaveHomeDirectory, 'keys.txt');

  await Directory(p.dirname(identityFile)).create(recursive: true);
  await File(identityFile).writeAsString('$identity\n');

  return identityFile;
}

Future<void> runGit(List<String> args, [String? cwd]) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: cwd,
    runInShell: false,
    environment: {...Platform.environment, ..._gitTestEnvironment},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  if (result.exitCode != 0) {
    throw Exception(
      'git ${args.join(' ')} failed with code ${result.exitCode}: '
      '${result.stderr}',
    );
  }
}

/// Stands in for the vitest `mockEnv` (`vi.mock("#app/lib/env.ts")`): every
/// env read inside the init service resolves against this map.
Env buildEnvironment(
  String homeDirectory,
  String xdgConfigHome, {
  String? dotweaveHome,
}) {
  return Env({
    'APPDATA': xdgConfigHome,
    'DOTWEAVE_HOME': ?dotweaveHome,
    'HOME': homeDirectory,
    'LOCALAPPDATA': p.join(homeDirectory, 'AppData', 'Local'),
    'USERPROFILE': homeDirectory,
    'XDG_CONFIG_HOME': xdgConfigHome,
  });
}

/// Stands in for `vi.stubEnv("PATH", "")`: routes the real git command
/// wrappers through an execFile seam that fails like a missing executable
/// (spawn ENOENT), so the genuine missing-git normalization in `lib/git.dart`
/// produces the error the service must wrap.
InitDependencies missingGitDependencies(Env env) {
  const gitDependencies = GitCommandDependencies(execFileAsync: _spawnEnoent);

  return InitDependencies(
    env: env,
    verifyIsGitRepository: (directory) async {
      await runGitCommandWithDependencies(
        ['-C', directory, 'rev-parse', '--is-inside-work-tree'],
        null,
        gitDependencies,
      );
    },
    initializeRepository: (directory, [source]) async {
      if (source == null) {
        await runGitCommandWithDependencies(
          ['init', '-b', 'main', directory],
          null,
          gitDependencies,
        );

        return const InitializeRepositoryResult(action: 'initialized');
      }

      await runGitCommandWithDependencies(
        ['clone', source, directory],
        null,
        gitDependencies,
      );

      return InitializeRepositoryResult(action: 'cloned', source: source);
    },
  );
}

Future<GitCommandResult> _spawnEnoent(
  String file,
  List<String> args, {
  String? cwd,
}) async {
  throw ProcessException(file, args, 'spawn $file ENOENT', 2);
}

Future<void> _removeTemporaryDirectory(String directory) async {
  final target = Directory(directory);

  if (!await target.exists()) {
    return;
  }

  try {
    await target.delete(recursive: true);
  } on FileSystemException {
    if (!Platform.isWindows) {
      rethrow;
    }

    // Git object files are read-only on Windows; clear attributes and retry.
    await Process.run('cmd', [
      '/c',
      'rmdir',
      '/s',
      '/q',
      directory,
    ], runInShell: false);
  }
}

void main() {
  tearDown(() async {
    while (_temporaryDirectories.isNotEmpty) {
      final directory = _temporaryDirectories.removeLast();

      await _removeTemporaryDirectory(directory);
    }
  });

  group('init service', () {
    test('writes a supplied age private key during initialization', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final sourceRepository = p.join(workspace, 'remote-sync');
      final ageKeys = await createAgeKeyPair();
      final extraRecipient = await createAgeKeyPair();

      await runGit(['init', '-b', 'main', sourceRepository], workspace);

      final env = buildEnvironment(homeDirectory, xdgConfigHome);
      final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
      final result = await initializeSyncDirectory(
        InitRequest(
          ageIdentity: '  ${ageKeys.identity}  ',
          recipients: [ageKeys.recipient, extraRecipient.recipient],
          repository: sourceRepository,
        ),
        InitDependencies(env: env),
      );

      expect(result.generatedIdentity, false);
      expect(
        await File(
          p.join(xdgConfigHome, 'dotweave', 'keys.txt'),
        ).readAsString(),
        '${ageKeys.identity}\n',
      );
      final manifest =
          jsonDecode(
                await File(
                  p.join(syncDirectory, 'manifest.jsonc'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      final age = manifest['age'] as Map<String, Object?>;
      expect(
        age['recipients'],
        containsAll([ageKeys.recipient, extraRecipient.recipient]),
      );
    });

    test('uses DOTWEAVE_HOME for initialization storage', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final dotweaveHome = p.join(workspace, 'custom-dotweave');
      final ageKeys = await createAgeKeyPair();

      final env = buildEnvironment(
        homeDirectory,
        xdgConfigHome,
        dotweaveHome: dotweaveHome,
      );

      await initializeSyncDirectory(
        InitRequest(
          ageIdentity: ageKeys.identity,
          recipients: [ageKeys.recipient],
        ),
        InitDependencies(env: env),
      );

      await expectLater(
        File(p.join(dotweaveHome, 'keys.txt')).readAsString(),
        completion('${ageKeys.identity}\n'),
      );
      await expectLater(
        File(p.join(dotweaveHome, 'settings.jsonc')).readAsString(),
        completion(contains('"version": 3')),
      );
      await expectLater(
        File(
          p.join(dotweaveHome, 'repository', 'manifest.jsonc'),
        ).readAsString(),
        completion(contains('"version": 8')),
      );
      await expectLater(
        File(
          p.join(xdgConfigHome, 'dotweave', 'settings.jsonc'),
        ).readAsString(),
        throwsA(anything),
      );
    });

    test('rejects an invalid supplied age private key', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');

      final env = buildEnvironment(homeDirectory, xdgConfigHome);

      await expectLater(
        initializeSyncDirectory(
          const InitRequest(ageIdentity: 'not-a-key', recipients: []),
          InitDependencies(env: env),
        ),
        throwsA(
          predicate(
            (error) =>
                RegExp(r'Invalid age private key').hasMatch(error.toString()),
          ),
        ),
      );
    });

    test(
      'reports a missing git executable during local initialization',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        final env = buildEnvironment(homeDirectory, xdgConfigHome);
        final dependencies = missingGitDependencies(env);

        await expectLater(
          initializeSyncDirectory(
            InitRequest(recipients: [ageKeys.recipient]),
            dependencies,
          ),
          throwsA(
            isA<DotweaveError>()
                .having((error) => error.code, 'code', 'SYNC_INIT_GIT_FAILED')
                .having((error) => error.hint, 'hint', contains('Git'))
                .having(
                  (error) => error.message,
                  'message',
                  'Failed to initialize the sync directory.',
                ),
          ),
        );
        await expectLater(
          initializeSyncDirectory(
            InitRequest(recipients: [ageKeys.recipient]),
            dependencies,
          ),
          throwsA(
            isA<DotweaveError>()
                .having(
                  (error) => error.details,
                  'details',
                  anyElement(contains('not installed or not on PATH')),
                )
                .having((error) => error.hint, 'hint', contains('PATH')),
          ),
        );
      },
    );

    test(
      'reports a missing git executable during repository cloning',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        final env = buildEnvironment(homeDirectory, xdgConfigHome);
        final dependencies = missingGitDependencies(env);

        await expectLater(
          initializeSyncDirectory(
            InitRequest(
              recipients: [ageKeys.recipient],
              repository: 'https://example.invalid/dotfiles.git',
            ),
            dependencies,
          ),
          throwsA(
            isA<DotweaveError>()
                .having((error) => error.code, 'code', 'SYNC_CLONE_FAILED')
                .having(
                  (error) => error.details,
                  'details',
                  anyElement(contains('not installed or not on PATH')),
                )
                .having(
                  (error) => error.hint,
                  'hint',
                  isNot(contains('repository source is reachable')),
                )
                .having(
                  (error) => error.message,
                  'message',
                  'Failed to clone the sync directory.',
                ),
          ),
        );
      },
    );

    test(
      'clones a configured repository source during initialization',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final sourceRepository = p.join(workspace, 'remote-sync');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await runGit(['init', '-b', 'main', sourceRepository], workspace);

        final env = buildEnvironment(homeDirectory, xdgConfigHome);
        final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
        final result = await initializeSyncDirectory(
          InitRequest(
            recipients: [ageKeys.recipient],
            repository: sourceRepository,
          ),
          InitDependencies(env: env),
        );

        expect(result.gitAction, 'cloned');
        expect(result.gitSource, sourceRepository);
        expect(
          await File(p.join(syncDirectory, 'manifest.jsonc')).readAsString(),
          contains('"version": 8'),
        );
        expect(
          await File(p.join(syncDirectory, 'manifest.jsonc')).readAsString(),
          isNot(contains('identityFile')),
        );
        expect(
          await File(p.join(syncDirectory, '.gitattributes')).readAsString(),
          '* -text\n',
        );
      },
    );

    test('rejects an existing initialized repo by default', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final ageKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, ageKeys.identity);
      final env = buildEnvironment(homeDirectory, xdgConfigHome);

      await initializeSyncDirectory(
        InitRequest(recipients: [ageKeys.recipient]),
        InitDependencies(env: env),
      );

      await expectLater(
        initializeSyncDirectory(
          InitRequest(recipients: [ageKeys.recipient]),
          InitDependencies(env: env),
        ),
        throwsA(
          isA<DotweaveError>()
              .having((error) => error.code, 'code', 'INIT_ALREADY_INITIALIZED')
              .having(
                (error) => error.message,
                'message',
                'Sync directory is already initialized.',
              ),
        ),
      );
    });

    test(
      'rejects non-empty sync directories that are not git repositories',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(syncDirectory).create(recursive: true);
        await File(
          p.join(syncDirectory, 'placeholder.txt'),
        ).writeAsString('keep\n');

        final env = buildEnvironment(homeDirectory, xdgConfigHome);

        await expectLater(
          initializeSyncDirectory(
            InitRequest(recipients: [ageKeys.recipient]),
            InitDependencies(env: env),
          ),
          throwsA(isA<DotweaveError>()),
        );
        await expectLater(
          initializeSyncDirectory(
            InitRequest(recipients: [ageKeys.recipient]),
            InitDependencies(env: env),
          ),
          throwsA(
            predicate(
              (error) => RegExp(
                r'Sync directory already exists and is not empty',
              ).hasMatch(error.toString()),
            ),
          ),
        );
        await expectLater(
          initializeSyncDirectory(
            InitRequest(
              identityFile: r'$XDG_CONFIG_HOME/dotweave/keys.txt',
              recipients: [ageKeys.recipient],
            ),
            InitDependencies(env: env),
          ),
          throwsA(
            isA<DotweaveError>().having(
              (error) => error.details,
              'details',
              anyElement('Sync directory: $syncDirectory'),
            ),
          ),
        );
      },
    );

    test('force removes existing local init state and clones a supplied '
        'repository', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final sourceRepository = p.join(workspace, 'remote-sync');
      final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
      final oldAgeKeys = await createAgeKeyPair();
      final newAgeKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, oldAgeKeys.identity);
      final env = buildEnvironment(homeDirectory, xdgConfigHome);

      await initializeSyncDirectory(
        InitRequest(recipients: [oldAgeKeys.recipient]),
        InitDependencies(env: env),
      );
      await File(
        p.join(xdgConfigHome, 'dotweave', 'settings.jsonc'),
      ).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({'activeProfile': 'old-profile', 'version': 3})}\n',
      );
      await File(
        p.join(syncDirectory, 'local-only.txt'),
      ).writeAsString('remove me\n');

      await runGit(['init', '-b', 'main', sourceRepository], workspace);
      await File(
        p.join(sourceRepository, 'remote-only.txt'),
      ).writeAsString('cloned\n');
      await runGit(['add', 'remote-only.txt'], sourceRepository);
      await runGit(['commit', '-m', 'add remote marker'], sourceRepository);

      final result = await initializeSyncDirectory(
        InitRequest(
          ageIdentity: newAgeKeys.identity,
          force: true,
          recipients: [],
          repository: sourceRepository,
        ),
        InitDependencies(env: env),
      );

      expect(result.gitAction, 'cloned');
      expect(result.gitSource, sourceRepository);
      final remoteOnly = await File(
        p.join(syncDirectory, 'remote-only.txt'),
      ).readAsString();
      expect(remoteOnly.replaceAll('\r\n', '\n'), 'cloned\n');
      await expectLater(
        File(p.join(syncDirectory, 'local-only.txt')).readAsString(),
        throwsA(anything),
      );
      await expectLater(
        File(p.join(xdgConfigHome, 'dotweave', 'keys.txt')).readAsString(),
        completion('${newAgeKeys.identity}\n'),
      );
      await expectLater(
        File(p.join(xdgConfigHome, 'dotweave', 'keys.txt')).readAsString(),
        completion(isNot(contains(oldAgeKeys.identity))),
      );
      expect(
        jsonDecode(
          await File(
            p.join(xdgConfigHome, 'dotweave', 'settings.jsonc'),
          ).readAsString(),
        ),
        allOf(
          containsPair('activeProfile', 'default'),
          containsPair('version', 3),
        ),
      );
    });

    test(
      'force rejects importing a repository without a new age identity after '
      'removing the old identity',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final sourceRepository = p.join(workspace, 'remote-sync');
        final oldAgeKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, oldAgeKeys.identity);
        await runGit(['init', '-b', 'main', sourceRepository], workspace);

        final env = buildEnvironment(homeDirectory, xdgConfigHome);

        await expectLater(
          initializeSyncDirectory(
            InitRequest(
              force: true,
              recipients: const [],
              repository: sourceRepository,
            ),
            InitDependencies(env: env),
          ),
          throwsA(
            isA<DotweaveError>()
                .having(
                  (error) => error.code,
                  'code',
                  'INIT_AGE_IDENTITY_REQUIRED',
                )
                .having((error) => error.hint, 'hint', contains('--key-file'))
                .having(
                  (error) => error.message,
                  'message',
                  'Existing repository setup requires an age private key.',
                ),
          ),
        );
      },
    );

    test('force replaces an old identity and rewrites settings for local '
        'initialization', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
      final oldAgeKeys = await createAgeKeyPair();

      await writeIdentityFile(xdgConfigHome, oldAgeKeys.identity);
      final env = buildEnvironment(homeDirectory, xdgConfigHome);

      await initializeSyncDirectory(
        InitRequest(recipients: [oldAgeKeys.recipient]),
        InitDependencies(env: env),
      );
      await File(
        p.join(xdgConfigHome, 'dotweave', 'settings.jsonc'),
      ).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({'activeProfile': 'old-profile', 'version': 3})}\n',
      );

      final result = await initializeSyncDirectory(
        const InitRequest(force: true, recipients: []),
        InitDependencies(env: env),
      );

      expect(result.generatedIdentity, true);
      expect(result.gitAction, 'initialized');
      await expectLater(
        File(p.join(syncDirectory, 'manifest.jsonc')).readAsString(),
        completion(contains('"version": 8')),
      );

      final newIdentity = await File(
        p.join(xdgConfigHome, 'dotweave', 'keys.txt'),
      ).readAsString();
      expect(newIdentity, contains('AGE-SECRET-KEY-'));
      expect(newIdentity, isNot(contains(oldAgeKeys.identity)));
      expect(
        jsonDecode(
          await File(
            p.join(xdgConfigHome, 'dotweave', 'settings.jsonc'),
          ).readAsString(),
        ),
        allOf(
          containsPair('activeProfile', 'default'),
          containsPair('version', 3),
        ),
      );
    });

    test(
      'force removes a non-git non-empty sync directory and initializes',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final syncDirectory = p.join(xdgConfigHome, 'dotweave', 'repository');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);
        await Directory(syncDirectory).create(recursive: true);
        await File(
          p.join(syncDirectory, 'placeholder.txt'),
        ).writeAsString('remove\n');

        final env = buildEnvironment(homeDirectory, xdgConfigHome);
        final result = await initializeSyncDirectory(
          InitRequest(force: true, recipients: [ageKeys.recipient]),
          InitDependencies(env: env),
        );

        expect(result.gitAction, 'initialized');
        await expectLater(
          File(p.join(syncDirectory, 'manifest.jsonc')).readAsString(),
          completion(contains('"version": 8')),
        );
        await expectLater(
          File(p.join(syncDirectory, 'placeholder.txt')).readAsString(),
          throwsA(anything),
        );
      },
    );

    test(
      'rejects repeated init before checking recipient mismatches',
      () async {
        final workspace = await createWorkspace();
        final homeDirectory = p.join(workspace, 'home');
        final xdgConfigHome = p.join(workspace, 'xdg');
        final ageKeys = await createAgeKeyPair();

        await writeIdentityFile(xdgConfigHome, ageKeys.identity);

        final env = buildEnvironment(homeDirectory, xdgConfigHome);

        await initializeSyncDirectory(
          InitRequest(recipients: [ageKeys.recipient]),
          InitDependencies(env: env),
        );

        await expectLater(
          initializeSyncDirectory(
            const InitRequest(recipients: ['age1differentrecipient']),
            InitDependencies(env: env),
          ),
          throwsA(
            isA<DotweaveError>()
                .having(
                  (error) => error.code,
                  'code',
                  'INIT_ALREADY_INITIALIZED',
                )
                .having(
                  (error) => error.message,
                  'message',
                  'Sync directory is already initialized.',
                ),
          ),
        );
      },
    );

    test('writes a supplied age private key when cloning a repo that already '
        'has manifest.jsonc', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final sourceRepository = p.join(workspace, 'remote-sync');
      final ageKeys = await createAgeKeyPair();

      await runGit(['init', '-b', 'main', sourceRepository], workspace);

      final initialConfig = createInitialSyncConfig(
        AgeConfig(recipients: [ageKeys.recipient]),
      );

      await File(
        p.join(sourceRepository, 'manifest.jsonc'),
      ).writeAsString(formatSyncConfig(initialConfig));
      await runGit(['add', 'manifest.jsonc'], sourceRepository);
      await runGit([
        'commit',
        '-m',
        'initial config',
        '--author',
        'test <test@test.com>',
      ], sourceRepository);

      final env = buildEnvironment(homeDirectory, xdgConfigHome);
      final result = await initializeSyncDirectory(
        InitRequest(
          ageIdentity: ageKeys.identity,
          recipients: const [],
          repository: sourceRepository,
        ),
        InitDependencies(env: env),
      );

      expect(result.alreadyInitialized, false);
      expect(result.generatedIdentity, false);
      expect(
        await File(
          p.join(xdgConfigHome, 'dotweave', 'keys.txt'),
        ).readAsString(),
        '${ageKeys.identity}\n',
      );
      expect(
        jsonDecode(
          await File(
            p.join(xdgConfigHome, 'dotweave', 'settings.jsonc'),
          ).readAsString(),
        ),
        allOf(
          containsPair('activeProfile', 'default'),
          containsPair('version', 3),
        ),
      );
    });

    test('rejects cloning a repo with manifest.jsonc when no key or identity '
        'file is available', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final sourceRepository = p.join(workspace, 'remote-sync');
      final ageKeys = await createAgeKeyPair();

      await runGit(['init', '-b', 'main', sourceRepository], workspace);

      final initialConfig = createInitialSyncConfig(
        AgeConfig(recipients: [ageKeys.recipient]),
      );

      await File(
        p.join(sourceRepository, 'manifest.jsonc'),
      ).writeAsString(formatSyncConfig(initialConfig));
      await runGit(['add', 'manifest.jsonc'], sourceRepository);
      await runGit([
        'commit',
        '-m',
        'initial config',
        '--author',
        'test <test@test.com>',
      ], sourceRepository);

      final env = buildEnvironment(homeDirectory, xdgConfigHome);

      await expectLater(
        initializeSyncDirectory(
          InitRequest(
            generateAgeIdentity: true,
            recipients: const [],
            repository: sourceRepository,
          ),
          InitDependencies(env: env),
        ),
        throwsA(
          predicate(
            (error) => RegExp(
              r'Existing repository setup requires an age private key',
            ).hasMatch(error.toString()),
          ),
        ),
      );
    });

    test('rejects cloning a repo with manifest.json', () async {
      final workspace = await createWorkspace();
      final homeDirectory = p.join(workspace, 'home');
      final xdgConfigHome = p.join(workspace, 'xdg');
      final sourceRepository = p.join(workspace, 'remote-sync');
      final ageKeys = await createAgeKeyPair();

      await runGit(['init', '-b', 'main', sourceRepository], workspace);

      final initialConfig = createInitialSyncConfig(
        AgeConfig(recipients: [ageKeys.recipient]),
      );

      await File(
        p.join(sourceRepository, 'manifest.json'),
      ).writeAsString(formatSyncConfig(initialConfig));
      await runGit(['add', 'manifest.json'], sourceRepository);
      await runGit([
        'commit',
        '-m',
        'legacy config',
        '--author',
        'test <test@test.com>',
      ], sourceRepository);

      final env = buildEnvironment(homeDirectory, xdgConfigHome);

      await expectLater(
        initializeSyncDirectory(
          InitRequest(
            ageIdentity: ageKeys.identity,
            recipients: const [],
            repository: sourceRepository,
          ),
          InitDependencies(env: env),
        ),
        throwsA(
          isA<DotweaveError>()
              .having((error) => error.code, 'code', 'CONFIG_JSON_UNSUPPORTED')
              .having(
                (error) => error.details,
                'details',
                anyElement(
                  matches(RegExp(r'Unsupported config file: .*manifest\.json')),
                ),
              )
              .having(
                (error) => error.message,
                'message',
                'Unsupported dotweave config file.',
              ),
        ),
      );
    });
  });
}
