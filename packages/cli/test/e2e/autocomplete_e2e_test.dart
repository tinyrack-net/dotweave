// Dart port of `packages/cli/tests/autocomplete.e2e.test.ts`.
//
// The TS shell shims exec `node --import <hook> src/index.ts`; the Dart port
// shims the AOT-compiled e2e executable instead (resolved through
// `resolveE2eBinary`), so the shim script quotes a single binary path. The
// shell runners spawn real shells with the parent environment plus the TS
// override set (execa's default `extendEnv`); `NODE_NO_WARNINGS` is omitted
// everywhere (Node-only). Test names and assertions are otherwise verbatim.

@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/cli/root_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/pty.dart'
    show
        bashPath,
        fishPath,
        isBashAvailable,
        isFishAvailable,
        isPowerShellAvailable,
        isZshAvailable,
        powerShellPath,
        zshPath;
import '../helpers/sync_fixture.dart' show stripAnsi;

const String _completeCommand =
    r'env -u COMP_LINE dotweave __complete "${inputs[@]}"';

final List<String> _rootCommandNames = [
  'autocomplete',
  ...rootCommandRoutes.keys,
];

final String? _selectedAutocompleteShell =
    Platform.environment['DOTWEAVE_AUTOCOMPLETE_SHELL'];

const List<String> _supportedAutocompleteShells = [
  'bash',
  'zsh',
  'fish',
  'powershell',
];

/// Mirror of the TS `runForShell` (which returns `it` or `it.skip`): computes
/// the `skip:` argument of a shell-specific test.
bool _skipForShell(String shell, bool available) {
  if (_selectedAutocompleteShell != null &&
      _selectedAutocompleteShell != shell) {
    return true;
  }

  if (_selectedAutocompleteShell == shell) {
    return false;
  }

  if (shell == 'powershell' && !Platform.isWindows) {
    return true;
  }

  return !available;
}

void _requireSelectedShellAvailability(String shell, bool available) {
  if (_selectedAutocompleteShell == shell) {
    expect(
      available,
      isTrue,
      reason: '$shell must be available for selected autocomplete CI shell',
    );
  }
}

Future<CliRunResult> _runCli(
  List<String> args, {
  String? cwd,
  Map<String, String>? env,
}) async {
  final result = await runCompiledCli(
    args,
    cwd: cwd,
    env: {'FORCE_COLOR': '0', 'NO_COLOR': '1', ...?env},
  );

  // Mirror of execa's default `reject: true`.
  if (result.exitCode != 0) {
    throw CliRunException(args, result);
  }

  return result;
}

List<String> _completionNames(String stdout) {
  return stdout.split('\n').map((line) => line.split('\t').first).toList();
}

List<String> _powerShellLines(String stdout) {
  return stdout.replaceAll('\r', '').split('\n');
}

final List<String> _bashRootCommandNames = [
  'autocomplete',
  ...rootCommandRoutes.keys,
].map((commandName) => '$commandName ').toList();

