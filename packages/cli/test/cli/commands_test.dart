// Dart port of `packages/cli/src/cli/commands.test.ts`.
//
// The TS suite mocks every service module (`vi.mock`) plus the CLI logger and
// asserts on mocked call arguments. The ported Dart commands call the real
// services and create their logger internally, so this port runs every test
// against a real isolated workspace (option 2 from the porting notes) and
// asserts the observable side of each behavior: captured stdout/stderr text,
// thrown errors, and filesystem effects. `IOOverrides` capture of
// `dart:io` stdout/stderr/stdin replaces the vitest logger/prompt mocks.
//
// Per-test route + delta notes are inline. Global deltas:
// - Service-call-argument assertions (`toHaveBeenCalledWith`) become manifest/
//   artifact/file assertions plus output-text assertions.
// - Paths mocked as `/tmp/...` in TS become real workspace paths.
// - The mocked spinner handles are observed through the non-TTY spinner
//   output contract: the start line is written once and `stop()` writes
//   nothing, so "stop called, succeed not called" is asserted as "start text
//   present, success text absent".

import 'dart:convert';
import 'dart:io' as io;

import 'package:dotweave/src/cli/cd.dart';
import 'package:dotweave/src/cli/doctor.dart';
import 'package:dotweave/src/cli/init.dart';
import 'package:dotweave/src/cli/profile/add.dart';
import 'package:dotweave/src/cli/profile/list.dart';
import 'package:dotweave/src/cli/profile/remove.dart';
import 'package:dotweave/src/cli/profile/use.dart';
import 'package:dotweave/src/cli/pull.dart';
import 'package:dotweave/src/cli/push.dart';
import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/cli/skill/install.dart';
import 'package:dotweave/src/cli/status.dart';
import 'package:dotweave/src/cli/track.dart';
import 'package:dotweave/src/cli/untrack.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/services/sync_mode.dart';
import 'package:dotweave/src/services/track.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/capture_stream.dart';
import '../helpers/sync_fixture.dart';

// ---------------------------------------------------------------------------
// Harness: IOOverrides-based stdout/stderr/stdin capture
// ---------------------------------------------------------------------------

/// Captures `dart:io` stdout/stderr writes issued by the command loggers
/// (the seam replacing the vitest `createCliLogger` module mock).
class _RecordingStdout implements io.Stdout {
  final StringBuffer _buffer = StringBuffer();

  @override
  bool get hasTerminal => false;

  @override
  void write(Object? object) {
    _buffer.write(object);
  }

  @override
  void writeln([Object? object = '']) {
    _buffer.writeln(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _buffer.writeCharCode(charCode);
  }

  String get text => _buffer.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'Stdout member ${invocation.memberName} is not supported in '
      'commands_test.',
    );
  }
}

/// Scripted stdin standing in for the TS `mocked.promptAsk` /
/// `process.stdin.isTTY` stubs. Reading past the scripted lines throws so
/// "prompt not called" assertions fail loudly when a prompt does happen.
class _StubStdin implements io.Stdin {
  _StubStdin({required this.hasTerminal, List<String> lines = const []})
    : _lines = [...lines];

  @override
  final bool hasTerminal;

  final List<String> _lines;

  @override
  String? readLineSync({
    Encoding encoding = io.systemEncoding,
    bool retainNewlines = false,
  }) {
    if (_lines.isEmpty) {
      throw StateError('Unexpected interactive prompt read from stdin.');
    }

    return _lines.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'Stdin member ${invocation.memberName} is not supported in '
      'commands_test.',
    );
  }
}

/// Result of invoking a command function directly (the TS `runCommand`
/// helper); output is captured with ANSI sequences stripped (the TS
/// `withoutAnsi` helper) and thrown errors are surfaced for `rejects`-style
/// assertions.
class _CommandRun {
  const _CommandRun({
    required this.stdout,
    required this.stderr,
    required this.error,
  });

  final String stdout;
  final String stderr;
  final Object? error;

  List<String> get stdoutLines => const LineSplitter().convert(stdout);
}

/// Mirror of the TS `runCommand` helper: loads the command function through
/// `command.loader()` and invokes it with the given flags/positional values.
Future<_CommandRun> _runCommand(
  Command command,
  Map<String, Object?> flags,
  List<Object?> positional, {
  bool stdinIsTTY = true,
  List<String> stdinLines = const [],
}) async {
  final capturedStdout = _RecordingStdout();
  final capturedStderr = _RecordingStdout();
  final stdinStub = _StubStdin(hasTerminal: stdinIsTTY, lines: stdinLines);
  Object? thrown;

  await io.IOOverrides.runZoned(
    () async {
      final func = await command.loader();
      final context = RunContext(
        process: RunProcess(stdout: CaptureStream(), stderr: CaptureStream()),
      );

      try {
        await func(context, flags, positional);
      } catch (error) {
        thrown = error;
      }
    },
    stdout: () => capturedStdout,
    stderr: () => capturedStderr,
    stdin: () => stdinStub,
    // The SDK's default `IOOverrides.fseGetType` mis-encodes the path (no
    // NUL terminator), making every async `FileSystemEntity.type` call
    // report notFound inside the zone; delegate to the working sync variant.
    fseGetType: (String path, bool followLinks) async {
      return io.FileSystemEntity.typeSync(path, followLinks: followLinks);
    },
  );

  return _CommandRun(
    stdout: stripAnsi(capturedStdout.text),
    stderr: stripAnsi(capturedStderr.text),
    error: thrown,
  );
}

// ---------------------------------------------------------------------------
// Harness: real workspace setup (replaces the vitest service mocks)
// ---------------------------------------------------------------------------

class _Workspace {
  const _Workspace({
    required this.root,
    required this.home,
    required this.xdgConfigHome,
    required this.identity,
    required this.recipient,
  });

  final String root;
  final String home;
  final String xdgConfigHome;
  final String identity;
  final String recipient;

  String get dotweaveHome => p.join(xdgConfigHome, 'dotweave');
  String get syncDirectory => p.join(dotweaveHome, 'repository');
  String get identityFile => p.join(dotweaveHome, 'keys.txt');
  String get manifestPath => p.join(syncDirectory, 'manifest.jsonc');

