// Cross-CLI compatibility suite: the cutover guarantee that the Dart port
// (`packages/cli_dart`) and the TypeScript CLI (`packages/cli`) can read each
// other's on-disk state byte-for-byte.
//
// Five scenarios:
//   1. TS writes → Dart reads (the critical direction for existing users).
//   2. Dart writes → TS reads (the mirror).
//   3. Byte parity of written config between twin workspaces.
//   4. Interleaved ping-pong on one shared repository.
//   5. Output parity spot-checks (--version, --help, status, a validation
//      error).
//
// Requires node + pnpm (the TS CLI is built on demand, see `ts_cli.dart`)
// and real git/age. Symlink coverage is POSIX-only.

@Tags(['compat'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/crypto/age/age.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart' as fixture;
import 'ts_cli.dart';

/// A CLI runner bound to a workspace base environment: either the Dart
/// compiled binary or the TS `node dist/index.js` entry.
typedef CliRunner =
    Future<CliRunResult> Function(
      List<String> args, {
      Map<String, String>? env,
      bool reject,
    });

void main() {
  late SyncE2EContext ctx;

  setUpAll(() async {
    // Build both CLIs up front so per-test timeouts only cover test work.
    await ensureTsCli();
    await resolveE2eBinary();
  });

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  Future<CliRunResult> tsCli(
    List<String> args, {
    Map<String, String>? env,
    bool reject = true,
  }) {
    return runTsCli(
      args,
      env: env == null ? ctx.baseEnv : mergeEnvironment(ctx.baseEnv, env),
      reject: reject,
    );
  }

  Future<CliRunResult> dartCli(
    List<String> args, {
    Map<String, String>? env,
    bool reject = true,
  }) {
    return ctx.runCli(args, env: env, reject: reject);
  }

  void expectCleanStatus(CliRunResult result) {
    final output = fixture.stripAnsi(result.stdout);

    expect(result.exitCode, 0);
    expect(output, contains('No push changes'));
    expect(output, contains('No pull changes'));
  }

  /// Commits and pushes the sync repository for the machine rooted at
  /// [xdgDir]. Skips the commit when the work tree is clean (e.g. after an
  /// untrack already pruned the artifact and push had nothing left to do).
  Future<void> commitAndPushRepo(
    String xdgDir,
    String message, {
    bool setUpstream = false,
  }) async {
    final repoDir = p.join(xdgDir, 'dotweave', 'repository');
    final status = await ctx.runGit(['status', '--porcelain'], repoDir);

    if (status.stdout.trim().isNotEmpty) {
      await ctx.runGit(['add', '.'], repoDir);
      await ctx.runGit(['commit', '-m', message], repoDir);
    }

    await ctx.runGit([
      'push',
      if (setUpstream) ...['-u', 'origin', 'main'],
    ], repoDir);
  }

  /// Lists every file in the sync repository (excluding `.git`) as
  /// POSIX-style paths relative to the repository root.
  Future<Set<String>> listRepositoryFiles(String xdgDir) async {
    final root = p.join(xdgDir, 'dotweave', 'repository');
    final files = <String>{};

    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }

      final relative = p.posix.joinAll(
        p.split(p.relative(entity.path, from: root)),
      );

      if (relative == '.git' || relative.startsWith('.git/')) {
        continue;
      }

      files.add(relative);
    }

    return files;
  }

  /// Scenarios 1 and 2: one CLI initializes, tracks (plain file, secret
  /// file, directory with a nested file, POSIX-only symlink), and pushes;
  /// the other CLI must see a clean workspace on the same machine and fully
  /// materialize the files on a second machine.
  Future<void> writerReaderScenario({
    required CliRunner writer,
    required CliRunner reader,
    required String label,
  }) async {
    final remote = p.join(ctx.workspace, 'remote-$label.git');
    final keyFile = p.join(ctx.workspace, '$label.agekey');
    final keys = await ctx.createAgeKeyPair();

    await ctx.runGit(['init', '--bare', '-b', 'main', remote]);
    await ctx.writeIdentityFile(keys.identity);
    await File(keyFile).writeAsString('${keys.identity}\n');

    final appDir = p.join(ctx.homeDir, '.config', 'app');
    final plainFile = p.join(appDir, 'config.toml');
    final secretFile = p.join(appDir, 'secret.env');
    final toolDir = p.join(ctx.homeDir, '.config', 'tooldir');
    final nestedFile = p.join(toolDir, 'nested', 'deep.txt');
    final link = p.join(ctx.homeDir, '.config', 'link.toml');

    await Directory(appDir).create(recursive: true);
    await Directory(p.dirname(nestedFile)).create(recursive: true);
    await File(plainFile).writeAsString('key = value\n');
    await File(secretFile).writeAsString('TOKEN=$label-secret\n');
    await File(nestedFile).writeAsString('deep\n');

    if (!Platform.isWindows) {
      await createSymlink(p.join('app', 'config.toml'), link);
    }

    await writer(['init', remote]);
    await writer(['track', plainFile]);
    await writer(['track', secretFile, '--mode', 'secret']);
    await writer(['track', toolDir]);

    if (!Platform.isWindows) {
      await writer(['track', link]);
    }

    await writer(['push']);

    // The secret artifact must be an armored age ciphertext in the repo.
    expect(
      await readRepositoryArtifact(
        ctx.xdgDir,
        'default',
        '.config/app/secret.env.dotweave.secret',
      ),
      contains('BEGIN AGE ENCRYPTED FILE'),
    );

    // Same machine, other CLI: no spurious diffs, doctor healthy.
    expectCleanStatus(await reader(['status']));

    final doctor = await reader(['doctor']);

    expect(doctor.exitCode, 0);
    expect(
      fixture.stripAnsi(doctor.stdout),
      isNot(contains('Doctor found issues')),
    );

    await commitAndPushRepo(ctx.xdgDir, 'sync $label', setUpstream: true);

    // Machine B: the reader clones the repository and pulls.
    final machineB = createMachineEnv(ctx.workspace, '$label-b', ctx.baseEnv);

    await Directory(machineB.homeDir).create(recursive: true);
    await reader(['init', remote, '--key-file', keyFile], env: machineB.env);
    await reader(['pull', '-y'], env: machineB.env);

    expect(
      await File(
        p.join(machineB.homeDir, '.config', 'app', 'config.toml'),
      ).readAsString(),
      'key = value\n',
    );
    expect(
      await File(
        p.join(machineB.homeDir, '.config', 'app', 'secret.env'),
      ).readAsString(),
      'TOKEN=$label-secret\n',
    );
    expect(
      await File(
        p.join(machineB.homeDir, '.config', 'tooldir', 'nested', 'deep.txt'),
      ).readAsString(),
      'deep\n',
    );

    if (!Platform.isWindows) {
      final linkB = p.join(machineB.homeDir, '.config', 'link.toml');

      expect(
        FileSystemEntity.typeSync(linkB, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(await readLinkTarget(linkB), 'app/config.toml');
      expect(await File(linkB).readAsString(), 'key = value\n');
    }

    expectCleanStatus(await reader(['status'], env: machineB.env));
  }

  group('cross-CLI compatibility', () {
    test('TS writes, Dart reads: same machine + machine B pull', () async {
      await writerReaderScenario(
        writer: tsCli,
        reader: dartCli,
        label: 'ts-writes',
      );
    });

    test('Dart writes, TS reads: same machine + machine B pull', () async {
      await writerReaderScenario(
        writer: dartCli,
        reader: tsCli,
        label: 'dart-writes',
      );
    });

    test(
      'byte parity: twin init+track sequences write identical config',
      () async {
        const plaintext = 'TOKEN=twin-secret\n';
        final keys = await ctx.createAgeKeyPair();
        final tsMachine = createMachineEnv(
          ctx.workspace,
          'twin-ts',
          ctx.baseEnv,
        );
        final dartMachine = createMachineEnv(
          ctx.workspace,
          'twin-dart',
          ctx.baseEnv,
        );

        for (final machine in [tsMachine, dartMachine]) {
          final twinDir = p.join(machine.homeDir, '.config', 'twin');

          await fixture.writeIdentityFile(machine.xdgDir, keys.identity);
          await Directory(p.join(twinDir, 'nested')).create(recursive: true);
          await File(
            p.join(twinDir, 'config.toml'),
          ).writeAsString('key = value\n');
          await File(
            p.join(twinDir, 'nested', 'deep.txt'),
          ).writeAsString('deep\n');
          await File(p.join(twinDir, 'secret.env')).writeAsString(plaintext);
        }

        // The same fixed sequence, run separately by each CLI in its own
        // workspace.
        Future<void> sequence(
          CliRunner run,
          ({
            Map<String, String> env,
            String homeDir,
            String localAppDataDir,
            String xdgDir,
          })
          machine,
        ) async {
          final twinDir = p.join(machine.homeDir, '.config', 'twin');

          await run(['init'], env: machine.env);
          await run(['track', twinDir], env: machine.env);
          await run([
            'track',
            p.join(twinDir, 'secret.env'),
            '--mode',
            'secret',
          ], env: machine.env);
          await run(['push'], env: machine.env);
        }

        await sequence(tsCli, tsMachine);
        await sequence(dartCli, dartMachine);

        // settings.jsonc and manifest.jsonc must be byte-identical.
        Future<List<int>> bytesOf(String xdgDir, List<String> parts) {
          return File(p.joinAll([xdgDir, ...parts])).readAsBytes();
        }

        expect(
          await bytesOf(dartMachine.xdgDir, ['dotweave', 'settings.jsonc']),
          await bytesOf(tsMachine.xdgDir, ['dotweave', 'settings.jsonc']),
        );
        expect(
          await bytesOf(dartMachine.xdgDir, [
            'dotweave',
            'repository',
            'manifest.jsonc',
          ]),
          await bytesOf(tsMachine.xdgDir, [
            'dotweave',
            'repository',
            'manifest.jsonc',
          ]),
        );

        // Identical relative path sets in the repository trees.
        final tsFiles = await listRepositoryFiles(tsMachine.xdgDir);
        final dartFiles = await listRepositoryFiles(dartMachine.xdgDir);

        expect(dartFiles, tsFiles);

        // Plain artifacts byte-identical; age ciphertexts are nondeterministic
        // so they must differ but cross-decrypt to the same plaintext.
        const secretArtifact =
            'profiles/default/.config/twin/secret.env.dotweave.secret';

        for (final file in tsFiles) {
          if (file == secretArtifact) {
            continue;
          }

          expect(
            await bytesOf(dartMachine.xdgDir, [
              'dotweave',
              'repository',
              ...file.split('/'),
            ]),
            await bytesOf(tsMachine.xdgDir, [
              'dotweave',
              'repository',
              ...file.split('/'),
            ]),
            reason: 'repository artifact $file must be byte-identical',
          );
        }

        final tsSecret = await readRepositoryArtifact(
          tsMachine.xdgDir,
          'default',
          '.config/twin/secret.env.dotweave.secret',
        );
        final dartSecret = await readRepositoryArtifact(
          dartMachine.xdgDir,
          'default',
          '.config/twin/secret.env.dotweave.secret',
        );

        expect(tsSecret, contains('BEGIN AGE ENCRYPTED FILE'));
        expect(dartSecret, contains('BEGIN AGE ENCRYPTED FILE'));
        expect(dartSecret, isNot(tsSecret));

        // Dart-decrypt(TS-secret) == TS-decrypt(Dart-secret) == plaintext.
        final decrypter = AgeDecrypter()..addIdentity(keys.identity);

        expect(
          utf8.decode(await decrypter.decrypt(armorDecode(tsSecret))),
          plaintext,
        );
        expect(
          utf8.decode(await tsAgeDecrypt(keys.identity, dartSecret)),
          plaintext,
        );
      },
    );

    test('interleaved ping-pong: TS and Dart alternate on one repo', () async {
      final remote = p.join(ctx.workspace, 'remote-pingpong.git');
      final keyFile = p.join(ctx.workspace, 'pingpong.agekey');
      final keys = await ctx.createAgeKeyPair();

      await ctx.runGit(['init', '--bare', '-b', 'main', remote]);
      await ctx.writeIdentityFile(keys.identity);
      await File(keyFile).writeAsString('${keys.identity}\n');

      final pingDir = p.join(ctx.homeDir, '.config', 'ping');
      final oneFile = p.join(pingDir, 'one.txt');
      final twoFile = p.join(pingDir, 'two.txt');

      await Directory(pingDir).create(recursive: true);
      await File(oneFile).writeAsString('one\n');
      await File(twoFile).writeAsString('two\n');

      // TS: init, track the first file, push.
      await tsCli(['init', remote]);
      await tsCli(['track', oneFile]);
      await tsCli(['push']);
      await commitAndPushRepo(ctx.xdgDir, 'ts adds one', setUpstream: true);
      expectCleanStatus(await dartCli(['status']));

      // Dart: track the second file, push.
      await dartCli(['track', twoFile]);
      await dartCli(['push']);
      await commitAndPushRepo(ctx.xdgDir, 'dart adds two');
      expectCleanStatus(await tsCli(['status']));

      // Machine B: TS clone + pull materializes both files.
      final machineB = createMachineEnv(
        ctx.workspace,
        'pingpong-b',
        ctx.baseEnv,
      );
      final oneFileB = p.join(machineB.homeDir, '.config', 'ping', 'one.txt');
      final twoFileB = p.join(machineB.homeDir, '.config', 'ping', 'two.txt');

      await Directory(machineB.homeDir).create(recursive: true);
      await tsCli(['init', remote, '--key-file', keyFile], env: machineB.env);
      await tsCli(['pull', '-y'], env: machineB.env);

      expect(await File(oneFileB).readAsString(), 'one\n');
      expect(await File(twoFileB).readAsString(), 'two\n');
      expectCleanStatus(await tsCli(['status'], env: machineB.env));

      // Machine A: Dart untracks the first file and pushes; the artifact is
      // pruned from the repository and TS agrees the workspace is clean.
      await dartCli(['untrack', '.config/ping/one.txt']);
      await dartCli(['push']);
      fixture.expectPathAbsent(
        p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'default',
          '.config',
          'ping',
          'one.txt',
        ),
      );
      await commitAndPushRepo(ctx.xdgDir, 'dart untracks one');
      expectCleanStatus(await tsCli(['status']));

      // Machine B: update the clone; TS status/pull agree, and the untracked
      // file's local copy is left alone.
      final repoDirB = p.join(machineB.xdgDir, 'dotweave', 'repository');

      await ctx.runGit(['pull'], repoDirB);
      expectCleanStatus(await tsCli(['status'], env: machineB.env));
      await tsCli(['pull', '-y'], env: machineB.env);
      expect(await File(oneFileB).readAsString(), 'one\n');
      expect(await File(twoFileB).readAsString(), 'two\n');
      expectCleanStatus(await tsCli(['status'], env: machineB.env));
    });

    test(
      'output parity: version, help, clean status, validation error',
      () async {
        final tsVersion = await tsCli(['--version']);
        final dartVersion = await dartCli(['--version']);

        expect(dartVersion.stdout, tsVersion.stdout);
        expect(tsVersion.stderr, '');
        expect(dartVersion.stderr, '');

        final tsHelp = await tsCli(['--help']);
        final dartHelp = await dartCli(['--help']);

        expect(dartHelp.stdout, tsHelp.stdout);
        expect(dartHelp.stderr, tsHelp.stderr);

        // Clean-workspace `status`: initialize once, then both CLIs must
        // print exactly the same report.
        final keys = await ctx.createAgeKeyPair();

        await ctx.writeIdentityFile(keys.identity);
        await dartCli(['init']);

        final tsStatus = await tsCli(['status']);
        final dartStatus = await dartCli(['status']);

        expect(dartStatus.stdout, tsStatus.stdout);
        expect(dartStatus.stderr, tsStatus.stderr);
        expect(dartStatus.exitCode, tsStatus.exitCode);

        // Validation error: identical stderr and exit code.
        final tsError = await tsCli([
          'track',
          'some-target',
          '--permission',
          'zzz',
        ], reject: false);
        final dartError = await dartCli([
          'track',
          'some-target',
          '--permission',
          'zzz',
        ], reject: false);

        expect(tsError.exitCode, isNot(0));
        expect(dartError.exitCode, tsError.exitCode);
        expect(dartError.stdout, tsError.stdout);
        expect(dartError.stderr, tsError.stderr);
      },
    );
  });
}