String _shellQuote(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

String _cleanShellStderr(String stderr) {
  return stripAnsi(stderr)
      .split(RegExp(r'\r?\n'))
      .where((line) {
        final trimmed = line.trim();

        return trimmed.isNotEmpty &&
            trimmed !=
                'MSYS2 is starting for the first time. '
                    'Executing the initial setup.' &&
            trimmed != 'Initial setup complete. MSYS2 is now ready to use.';
      })
      .join('\n');
}

({String drive, String pathRest})? _splitWindowsDrivePath(String value) {
  final normalized = value.replaceAll('\\', '/');
  final drivePathMatch = RegExp(r'^([A-Za-z]):/(.*)$').firstMatch(normalized);

  if (drivePathMatch == null) {
    return null;
  }

  final drive = drivePathMatch.group(1);
  final pathRest = drivePathMatch.group(2);

  if (drive == null || pathRest == null) {
    return null;
  }

  return (drive: drive.toLowerCase(), pathRest: pathRest);
}

String _toMsysShellPath(String value) {
  final drivePath = _splitWindowsDrivePath(value);

  return drivePath == null
      ? value.replaceAll('\\', '/')
      : '/${drivePath.drive}/${drivePath.pathRest}';
}

String _toWslShellPath(String value) {
  final drivePath = _splitWindowsDrivePath(value);

  return drivePath == null
      ? value.replaceAll('\\', '/')
      : '/mnt/${drivePath.drive}/${drivePath.pathRest}';
}

List<String> _shellPathEntries(String value) {
  if (!Platform.isWindows) {
    return [value];
  }

  return [_toWslShellPath(value), _toMsysShellPath(value)];
}

/// Mirror of the TS `createShellShimScript`; the shim execs the compiled e2e
/// binary instead of `node --import <hook> <cliPath>`.
Future<String> _createShellShimScript() async {
  final binary = await resolveE2eBinary();

  if (!Platform.isWindows) {
    return [
      '#!/usr/bin/env bash',
      'exec ${_shellQuote(binary)} "\$@"',
    ].join('\n');
  }

  return [
    '#!/usr/bin/env bash',
    r'case "$(uname -r 2>/dev/null || true)" in',
    '  *icrosoft*|*WSL*)',
    '    dotweave_bin=${_shellQuote(_toWslShellPath(binary))}',
    '    ;;',
    '  *)',
    '    dotweave_bin=${_shellQuote(_toMsysShellPath(binary))}',
    '    ;;',
    'esac',
    r'exec "$dotweave_bin" "$@"',
  ].join('\n');
}

String _exportPathCommand(String binDirectory) {
  return 'export PATH='
      '${_shellPathEntries(binDirectory).map(_shellQuote).join(':')}:\$PATH';
}

String _fishString(String value) {
  return "'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'";
}

String get _pathDelimiter => Platform.isWindows ? ';' : ':';

Future<void> _makeExecutable(String path) async {
  if (Platform.isWindows) {
    return;
  }

  await Process.run('chmod', ['755', path]);
}

/// Mirror of `realpath(mkdtemp(...))`.
Future<String> _createRealpathTempDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);

  return directory.resolveSymbolicLinks();
}

/// Spawns a real shell with the parent environment plus [env] (execa's
/// default env extension) and throws on a non-zero exit code (execa's default
/// `reject: true`).
Future<CliRunResult> _execShell(
  String executable,
  List<String> args, {
  String? cwd,
  Map<String, String>? env,
}) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: cwd,
    environment: env,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final run = (
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );

  if (run.exitCode != 0) {
    throw StateError(
      '$executable ${args.join(' ')} failed with exit code ${run.exitCode}\n'
      'stdout:\n${run.stdout}\n'
      'stderr:\n${run.stderr}',
    );
  }

  return run;
}

Future<CliRunResult> _runBashCompletion(
  List<String> words,
  int currentWordIndex, {
  String? cwd,
}) async {
  final configDirectory = await _createRealpathTempDirectory(
    'dotweave-autocomplete-bash-',
  );
  final binDirectory = p.join(configDirectory, 'bin');
  final homeDir = p.join(configDirectory, 'home');
  final shimPath = p.join(binDirectory, 'dotweave');

  await Directory(binDirectory).create(recursive: true);
  await File(shimPath).writeAsString(await _createShellShimScript());
  await _makeExecutable(shimPath);

  try {
    return await _execShell(
      // Always execute the probed absolute path: on Windows, CreateProcess
      // searches System32 before PATH, so a bare `bash` resolves to the WSL
      // launcher stub even when Git Bash is the shell the probe accepted.
      bashPath ?? 'bash',
      [
        '-lc',
        [
          'set -euo pipefail',
          _exportPathCommand(binDirectory),
          r'eval "$(dotweave autocomplete bash)"',
          'COMP_WORDS=(${words.map(_shellQuote).join(' ')})',
          'COMP_CWORD=$currentWordIndex',
          '__dotweave_complete',
          r'printf "%s\n" "${COMPREPLY[@]}"',
        ].join('; '),
      ],
      cwd: cwd,
      env: {'FORCE_COLOR': '0', 'HOME': homeDir, 'NO_COLOR': '1'},
    );
  } finally {
    await removeE2eWorkspace(configDirectory);
  }
}