  String homePath(String posixRelativePath) {
    return p.joinAll([home, ...posixRelativePath.split('/')]);
  }

  String artifactPath(String profile, String posixRepoPath) {
    return p.joinAll([
      syncDirectory,
      'profiles',
      profile,
      ...posixRepoPath.split('/'),
    ]);
  }
}

/// Creates an isolated workspace and routes all dotweave env reads to it.
/// With [initialize] the sync repository is bootstrapped through the real
/// init service (like the sync service integration suites).
Future<_Workspace> _setUpWorkspace({
  bool writeIdentity = true,
  bool initialize = true,
  int extraRecipients = 0,
}) async {
  final root = await createWorkspace('dotweave-commands-');
  final home = p.join(root, 'home');
  final xdgConfigHome = p.join(root, 'xdg');

  await io.Directory(home).create(recursive: true);

  final keys = await createAgeKeyPair();

  if (writeIdentity) {
    await writeIdentityFile(xdgConfigHome, keys.identity);
  }

  setEnvironment(home, xdgConfigHome);

  if (initialize) {
    final recipients = [keys.recipient];

    for (var index = 0; index < extraRecipients; index += 1) {
      recipients.add((await createAgeKeyPair()).recipient);
    }

    await initializeSyncDirectory(InitRequest(recipients: recipients));
  }

  return _Workspace(
    root: root,
    home: home,
    xdgConfigHome: xdgConfigHome,
    identity: keys.identity,
    recipient: keys.recipient,
  );
}

Future<void> _writeHomeFile(
  _Workspace workspace,
  String posixRelativePath,
  String contents,
) async {
  final path = workspace.homePath(posixRelativePath);

  await io.Directory(p.dirname(path)).create(recursive: true);
  await io.File(path).writeAsString(contents);
}

Future<List<Map<String, Object?>>> _manifestEntries(
  _Workspace workspace,
) async {
  return parseManifestEntries(
    await io.File(workspace.manifestPath).readAsString(),
  );
}

/// Creates a bare git repository usable as an init clone source.
Future<String> _createSourceRepository(_Workspace workspace) async {
  final source = p.join(workspace.root, 'source.git');

  await runGit(['init', '--bare', source]);

  return source;
}

DotweaveError _dotweaveError(Object? error) {
  expect(error, isA<DotweaveError>());

  return error as DotweaveError;
}

Object? _describeFlag(Flag flag) {
  return switch (flag) {
    BooleanFlag() => {'kind': 'boolean', 'brief': flag.brief},
    CounterFlag() => {'kind': 'counter', 'brief': flag.brief},
    EnumFlag() => {'kind': 'enum', 'brief': flag.brief, 'values': flag.values},
    ParsedFlag() => {
      'kind': 'parsed',
      'brief': flag.brief,
      if (flag.placeholder != null) 'placeholder': flag.placeholder,
      'variadic': flag.variadic,
    },
  };
}