Future<CliRunResult> _runZshCompletion(
  List<String> words,
  int currentWord, {
  String? cwd,
}) async {
  final configDirectory = await _createRealpathTempDirectory(
    'dotweave-autocomplete-zsh-',
  );
  final binDirectory = p.join(configDirectory, 'bin');
  final shimPath = p.join(binDirectory, 'dotweave');

  await Directory(binDirectory).create(recursive: true);
  await File(shimPath).writeAsString(await _createShellShimScript());
  await _makeExecutable(shimPath);

  final compaddMock = [
    'function compadd() {',
    '  local suffix=""',
    r'  while (( $# > 0 )); do',
    r'    case "$1" in',
    '      --)',
    '        shift',
    '        break',
    '        ;;',
    '      -Q)',
    '        shift',
    '        ;;',
    '      -S)',
    r'        suffix="$2"',
    '        shift 2',
    '        ;;',
    '      *)',
    '        shift',
    '        ;;',
    '    esac',
    '  done',
    '  local completion=""',
    r'  for completion in "$@"; do',
    r'    printf "%s%s\n" "$completion" "$suffix"',
    '  done',
    '}',
  ].join('; ');

  try {
    return await _execShell(
      zshPath ?? 'zsh',
      [
        '-lc',
        [
          'set -euo pipefail',
          _exportPathCommand(binDirectory),
          'function compdef() { :; }',
          compaddMock,
          r'eval "$(dotweave autocomplete zsh)"',
          'words=(${words.map(_shellQuote).join(' ')})',
          'CURRENT=$currentWord',
          '__dotweave_complete',
        ].join('; '),
      ],
      cwd: cwd,
      env: {'FORCE_COLOR': '0', 'NO_COLOR': '1'},
    );
  } finally {
    await removeE2eWorkspace(configDirectory);
  }
}

Future<CliRunResult> _runFishCompletion(
  String commandLine, {
  String? cwd,
}) async {
  final configDirectory = await _createRealpathTempDirectory(
    'dotweave-autocomplete-fish-',
  );
  final binDirectory = p.join(configDirectory, 'bin');
  final homeDirectory = p.join(configDirectory, 'home');
  final shimPath = p.join(binDirectory, 'dotweave');

  await Directory(binDirectory).create(recursive: true);
  await Directory(homeDirectory).create(recursive: true);
  await File(shimPath).writeAsString(await _createShellShimScript());
  await _makeExecutable(shimPath);

  try {
    return await _execShell(
      fishPath ?? 'fish',
      [
        '-c',
        [
          'set -gx PATH '
              '${_shellPathEntries(binDirectory).map(_fishString).join(' ')}'
              ' \$PATH',
          'dotweave autocomplete fish | source',
          'complete -C ${_fishString(commandLine)}',
        ].join('; '),
      ],
      cwd: cwd,
      env: {
        'FORCE_COLOR': '0',
        'NO_COLOR': '1',
        // Isolate fish's data/history dirs per invocation: concurrent fish
        // processes sharing the runner's real HOME race on creating
        // ~/.local/share/fish ("File exists") and print history warnings to
        // stderr, breaking the empty-stderr assertions.
        'HOME': homeDirectory,
        'XDG_CONFIG_HOME': p.join(homeDirectory, '.config'),
        'XDG_DATA_HOME': p.join(homeDirectory, '.local', 'share'),
      },
    );
  } finally {
    await removeE2eWorkspace(configDirectory);
  }
}

Future<({String binDirectory, String configDirectory})>
_createPowerShellShim() async {
  final configDirectory = await _createRealpathTempDirectory(
    'dotweave-autocomplete-pwsh-',
  );
  final binDirectory = p.join(configDirectory, 'bin');

  await Directory(binDirectory).create(recursive: true);

  final binary = await resolveE2eBinary();

  if (Platform.isWindows) {
    await File(
      p.join(binDirectory, 'dotweave.cmd'),
    ).writeAsString(['@echo off', '"$binary" %*'].join('\r\n'));
  } else {
    final shimPath = p.join(binDirectory, 'dotweave');

    await File(shimPath).writeAsString(await _createShellShimScript());
    await _makeExecutable(shimPath);
  }

  return (binDirectory: binDirectory, configDirectory: configDirectory);
}

String _psString(String value) {
  return "'${value.replaceAll("'", "''")}'";
}

Future<CliRunResult> _runPowerShellCompletion(
  String commandLine, {
  String? cwd,
}) async {
  final shim = await _createPowerShellShim();
  final script = [
    r"$ErrorActionPreference = 'Stop'",
    '\$env:PATH = ${_psString(shim.binDirectory)} + '
        '${_psString(_pathDelimiter)} + \$env:PATH',
    r'. ([scriptblock]::Create(((dotweave autocomplete powershell) -join '
        '[Environment]::NewLine)))',
    '\$line = ${_psString(commandLine)}',
    r'$matches = TabExpansion2 -inputScript $line -cursorColumn $line.Length',
    r'$matches.CompletionMatches | ForEach-Object { $_.CompletionText }',
  ].join('; ');

  try {
    return await _execShell(
      powerShellPath ?? 'pwsh',
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
      cwd: cwd,
      env: {'FORCE_COLOR': '0', 'NO_COLOR': '1'},
    );
  } finally {
    await removeE2eWorkspace(shim.configDirectory);
  }
}