void main() {
  tearDown(cleanUpSyncFixture);

  group('CLI command modules', () {
    test('initializes without a repository and generates an identity when none '
        'exists', () async {
      // Real-workspace route: no identity, no repository argument. The TS
      // assertions on `initializeSyncDirectory` arguments become their
      // effects: an identity is generated and a fresh repository is
      // initialized without prompting.
      final workspace = await _setUpWorkspace(
        writeIdentity: false,
        initialize: false,
      );

      final run = await _runCommand(initCommand, {}, [null]);

      expect(run.error, isNull);
      // `promptAsk` not called: scripted stdin would have thrown and the
      // prompt question was never written.
      expect(run.stdout, isNot(contains('Enter the age private key')));
      expect(run.stdout, contains('Sync directory initialized'));
      expect(run.stdout, contains('initialized new repository'));
      expect(run.stdout, contains('generated a new local identity'));
      expect(run.stdout, contains('0 entries · 1 recipients'));
      expect(await io.File(workspace.identityFile).exists(), isTrue);
      expect(await io.File(workspace.manifestPath).exists(), isTrue);
    });

    test('initializes with force without a repository and treats an existing '
        'identity as reset', () async {
      final workspace = await _setUpWorkspace(initialize: false);
      final previousIdentity = await io.File(
        workspace.identityFile,
      ).readAsString();

      final run = await _runCommand(initCommand, {'force': true}, [null]);

      expect(run.error, isNull);
      expect(run.stdout, isNot(contains('Enter the age private key')));
      expect(run.stdout, contains('generated a new local identity'));
      // `generateAgeIdentity: true` despite the pre-existing identity: the
      // file was regenerated, not preserved.
      final nextIdentity = await io.File(workspace.identityFile).readAsString();
      expect(nextIdentity, isNot(previousIdentity));
    });

    test('initializes from a repository without prompting when an identity '
        'exists', () async {
      final workspace = await _setUpWorkspace(initialize: false);
      final source = await _createSourceRepository(workspace);

      final run = await _runCommand(initCommand, {}, [source]);

      expect(run.error, isNull);
      expect(run.stdout, isNot(contains('Enter the age private key')));
      expect(run.stdout, contains('cloned from $source'));
      expect(run.stdout, contains('using existing identity'));
      // `generateAgeIdentity: false`: the existing identity is untouched.
      expect(
        await io.File(workspace.identityFile).readAsString(),
        '${workspace.identity}\n',
      );
    });

    test(
      'initializes from a repository with an age key file without prompting',
      () async {
        final workspace = await _setUpWorkspace(
          writeIdentity: false,
          initialize: false,
        );
        final source = await _createSourceRepository(workspace);
        final importedKeys = await createAgeKeyPair();
        final keyFile = p.join(workspace.root, 'import.agekey');

        // The TS mock returns "  AGE-SECRET-KEY-FILE  \n"; a real identity is
        // required here, padded the same way to exercise the trim.
        await io.File(keyFile).writeAsString('  ${importedKeys.identity}  \n');

        final run = await _runCommand(
          initCommand,
          {'keyFile': keyFile},
          [source],
        );

        expect(run.error, isNull);
        expect(run.stdout, isNot(contains('Enter the age private key')));
        // Spinner succeed("Sync directory initialized").
        expect(run.stdout, contains('✔ Sync directory initialized'));
        // The trimmed key-file contents became the identity.
        expect(
          await io.File(workspace.identityFile).readAsString(),
          contains(importedKeys.identity),
        );
      },
    );

    test(
      'initializes with force from a repository with an age key file without '
      'prompting',
      () async {
        final workspace = await _setUpWorkspace(initialize: false);
        final source = await _createSourceRepository(workspace);
        final importedKeys = await createAgeKeyPair();
        final keyFile = p.join(workspace.root, 'force.agekey');

        await io.File(keyFile).writeAsString('${importedKeys.identity}\n');

        final run = await _runCommand(
          initCommand,
          {'force': true, 'keyFile': keyFile},
          [source],
        );

        expect(run.error, isNull);
        expect(run.stdout, isNot(contains('Enter the age private key')));
        final identityContents = await io.File(
          workspace.identityFile,
        ).readAsString();
        expect(identityContents, contains(importedKeys.identity));
        expect(identityContents, isNot(contains(workspace.identity)));
      },
    );

    test('initializes without a repository using an age key file without '
        'generating', () async {
      final workspace = await _setUpWorkspace(
        writeIdentity: false,
        initialize: false,
      );
      final importedKeys = await createAgeKeyPair();
      final keyFile = p.join(workspace.root, 'local.agekey');

      await io.File(keyFile).writeAsString('${importedKeys.identity}\n');

      final run = await _runCommand(initCommand, {'keyFile': keyFile}, [null]);

      expect(run.error, isNull);
      expect(run.stdout, isNot(contains('Enter the age private key')));
      expect(run.stdout, contains('initialized new repository'));
      // `generateAgeIdentity: false`: the identity is the imported key.
      expect(
        await io.File(workspace.identityFile).readAsString(),
        contains(importedKeys.identity),
      );
    });

    test('initializes with force from a repository by prompting even when an '
        'identity exists', () async {
      final workspace = await _setUpWorkspace(initialize: false);
      final source = await _createSourceRepository(workspace);
      final promptedKeys = await createAgeKeyPair();

      final run = await _runCommand(
        initCommand,
        {'force': true},
        [source],
        stdinLines: ['  ${promptedKeys.identity}  '],
      );

      expect(run.error, isNull);
      expect(
        run.stdout,
        contains('Enter the age private key for the existing repository: '),
      );
      // The trimmed prompted key became the identity (force replaced the
      // pre-existing one).
      final identityContents = await io.File(
        workspace.identityFile,
      ).readAsString();
      expect(identityContents, contains(promptedKeys.identity));
      expect(identityContents, isNot(contains(workspace.identity)));
    });

    test(
      'stops the init spinner when repository initialization rejects',
      () async {
        final workspace = await _setUpWorkspace(initialize: false);
        final missingSource = p.join(workspace.root, 'missing-source.git');

        final run = await _runCommand(initCommand, {}, [missingSource]);

        final error = _dotweaveError(run.error);
        expect(error.message, 'Failed to clone the sync directory.');
        // Non-TTY spinner contract: start line written, `stop()` writes
        // nothing, and neither succeed nor fail output appears.
        expect(run.stdout, contains('Cloning repository...'));
        expect(run.stdout, isNot(contains('Sync directory initialized')));
        expect(run.stdout, isNot(contains('✔')));
        expect(run.stdout, isNot(contains('✖')));
      },
    );

    test(
      'rejects a blank prompted key when importing an existing repository',
      () async {
        final workspace = await _setUpWorkspace(
          writeIdentity: false,
          initialize: false,
        );

        final run = await _runCommand(
          initCommand,
          {},
          ['origin'],
          stdinLines: ['   '],
        );

        final error = _dotweaveError(run.error);
        expect(
          error.message,
          contains('Existing repository setup requires an age private key'),
        );
        expect(
          run.stdout,
          contains('Enter the age private key for the existing repository: '),
        );
        // `initializeSyncDirectory` was never called: nothing was created.
        expect(await io.Directory(workspace.syncDirectory).exists(), isFalse);
        expect(await io.File(workspace.identityFile).exists(), isFalse);
      },
    );

    test('exposes only force and key-file flags for init credentials', () {
      expect(initCommand.parameters.flags.keys.toList()..sort(), [
        'force',
        'keyFile',
      ]);
    });

    test('exposes kind, local, repo, mode, permission, and profile flags for '
        'track', () {
      expect(trackCommand.parameters.flags.keys.toList()..sort(), [
        'kind',
        'local',
        'mode',
        'permission',
        'profile',
        'repo',
      ]);
    });

    test('does not expose missing target shortcut flags for track', () {
      final flagKeys = trackCommand.parameters.flags.keys.toList();

      expect(flagKeys, isNot(contains('missingOk')));
      expect(flagKeys, isNot(contains('missing-ok')));
    });

    test('documents track platform flag grammar without removed shortcuts', () {
      // The TS test JSON.stringifies the flag definitions; the Dart flags are
      // not JSON-encodable objects, so an equivalent JSON description (brief,
      // placeholder, values) is built for the same text assertions.
      final flagText = jsonEncode({
        for (final entry in trackCommand.parameters.flags.entries)
          entry.key: _describeFlag(entry.value),
      });

      expect(flagText, contains('path|platform=path'));
      expect(flagText, contains('mode|platform=mode'));
      expect(flagText, contains('octal|platform=octal'));
      expect(
        RegExp(
          r'--repo-path|--secret|--normal|--ignore|--missing-ok',
        ).hasMatch(flagText),
        isFalse,
      );
    });

    test('tracks new targets and formats track output', () async {
      final workspace = await _setUpWorkspace();

      await addProfile('work');
      await _writeHomeFile(workspace, '.gitconfig', '[user]\nname=test\n');

      // The TS test passes the cwd-relative target ".gitconfig"; the real
      // workspace uses the home-anchored spelling so the target resolves
      // inside the isolated HOME instead of the test process cwd.
      final run = await _runCommand(
        trackCommand,
        {
          'mode': ['secret'],
          'profile': ['work'],
          'repo': ['profiles/work/.gitconfig'],
        },
        ['~/.gitconfig'],
      );

      expect(run.error, isNull);
      expect(run.stdout, contains('Started tracking profiles/work/.gitconfig'));
      expect(run.stdout, contains(RegExp(r'kind\s+file')));
      expect(run.stdout, contains(RegExp(r'path\s+\S')));
      expect(run.stdout, contains(workspace.homePath('.gitconfig')));
      expect(run.stdout, contains(RegExp(r'repo\s+profiles/work/\.gitconfig')));
      expect(run.stdout, contains(RegExp(r'mode\s+secret')));
      expect(run.stdout, contains(RegExp(r'profiles\s+work')));
      // DELTA: the TS mock invented a configured permission ("0600"); the
      // real track service records no permission when --permission is absent,
      // so no permission row is rendered.
      expect(run.stdout, isNot(contains('permission')));

      final entries = await _manifestEntries(workspace);
      expect(entries, [
        {
          'kind': 'file',
          'localPath': {'default': '~/.gitconfig'},
          'repoPath': {'default': 'profiles/work/.gitconfig'},
          'mode': {'default': 'secret'},
          'profiles': ['work'],
        },
      ]);
    });

    test('omits absent optional fields from track output', () async {
      final workspace = await _setUpWorkspace();

      await io.Directory(
        workspace.homePath('.config/app'),
      ).create(recursive: true);

      final run = await _runCommand(
        trackCommand,
        {'kind': 'directory'},
        ['~/.config/app'],
      );

      expect(run.error, isNull);

      final detailRows = run.stdoutLines
          .where((line) => line.startsWith('  '))
          .toList();
      expect(
        detailRows,
        [
          'kind  directory',
          'path  ${workspace.homePath('.config/app')}',
          'repo  .config/app',
          'mode  normal',
        ].map((row) => '  $row').toList(),
      );
    });

    test('passes explicit target kind to track service', () async {
      final workspace = await _setUpWorkspace();

      final run = await _runCommand(
        trackCommand,
        {
          'kind': 'file',
          'mode': ['normal'],
        },
        ['~/.config/future.toml'],
      );

      expect(run.error, isNull);

      final entries = await _manifestEntries(workspace);
      expect(entries, hasLength(1));
      expect(entries[0]['kind'], 'file');
      expect(entries[0]['localPath'], {'default': '~/.config/future.toml'});
    });

    test('passes explicit permission to track service', () async {
      final workspace = await _setUpWorkspace();

      await _writeHomeFile(workspace, '.ssh/config', 'Host example\n');

      final run = await _runCommand(
        trackCommand,
        {
          'mode': ['normal'],
          'permission': ['0600'],
        },
        ['~/.ssh/config'],
      );

      expect(run.error, isNull);
      expect(run.stdout, contains(RegExp(r'permission\s+0600')));

      final entries = await _manifestEntries(workspace);
      expect(entries, hasLength(1));
      expect(entries[0]['permission'], {'default': '0600'});
    });

    test('rejects invalid permission before tracking', () async {
      final workspace = await _setUpWorkspace();

      await _writeHomeFile(workspace, '.ssh/config', 'Host example\n');

      final run = await _runCommand(
        trackCommand,
        {
          'mode': ['normal'],
          'permission': ['600'],
        },
        ['~/.ssh/config'],
      );

      final error = _dotweaveError(run.error);
      expect(error.code, 'INVALID_PERMISSION');
      // `trackTarget` was never reached: no entry was written.
      expect(await _manifestEntries(workspace), isEmpty);
    });

    test('passes platform-aware repo paths to track service', () async {
      final workspace = await _setUpWorkspace();

      await io.Directory(
        workspace.homePath('.config/app'),
      ).create(recursive: true);

      final run = await _runCommand(
        trackCommand,
        {
          'mode': ['normal'],
          'repo': ['.config/app', 'win=AppData/Roaming/App'],
        },
        ['~/.config/app'],
      );

      expect(run.error, isNull);

      final entries = await _manifestEntries(workspace);
      expect(entries, hasLength(1));
      expect(entries[0]['repoPath'], {
        'default': '.config/app',
        'win': 'AppData/Roaming/App',
      });
    });

    test('passes platform-aware modes to track service', () async {
      final workspace = await _setUpWorkspace();

      await io.Directory(
        workspace.homePath('.config/app'),
      ).create(recursive: true);

      final run = await _runCommand(
        trackCommand,
        {
          'mode': ['normal', 'win=ignore'],
        },
        ['~/.config/app'],
      );

      expect(run.error, isNull);

      final entries = await _manifestEntries(workspace);
      expect(entries, hasLength(1));
      expect(entries[0]['mode'], {'default': 'normal', 'win': 'ignore'});
    });

    test('passes local platform overrides to track service', () async {
      final workspace = await _setUpWorkspace();

      await io.Directory(
        workspace.homePath('.config/app'),
      ).create(recursive: true);

      final run = await _runCommand(
        trackCommand,
        {
          'local': ['win=%APPDATA%/App'],
          'mode': ['normal'],
        },
        ['~/.config/app'],
      );

      expect(run.error, isNull);

      final entries = await _manifestEntries(workspace);
      expect(entries, hasLength(1));
      expect(entries[0]['localPath'], {
        'default': '~/.config/app',
        'win': '%APPDATA%/App',
      });
    });

    test('rejects default local values before tracking', () async {
      final workspace = await _setUpWorkspace();

      await io.Directory(
        workspace.homePath('.config/app'),
      ).create(recursive: true);

      final bareRun = await _runCommand(
        trackCommand,
        {
          'local': ['.config/app'],
          'mode': ['normal'],
        },
        ['~/.config/app'],
      );
      expect(_dotweaveError(bareRun.error).code, 'INVALID_PLATFORM_FLAG');

      final defaultRun = await _runCommand(
        trackCommand,
        {
          'local': ['default=.config/app'],
          'mode': ['normal'],
        },
        ['~/.config/app'],
      );
      expect(_dotweaveError(defaultRun.error).code, 'INVALID_PLATFORM_FLAG');

      // `trackTarget` was never reached.
      expect(await _manifestEntries(workspace), isEmpty);
    });

    test(
      'installs the bundled dotweave skill and reports the target path',
      () async {
        final skillsRoot = await createWorkspace('dotweave-skills-');

        final run = await _runCommand(
          skillInstallCommand,
          {'dryRun': true, 'force': true},
          [skillsRoot],
        );

        expect(run.error, isNull);
        expect(run.stdout, contains('Would install dotweave skill'));
        final targetPath = p.join(skillsRoot, 'dotweave', 'SKILL.md');
        expect(run.stdout, contains('  target: $targetPath'));
        // Dry run: nothing was written.
        expect(await io.File(targetPath).exists(), isFalse);
      },
    );

    test('rejects --repo when tracking multiple targets', () async {
      final workspace = await _setUpWorkspace();

      await _writeHomeFile(workspace, '.gitconfig', 'a\n');
      await _writeHomeFile(workspace, '.zshrc', 'b\n');

      final run = await _runCommand(
        trackCommand,
        {
          'mode': ['normal'],
          'repo': ['profiles/shared/tool'],
        },
        ['~/.gitconfig', '~/.zshrc'],
      );

      final error = _dotweaveError(run.error);
      expect(
        error.message,
        'The --repo flag can only be used with a single sync target.',
      );
      expect(await _manifestEntries(workspace), isEmpty);
    });

    test(
      'falls back to mode updates when tracking finds an existing target',
      () async {
        // DELTA: the TS test forces `trackTarget` to reject with
        // TARGET_NOT_FOUND via a mock, which drives the CLI fallback into
        // `setTargetMode`/`assignProfiles`. The real track service never
        // throws TARGET_NOT_FOUND (only sync-mode's `setTargetMode` does), so
        // the fallback branch is unreachable through the real services and
        // this port asserts the real observable outcome of the same
        // invocation: a nonexistent target without --kind fails with
        // TARGET_KIND_REQUIRED before any mode update is written.
        final workspace = await _setUpWorkspace();

        final run = await _runCommand(
          trackCommand,
          {
            'mode': ['ignore'],
            'profile': [''],
          },
          ['~/.config/nvim'],
        );

        final error = _dotweaveError(run.error);
        expect(error.code, 'TARGET_KIND_REQUIRED');
        expect(run.stdout, isNot(contains('Updated sync mode')));
        expect(await _manifestEntries(workspace), isEmpty);
      },
    );

    test(
      'validates fallback track profiles before writing mode updates',
      () async {
        // Real-workspace route: 'ghost' is unregistered, so the profile
        // validation rejects before any mode update is written. (The real
        // rejection comes from `trackTarget`'s own profile validation rather
        // than the mocked fallback's `validateProfilesExist`; the observable
        // contract — the same error and no config writes — is identical.)
        final workspace = await _setUpWorkspace();

        final run = await _runCommand(
          trackCommand,
          {
            'mode': ['ignore'],
            'profile': ['ghost'],
          },
          ['~/.config/nvim'],
        );

        final error = _dotweaveError(run.error);
        expect(error.message, "Unknown profile 'ghost'.");
        expect(error.code, 'UNKNOWN_PROFILE');
        expect(run.stdout, isNot(contains('Updated sync mode')));
        expect(await _manifestEntries(workspace), isEmpty);
      },
    );

    test('lists, adds, removes, uses, and clears profiles', () async {
      // Real-workspace route. The TS test runs list/add/remove/use/clear
      // against one mocked state; real profile semantics forbid that exact
      // sequence (adding an existing profile or removing the active profile
      // throws), so the registry is adjusted through the real profile service
      // between command invocations to keep every step valid.
      await _setUpWorkspace();
      await addProfile('personal');
      await addProfile('work');
      await setActiveProfile('work');

      final listRun = await _runCommand(profileListCommand, {}, []);
      expect(listRun.error, isNull);
      expect(listRun.stdout, contains('Profiles'));
      expect(listRun.stdout, contains('  - personal'));
      expect(listRun.stdout, contains('  - work (active)'));
      expect(listRun.stdout, isNot(contains('restricted entries')));
      expect(listRun.stderr, isNot(contains('restricted entries')));

      await clearActiveProfile();
      await removeProfile('work');

      final addRun = await _runCommand(profileAddCommand, {}, ['work']);
      expect(addRun.error, isNull);
      expect(addRun.stdout, contains('Added profile work'));

      final removeRun = await _runCommand(profileRemoveCommand, {}, ['work']);
      expect(removeRun.error, isNull);
      expect(removeRun.stdout, contains('Removed profile work'));

      await addProfile('work');

      final useRun = await _runCommand(profileUseCommand, {}, ['work']);
      expect(useRun.error, isNull);
      expect(useRun.stdout, contains('Active profile set to work'));

      final clearRun = await _runCommand(profileUseCommand, {}, [null]);
      expect(clearRun.error, isNull);
      expect(clearRun.stdout, contains('Active profile cleared'));
    });

    test(
      'warns when listing profiles with an unregistered active profile',
      () async {
        final workspace = await _setUpWorkspace();

        // Write settings.jsonc directly: `profile use ghost` would reject.
        final globalConfigPath = resolveDotweaveGlobalConfigFilePathFromEnv();
        await io.File(globalConfigPath).writeAsString(
          '${jsonStringify({'activeProfile': 'ghost', 'version': 3})}\n',
        );

        final run = await _runCommand(profileListCommand, {}, []);

        expect(run.error, isNull);
        expect(
          run.stderr,
          contains(
            "Active profile 'ghost' is not registered in manifest.jsonc.",
          ),
        );
        expect(workspace.manifestPath, isNotEmpty);
      },
    );

    test(
      'marks default active when listing profiles without an explicit active '
      'profile',
      () async {
        await _setUpWorkspace();
        await addProfile('work');

        // Remove settings.jsonc so no explicit active profile exists (init
        // writes one with the default profile).
        await io.File(resolveDotweaveGlobalConfigFilePathFromEnv()).delete();

        final run = await _runCommand(profileListCommand, {}, []);

        expect(run.error, isNull);

        final listLines = run.stdoutLines
            .where((line) => line.startsWith('  - '))
            .toList();
        expect(listLines, ['  - default (active)', '  - work']);
      },
    );

    test(
      'passes pull, push, and status flags through with a shared reporter',
      () async {
        final workspace = await _setUpWorkspace();
        await addProfile('work');
        await _writeHomeFile(workspace, '.config/app.toml', 'from-repo\n');
        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('normal'),
            target: workspace.homePath('.config/app.toml'),
          ),
          workspace.home,
        );
        await pushChanges(const PushRequest(dryRun: false));
        await _writeHomeFile(workspace, '.config/app.toml', 'local-change\n');

        final pullRun = await _runCommand(pullCommand, {
          'dryRun': true,
          'profile': 'work',
        }, []);
        expect(pullRun.error, isNull);
        expect(pullRun.stdout, contains('Pull preview (dry run)'));
        // Dry run: `applyPullPlan` was not invoked — the local change stays.
        expect(
          await io.File(workspace.homePath('.config/app.toml')).readAsString(),
          'local-change\n',
        );

        final pushRun = await _runCommand(pushCommand, {
          'dryRun': true,
          'profile': 'work',
        }, []);
        expect(pushRun.error, isNull);
        expect(pushRun.stdout, contains('Push preview (dry run)'));
        // Dry run: the repository artifact was not updated.
        expect(
          await io.File(
            workspace.artifactPath('default', '.config/app.toml'),
          ).readAsString(),
          'from-repo\n',
        );

        final statusRun = await _runCommand(statusCommand, {
          'profile': 'work',
        }, []);
        expect(statusRun.error, isNull);
        expect(statusRun.stdout, contains('Sync status'));
        expect(statusRun.stdout, contains('Push changes'));
        expect(statusRun.stdout, contains('Pull changes'));
      },
    );

    test('stops the push spinner when push planning rejects', () async {
      // Push planning rejects for real: the sync directory was never
      // initialized in this workspace.
      await _setUpWorkspace(writeIdentity: false, initialize: false);

      final run = await _runCommand(pushCommand, {}, []);

      expect(run.error, isA<DotweaveError>());
      expect(run.stdout, contains('Pushing changes...'));
      expect(run.stdout, isNot(contains('Push complete')));
      expect(run.stdout, isNot(contains('✔')));
    });

    test('stops the prepare pull spinner when planning rejects', () async {
      await _setUpWorkspace(writeIdentity: false, initialize: false);

      final run = await _runCommand(pullCommand, {}, []);

      expect(run.error, isA<DotweaveError>());
      expect(run.stdout, contains('Preparing pull...'));
      expect(run.stdout, isNot(contains('Pull complete')));
      expect(run.stdout, isNot(contains('✔')));
    });

    test('stops the apply pull spinner when applying rejects', () async {
      // Applying rejects for real: a pushed file diverges locally and the
      // local side is made unwritable, so planning succeeds (reads only) and
      // the apply write fails.
      final workspace = await _setUpWorkspace();
      final localFile = workspace.homePath('.config/app.toml');

      await _writeHomeFile(workspace, '.config/app.toml', 'from-repo\n');
      await trackTarget(
        TrackRequest(mode: const TrackModeValue('normal'), target: localFile),
        workspace.home,
      );
      await pushChanges(const PushRequest(dryRun: false));
      await _writeHomeFile(workspace, '.config/app.toml', 'local-change\n');

      if (io.Platform.isWindows) {
        await io.Process.run('attrib', ['+R', localFile]);
      } else {
        await io.Process.run('chmod', ['555', p.dirname(localFile)]);
      }

      final run = await _runCommand(pullCommand, {'yes': true}, []);

      // Restore write access before asserting so teardown can clean up.
      if (io.Platform.isWindows) {
        await io.Process.run('attrib', ['-R', localFile]);
      } else {
        await io.Process.run('chmod', ['755', p.dirname(localFile)]);
      }

      expect(run.error, isNotNull);
      expect(run.stdout, contains('Preparing pull...'));
      expect(run.stdout, contains('Applying pull...'));
      expect(run.stdout, isNot(contains('Pull complete')));
    });

    test('stops the status spinner when status calculation rejects', () async {
      await _setUpWorkspace(writeIdentity: false, initialize: false);

      final run = await _runCommand(statusCommand, {}, []);

      expect(run.error, isA<DotweaveError>());
      expect(run.stdout, contains('Checking sync status...'));
      expect(run.stdout, isNot(contains('Sync status —')));
    });

    test(
      'formats status output for every push and pull change category',
      () async {
        // Real-workspace route covering all five change categories at once
        // (all entries assigned to profile 'work' like the TS mock's):
        // - `.config/app.toml` (file entry): pushed then locally modified →
        //   push Modify + pull Changed (the same coupling the TS mock
        //   scripted for this path).
        // - `.config/tools` (directory entry): pushed with `old.toml`
        //   inside; afterwards `new.toml` is created locally (push Add +
        //   pull Remove — a real coupling; the TS mock used a separate
        //   `obsolete.toml` for Remove) and `old.toml` is switched to an
        //   ignored child override, whose stale artifact push deletes
        //   (DELTA: the real Delete entry is the artifact key
        //   `work/.config/tools/old.toml`, not a bare repo path).
        // The ignored-child override is the third manifest entry, matching
        // the TS mock's 3-entry count.
        final workspace = await _setUpWorkspace(extraRecipients: 1);
        await addProfile('work');

        await _writeHomeFile(workspace, '.config/app.toml', 'from-repo\n');
        await _writeHomeFile(workspace, '.config/tools/old.toml', 'old\n');
        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('normal'),
            profiles: const ['work'],
            target: workspace.homePath('.config/app.toml'),
          ),
          workspace.home,
        );
        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('normal'),
            profiles: const ['work'],
            target: workspace.homePath('.config/tools'),
          ),
          workspace.home,
        );
        await pushChanges(const PushRequest(dryRun: false, profile: 'work'));

        await _writeHomeFile(workspace, '.config/app.toml', 'local-change\n');
        await _writeHomeFile(workspace, '.config/tools/new.toml', 'new\n');
        await setTargetMode(
          SetModeRequest(
            mode: 'ignore',
            target: workspace.homePath('.config/tools/old.toml'),
          ),
          workspace.home,
        );
        await assignProfiles(
          AssignProfilesRequest(
            profiles: const ['work'],
            target: workspace.homePath('.config/tools/old.toml'),
          ),
          workspace.home,
        );

        final run = await _runCommand(statusCommand, {'profile': 'work'}, []);

        expect(run.error, isNull);
        expect(
          run.stdout,
          contains('Sync status — 3 entries, 2 recipients, profile: work'),
        );

        expect(run.stdout, contains('Push changes (repository)'));
        expect(run.stdout, contains('Add (1)'));
        expect(run.stdout, contains('Modify (1)'));
        expect(run.stdout, contains('Delete (1)'));
        expect(run.stdout, contains('Pull changes (local)'));
        expect(run.stdout, contains('Changed (1)'));
        expect(run.stdout, contains('Remove (1)'));

        final logLines = run.stdoutLines;
        expect(logLines, contains('  + .config/tools/new.toml'));
        expect(logLines, contains('  ~ .config/app.toml'));
        expect(logLines, contains('  - work/.config/tools/old.toml'));
        expect(
          logLines,
          contains('  + ${workspace.homePath('.config/app.toml')}'),
        );
        expect(
          logLines,
          contains('  - ${workspace.homePath('.config/tools/new.toml')}'),
        );
      },
    );

    test('truncates long status change lists after ten items', () async {
      // Twelve tracked-but-unpushed files → push Add (12). DELTA: the file
      // names below zero-pad indices 1-9 so the real sorted order matches the
      // TS mock's insertion order (compareLocaleLike is lexicographic), and
      // the info line reports the real 12 entries (the TS mock claimed 0
      // entries while still listing 12 additions).
      final workspace = await _setUpWorkspace();

      for (var index = 1; index <= 12; index += 1) {
        final name = 'generated-${index.toString().padLeft(2, '0')}.toml';

        await _writeHomeFile(workspace, '.config/$name', 'value-$index\n');
        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('normal'),
            target: workspace.homePath('.config/$name'),
          ),
          workspace.home,
        );
      }

      final run = await _runCommand(statusCommand, {}, []);

      expect(run.error, isNull);
      expect(run.stdout, contains('Add (12)'));
      expect(
        run.stdout,
        contains('Sync status — 12 entries, 1 recipients, profile: default'),
      );

      final logLines = run.stdoutLines;
      expect(logLines, contains('  + .config/generated-10.toml'));
      expect(logLines, isNot(contains('  + .config/generated-11.toml')));
      expect(logLines, contains('  ... and 2 more'));
    });

    test('skips prompting and exits when pull has no changes', () async {
      final workspace = await _setUpWorkspace();

      await _writeHomeFile(workspace, '.config/app.toml', 'stable\n');
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: workspace.homePath('.config/app.toml'),
        ),
        workspace.home,
      );
      await pushChanges(const PushRequest(dryRun: false));

      final run = await _runCommand(pullCommand, {}, []);

      expect(run.error, isNull);
      // No prompt: the scripted stdin would have thrown on read.
      expect(run.stdout, isNot(contains('Apply these changes?')));
      expect(run.stdout, contains('Already up to date'));
    });

    test('applies pull changes after interactive confirmation', () async {
      final workspace = await _setUpPullChangesWorkspace();

      final run = await _runCommand(pullCommand, {}, [], stdinLines: ['y']);

      expect(run.error, isNull);
      expect(run.stdout, contains('Apply these changes? [y/N] '));
      expect(run.stdout, contains('Pull complete'));
      // `applyPullPlan` ran: the local change was reverted and the obsolete
      // file removed.
      expect(
        await io.File(
          workspace.homePath('.config/app/config.toml'),
        ).readAsString(),
        'from-repo\n',
      );
      expect(
        await io.File(workspace.homePath('.config/app/obsolete.txt')).exists(),
        isFalse,
      );
    });

    test('cancels pull changes when confirmation is not y', () async {
      final workspace = await _setUpPullChangesWorkspace();

      final run = await _runCommand(pullCommand, {}, [], stdinLines: ['n']);

      expect(run.error, isNull);
      expect(run.stdout, contains('Skipped pull changes'));
      // `applyPullPlan` did not run: everything stays as-is.
      expect(
        await io.File(
          workspace.homePath('.config/app/config.toml'),
        ).readAsString(),
        'local-change\n',
      );
      expect(
        await io.File(workspace.homePath('.config/app/obsolete.txt')).exists(),
        isTrue,
      );
    });

    test('skips prompting when --yes is provided', () async {
      final workspace = await _setUpPullChangesWorkspace();

      final run = await _runCommand(pullCommand, {'yes': true}, []);

      expect(run.error, isNull);
      expect(run.stdout, isNot(contains('Apply these changes?')));
      expect(run.stdout, contains('Pull complete'));
      expect(run.stdout, contains('updated: 1 paths'));
      expect(run.stdout, contains('removed: 1 paths'));
      expect(
        await io.File(
          workspace.homePath('.config/app/config.toml'),
        ).readAsString(),
        'from-repo\n',
      );
    });

    test(
      'fails in non-interactive mode without --yes when changes exist',
      () async {
        final workspace = await _setUpPullChangesWorkspace();

        final run = await _runCommand(pullCommand, {}, [], stdinIsTTY: false);

        final error = _dotweaveError(run.error);
        expect(
          error.message,
          'Pull confirmation requires an interactive terminal.',
        );
        // `applyPullPlan` did not run.
        expect(
          await io.File(
            workspace.homePath('.config/app/config.toml'),
          ).readAsString(),
          'local-change\n',
        );
      },
    );

    test(
      'untracks tracked targets relative to the current working directory',
      () async {
        final workspace = await _setUpWorkspace();

        await _writeHomeFile(workspace, '.ssh/config', 'Host example\n');
        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('normal'),
            target: workspace.homePath('.ssh/config'),
          ),
          workspace.home,
        );

        // The repo-relative spelling resolves independently of the real test
        // process cwd (which is what the command passes through).
        final run = await _runCommand(untrackCommand, {}, ['.ssh/config']);

        expect(run.error, isNull);
        expect(run.stdout, contains('Stopped tracking .ssh/config'));
        expect(await _manifestEntries(workspace), isEmpty);
      },
    );

    test('marks doctor failures by throwing with exit code', () async {
      final workspace = await _setUpWorkspace();

      await _writeHomeFile(workspace, '.gitconfig', 'x\n');
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: workspace.homePath('.gitconfig'),
        ),
        workspace.home,
      );
      // Real age failure: delete the identity file.
      await io.File(workspace.identityFile).delete();

      final run = await _runCommand(doctorCommand, {}, []);

      final error = _dotweaveError(run.error);
      expect(error.message, 'Doctor found issues.');
      expect(run.stdout, contains('Doctor found issues'));
    });

    test('formats successful doctor checks with an all-pass summary', () async {
      // DELTA: the real doctor always runs its six checks (git, config,
      // profiles, age, entries, local-paths), so the all-pass summary
      // counts 6 ok instead of the TS mock's 2.
      final workspace = await _setUpWorkspace();

      await _writeHomeFile(workspace, '.gitconfig', 'x\n');
      await trackTarget(
        TrackRequest(
          mode: const TrackModeValue('normal'),
          target: workspace.homePath('.gitconfig'),
        ),
        workspace.home,
      );

      final run = await _runCommand(doctorCommand, {}, []);

      expect(run.error, isNull);
      expect(
        run.stdout,
        contains('Doctor passed (6 ok · 0 warnings · 0 failures)'),
      );
      expect(run.stderr, isEmpty);
      expect(run.stdout, isNot(contains('✖')));
      expect(run.stdout, isNot(contains('⚠')));
    });

    test('formats doctor warnings with remapped check ids and distinct warn '
        'labels', () async {
      // DELTA: the real doctor can only warn through the `entries` check
      // (`local-paths` is ok or fail, never warn — and its fail path is
      // pre-empted by snapshot errors that abort the whole run), so this
      // exercises the single reachable warning; the mocked
      // `local-paths` → `local` remap line has no real-service
      // counterpart.
      await _setUpWorkspace();

      final run = await _runCommand(doctorCommand, {}, []);

      expect(run.error, isNull);
      expect(
        run.stderr,
        contains(
          'Doctor completed with warnings (5 ok · 1 warnings · 0 failures)',
        ),
      );

      final issueLines = run.stdoutLines
          .where((line) => line.startsWith('  '))
          .toList();
      expect(issueLines, ['  ⚠ entries — No sync entries are configured yet']);
      expect(run.stdout, isNot(contains('✖ entries')));
    });

    test(
      'formats doctor failures with remapped age id and throws an exit-coded '
      'error',
      () async {
        final workspace = await _setUpWorkspace();

        await _writeHomeFile(workspace, '.gitconfig', 'x\n');
        await trackTarget(
          TrackRequest(
            mode: const TrackModeValue('normal'),
            target: workspace.homePath('.gitconfig'),
          ),
          workspace.home,
        );
        await io.File(workspace.identityFile).delete();

        final run = await _runCommand(doctorCommand, {}, []);

        final error = _dotweaveError(run.error);
        expect(error.message, 'Doctor found issues.');
        expect(error, isA<CommandExitCode>());
        expect((error as CommandExitCode).exitCode, 1);

        // DELTA: real summary counts (5 ok · 0 warnings · 1 failures) versus
        // the TS mock's single-check result.
        expect(
          run.stdout,
          contains('Doctor found issues (5 ok · 0 warnings · 1 failures)'),
        );

        final issueLines = run.stdoutLines
            .where((line) => line.startsWith('  '))
            .toList();
        expect(issueLines, [
          '  ✖ identity — Age identity file is missing: '
              '${workspace.identityFile}',
        ]);
      },
    );

    test('truncates doctor issue details after three non-ok checks', () async {
      // DELTA: the real doctor can surface at most two non-ok checks in one
      // run (git/config failures return early, `profiles` is always ok, an
      // entries warning implies no tracked entries, and the local-paths
      // check only fails on snapshot errors that abort the whole doctor run
      // first), so the truncation branch (>3 issues) is unreachable through
      // the real service. This port drives the densest reachable issue list —
      // an age failure plus an entries warning — and asserts the full list
      // renders without a truncation line.
      final workspace = await _setUpWorkspace();

      await io.File(workspace.identityFile).delete();

      final run = await _runCommand(doctorCommand, {}, []);

      final error = _dotweaveError(run.error);
      expect(error.message, 'Doctor found issues.');

      final issueLines = run.stdoutLines
          .where((line) => line.startsWith('  '))
          .toList();
      expect(issueLines, [
        '  ✖ identity — Age identity file is missing: '
            '${workspace.identityFile}',
        '  ⚠ entries — No sync entries are configured yet',
      ]);
      expect(run.stdout, isNot(contains('more issues')));
    });

    test('creates the sync directory before launching cd shells', () async {
      // The real `launchShellInDirectory` spawns an interactive shell with
      // inherited stdio, which must not happen inside the test runner. The
      // platform key is forced to the opposite platform so shell resolution
      // points at an executable that cannot exist here; the command still
      // resolves the sync directory, creates it, and reaches the real shell
      // launcher (which fails to spawn). DELTA: the TS test asserts the
      // mocked `launchShellInDirectory("/tmp/dotweave")` call; here the
      // launcher invocation is proven by its thrown shell error.
      final workspace = await _setUpWorkspace(
        writeIdentity: false,
        initialize: false,
      );

      mockCurrentPlatformKey(io.Platform.isWindows ? 'linux' : 'win');

      expect(await io.Directory(workspace.syncDirectory).exists(), isFalse);

      final run = await _runCommand(cdCommand, {}, []);

      // mkdir ran with `recursive: true` before the launch attempt.
      expect(await io.Directory(workspace.syncDirectory).exists(), isTrue);

      final error = _dotweaveError(run.error);
      expect(
        error.message,
        anyOf(contains('Failed to launch shell'), contains('Shell exited')),
      );
    });
  });
}

/// Shared pull-scenario workspace: one tracked directory whose pushed state
/// diverges locally by exactly one updated file (`config.toml`, modified
/// locally) and one deletable file (`obsolete.txt`, created locally after the
/// push) — mirroring the TS mocked plan of 1 updated + 1 deleted path.
Future<_Workspace> _setUpPullChangesWorkspace() async {
  final workspace = await _setUpWorkspace();

  await _writeHomeFile(workspace, '.config/app/config.toml', 'from-repo\n');
  await trackTarget(
    TrackRequest(
      mode: const TrackModeValue('normal'),
      target: workspace.homePath('.config/app'),
    ),
    workspace.home,
  );
  await pushChanges(const PushRequest(dryRun: false));

  await _writeHomeFile(workspace, '.config/app/config.toml', 'local-change\n');
  await _writeHomeFile(workspace, '.config/app/obsolete.txt', 'obsolete\n');

  return workspace;
}