void main() {
  group('autocomplete e2e', () {
    late String completionFixtureDirectory;

    test('uses a supported autocomplete shell selector when provided', () {
      if (_selectedAutocompleteShell != null) {
        expect(
          _supportedAutocompleteShells,
          contains(_selectedAutocompleteShell),
        );
      }
    });

    test('requires fish when fish autocomplete is selected', () {
      _requireSelectedShellAvailability('fish', isFishAvailable);
    });

    setUpAll(() async {
      completionFixtureDirectory = (await Directory.systemTemp.createTemp(
        'dotweave-autocomplete-',
      )).path;
      await File(
        p.join(completionFixtureDirectory, 'file-alpha.txt'),
      ).writeAsString('');
      await Directory(
        p.join(completionFixtureDirectory, 'folder-beta'),
      ).create();
    });

    tearDownAll(() async {
      await removeE2eWorkspace(completionFixtureDirectory);
    });

    test('appears in root help', () async {
      final result = await _runCli([]);

      expect(result.exitCode, 0);
      expect(_cleanShellStderr(result.stderr), '');
      expect(result.stdout, contains('autocomplete'));
      expect(result.stdout, contains('Print shell autocomplete scripts'));
    });

    test('prints a bash autocomplete script for eval', () async {
      final result = await _runCli(['autocomplete', 'bash']);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('__dotweave_complete() {'));
      expect(result.stdout, contains(_completeCommand));
      expect(
        result.stdout,
        contains(
          'complete -o default -o nospace -F __dotweave_complete '
          'dotweave',
        ),
      );
      expect(result.stdout, isNot(contains('Setup Instructions')));
      expect(_cleanShellStderr(result.stderr), '');
    });

    test('prints a zsh autocomplete script for eval', () async {
      final result = await _runCli(['autocomplete', 'zsh']);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('autoload -Uz compinit'));
      expect(result.stdout, contains(_completeCommand));
      expect(result.stdout, contains('compdef __dotweave_complete dotweave'));
      expect(_cleanShellStderr(result.stderr), '');
    });

    test('prints a fish autocomplete script for source', () async {
      final result = await _runCli(['autocomplete', 'fish']);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('function __dotweave_complete'));
      expect(result.stdout, contains('command dotweave __complete'));
      expect(result.stdout, contains('complete -c dotweave -f'));
      expect(_cleanShellStderr(result.stderr), '');
    });

    test(
      'normalizes __complete input when the command name is included',
      () async {
        final result = await _runCli(['__complete', 'dotweave', 'aut']);

        expect(result.exitCode, 0);
        expect(result.stdout.trim().split('\t').first, 'autocomplete');
        expect(_cleanShellStderr(result.stderr), '');
      },
    );

    test(
      'completes track targets and flags after an existing target',
      () async {
        final result = await _runCli([
          '__complete',
          'track',
          'file-alpha.txt',
          '',
        ], cwd: completionFixtureDirectory);

        expect(result.exitCode, 0);
        expect(
          _completionNames(result.stdout),
          containsAll([
            '--mode',
            '--profile',
            'file-alpha.txt',
            'folder-beta/',
          ]),
        );
        expect(_cleanShellStderr(result.stderr), '');
      },
    );

    test(
      'populates bash completions from the emitted script',
      () async {
        final result = await _runBashCompletion(['dotweave', 'aut'], 1);

        expect(result.exitCode, 0);
        expect(result.stdout.split('\n'), contains('autocomplete '));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('bash', isBashAvailable),
    );

    test('offers root subcommands when bash completes the command token '
        'itself', () async {
      final result = await _runBashCompletion(['dotweave'], 0);

      expect(result.exitCode, 0);
      expect(result.stdout.split('\n'), containsAll(_bashRootCommandNames));
    }, skip: _skipForShell('bash', isBashAvailable));

    test(
      'adds a trailing space for unique bash subcommand completions',
      () async {
        final result = await _runBashCompletion(['dotweave', 'pro'], 1);

        expect(result.exitCode, 0);
        expect(result.stdout.split('\n'), contains('profile '));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('bash', isBashAvailable),
    );

    test(
      'populates bash path completions for track targets',
      () async {
        final result = await _runBashCompletion(
          ['dotweave', 'track', 'fi'],
          2,
          cwd: completionFixtureDirectory,
        );

        expect(result.exitCode, 0);
        expect(result.stdout.split('\n'), contains('file-alpha.txt '));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('bash', isBashAvailable),
    );

    test(
      'populates bash flag completions after a track target',
      () async {
        final result = await _runBashCompletion(
          ['dotweave', 'track', 'file-alpha.txt', '-'],
          3,
          cwd: completionFixtureDirectory,
        );

        expect(result.exitCode, 0);
        expect(
          result.stdout.split('\n'),
          containsAll(['--mode ', '--profile ', '--repo ']),
        );
      },
      skip: _skipForShell('bash', isBashAvailable),
    );

    test(
      'adds a trailing space for unique zsh subcommand completions',
      () async {
        final result = await _runZshCompletion(['dotweave', 'pro'], 2);

        expect(result.exitCode, 0);
        expect(result.stdout.split('\n'), contains('profile'));
      },
      skip: _skipForShell('zsh', isZshAvailable),
    );

    test(
      'offers root subcommands when zsh completes the command token itself',
      () async {
        final result = await _runZshCompletion(['dotweave'], 1);

        expect(result.exitCode, 0);
        expect(result.stdout.split('\n'), containsAll(_rootCommandNames));
      },
      skip: _skipForShell('zsh', isZshAvailable),
    );

    test(
      'populates fish root completions from a prefix',
      () async {
        _requireSelectedShellAvailability('fish', isFishAvailable);

        final result = await _runFishCompletion('dotweave pr');

        expect(result.exitCode, 0);
        expect(_completionNames(result.stdout), contains('profile'));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('fish', isFishAvailable),
    );

    test(
      'populates fish path completions for track targets',
      () async {
        _requireSelectedShellAvailability('fish', isFishAvailable);

        final result = await _runFishCompletion(
          'dotweave track fi',
          cwd: completionFixtureDirectory,
        );

        expect(result.exitCode, 0);
        expect(_completionNames(result.stdout), contains('file-alpha.txt'));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('fish', isFishAvailable),
    );

    test(
      'populates fish flag completions after a track target',
      () async {
        _requireSelectedShellAvailability('fish', isFishAvailable);

        final result = await _runFishCompletion(
          'dotweave track file-alpha.txt -',
          cwd: completionFixtureDirectory,
        );

        expect(result.exitCode, 0);
        expect(
          _completionNames(result.stdout),
          containsAll(['--mode', '--profile', '--repo']),
        );
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('fish', isFishAvailable),
    );

    test(
      'proposes root subcommands when COMP_LINE has a trailing space',
      () async {
        final result = await _runCli(
          ['__complete', 'dotweave', ''],
          env: {'COMP_LINE': 'dotweave '},
        );

        expect(result.exitCode, 0);
        expect(_completionNames(result.stdout), containsAll(_rootCommandNames));
        expect(_cleanShellStderr(result.stderr), '');
      },
    );

    test(
      'proposes subcommand completions when COMP_LINE targets a command',
      () async {
        final result = await _runCli(
          ['__complete', 'dotweave', 'track', ''],
          env: {'COMP_LINE': 'dotweave track '},
          cwd: completionFixtureDirectory,
        );

        expect(result.exitCode, 0);
        expect(
          _completionNames(result.stdout),
          containsAll(['--mode', '--profile', '--repo']),
        );
        expect(_cleanShellStderr(result.stderr), '');
      },
    );

    test(
      'populates PowerShell root completions from a prefix',
      () async {
        _requireSelectedShellAvailability('powershell', isPowerShellAvailable);

        final result = await _runPowerShellCompletion('dotweave p');

        expect(result.exitCode, 0);
        expect(_powerShellLines(result.stdout), contains('profile'));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('powershell', isPowerShellAvailable),
    );

    test(
      'populates PowerShell subcommand completions from a prefix',
      () async {
        _requireSelectedShellAvailability('powershell', isPowerShellAvailable);

        final result = await _runPowerShellCompletion('dotweave tr');

        expect(result.exitCode, 0);
        expect(_powerShellLines(result.stdout), contains('track'));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('powershell', isPowerShellAvailable),
    );

    test(
      'populates PowerShell path completions for track targets',
      () async {
        _requireSelectedShellAvailability('powershell', isPowerShellAvailable);

        final result = await _runPowerShellCompletion(
          'dotweave track fi',
          cwd: completionFixtureDirectory,
        );

        expect(result.exitCode, 0);
        expect(_powerShellLines(result.stdout), contains('file-alpha.txt'));
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('powershell', isPowerShellAvailable),
    );

    test(
      'populates PowerShell flag completions after a track target',
      () async {
        _requireSelectedShellAvailability('powershell', isPowerShellAvailable);

        final result = await _runPowerShellCompletion(
          'dotweave track file-alpha.txt -',
          cwd: completionFixtureDirectory,
        );

        expect(result.exitCode, 0);
        expect(
          _powerShellLines(result.stdout),
          containsAll(['--mode', '--profile', '--repo']),
        );
        expect(_cleanShellStderr(result.stderr), '');
      },
      skip: _skipForShell('powershell', isPowerShellAvailable),
    );

    test(
      'shows bash, zsh, fish, and PowerShell autocomplete subcommands',
      () async {
        final result = await _runCli(['autocomplete', '--help']);

        expect(result.exitCode, 0);
        expect(result.stdout, contains('bash'));
        expect(result.stdout, contains('zsh'));
        expect(result.stdout, contains('fish'));
        expect(result.stdout, contains('powershell'));
        expect(result.stdout, isNot(contains('install')));
        expect(result.stdout, isNot(contains('uninstall')));
        expect(_cleanShellStderr(result.stderr), '');
      },
    );
  });
}
