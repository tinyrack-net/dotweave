// Dart port of `packages/cli/tests/autocomplete.pty.e2e.test.ts`.
//
// node-pty is replaced by the POSIX `script`-utility wrapper in
// `test/helpers/pty.dart`, which does not exist on Windows: every test body
// therefore starts with `if (Platform.isWindows) return;` (the TS suites'
// `process.platform !== "win32"` pty support check). The TS powershell pty
// group ran only on Windows (winpty); with the POSIX-only wrapper it is
// compiled but never exercised. The shell shim execs the AOT-compiled e2e
// binary instead of `node <cliNodeOptions>`; `NODE_NO_WARNINGS` is omitted
// (Node-only). The TS per-test 15s/20s vitest timeouts are covered by the
// file-level timeout plus the 10s/15s waitFor deadlines.

@Tags(['pty'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dotweave/src/cli/root_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/pty.dart';

final List<String> _rootCommandNames = [
  'autocomplete',
  ...rootCommandRoutes.keys,
];

final String? _selectedAutocompleteShell =
    Platform.environment['DOTWEAVE_AUTOCOMPLETE_SHELL'];

const List<String> _ptyRootSmokeCommandNames = [
  'autocomplete',
  'profile',
  'status',
];

bool _shouldRunPtyShell(String shell, bool available) {
  if (_selectedAutocompleteShell != null &&
      _selectedAutocompleteShell != shell) {
    return false;
  }

  if (shell == 'powershell') {
    return Platform.isWindows &&
        (_selectedAutocompleteShell == shell || available);
  }

  if (Platform.isWindows) {
    return false;
  }

  return _selectedAutocompleteShell == shell || available;
}

void _requireSelectedPtyShellAvailability(String shell, bool available) {
  if (_selectedAutocompleteShell == shell) {
    expect(
      available,
      isTrue,
      reason: '$shell must be available for selected autocomplete CI shell',
    );
  }
}

String _shellQuote(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

String get _pathDelimiter => Platform.isWindows ? ';' : ':';

Future<void> _makeExecutable(String path) async {
  if (Platform.isWindows) {
    return;
  }

  await Process.run('chmod', ['755', path]);
}

Future<String> _waitForPtyRootSmokeCommands(PtySession session) {
  return session.waitForOutput((output) {
    return _ptyRootSmokeCommandNames.every(output.contains);
  }, const Duration(seconds: 10));
}

Future<({String binDirectory, String configDirectory})>
_createTestShellDirectory(List<String> rcLines, String rcFileName) async {
  final configDirectory = (await Directory.systemTemp.createTemp(
    'dotweave-autocomplete-pty-',
  )).path;
  final binDirectory = p.join(configDirectory, 'bin');

  await Directory(binDirectory).create(recursive: true);

  final cliCommand = _shellQuote(await resolveE2eBinary());
  final shimPath = p.join(binDirectory, 'dotweave');

  await File(
    shimPath,
  ).writeAsString(['#!/usr/bin/env bash', 'exec $cliCommand "\$@"'].join('\n'));
  await _makeExecutable(shimPath);

  await File(
    p.join(configDirectory, rcFileName),
  ).writeAsString(rcLines.join('\n'));

  return (binDirectory: binDirectory, configDirectory: configDirectory);
}

Future<({String binDirectory, String configDirectory})>
_createPowerShellPtyDirectory() async {
  final configDirectory = (await Directory.systemTemp.createTemp(
    'dotweave-autocomplete-powershell-pty-',
  )).path;
  final binDirectory = p.join(configDirectory, 'bin');
  final binary = await resolveE2eBinary();

  await Directory(binDirectory).create(recursive: true);
  await File(
    p.join(binDirectory, 'dotweave.cmd'),
  ).writeAsString(['@echo off', '"$binary" %*'].join('\r\n'));

  return (binDirectory: binDirectory, configDirectory: configDirectory);
}

void main() {
  group('autocomplete fish pty e2e', () {
    late String fishBinDirectory;
    late String fishConfigRoot;
    late String fishFixtureDirectory;
    late String systemPath;

    setUpAll(() async {
      _requireSelectedPtyShellAvailability('fish', isFishAvailable);

      systemPath = Platform.environment['PATH'] ?? '';

      final directories = await _createTestShellDirectory(
        [],
        '.fish-placeholder',
      );
      final fishConfigDirectory = p.join(directories.configDirectory, 'fish');

      await Directory(fishConfigDirectory).create(recursive: true);
      await File(p.join(fishConfigDirectory, 'config.fish')).writeAsString(
        [
          "function fish_prompt; printf 'PROMPT> '; end",
          'dotweave autocomplete fish | source',
        ].join('\n'),
      );

      fishBinDirectory = directories.binDirectory;
      fishConfigRoot = directories.configDirectory;
      fishFixtureDirectory = (await Directory.systemTemp.createTemp(
        'dotweave-autocomplete-fish-pty-',
      )).path;
      await File(
        p.join(fishFixtureDirectory, 'file-alpha.txt'),
      ).writeAsString('');
    });

    tearDownAll(() async {
      await removeE2eWorkspace(fishConfigRoot);
      await removeE2eWorkspace(fishFixtureDirectory);
    });

    Future<PtySession> createFishSession() {
      return startPtySession(
        args: ['--features', 'no-query-term', '--interactive'],
        cwd: fishFixtureDirectory,
        env: {
          'FORCE_COLOR': '0',
          'NO_COLOR': '1',
          'PATH': [fishBinDirectory, systemPath].join(_pathDelimiter),
          'XDG_CONFIG_HOME': fishConfigRoot,
        },
        file: fishPath ?? 'fish',
      );
    }

    test('completes a root subcommand in interactive fish', () async {
      if (Platform.isWindows) {
        return;
      }

      final session = await createFishSession();

      try {
        await session.waitFor('PROMPT> ');

        session.write('dotweave p\t');

        final output = await session.waitFor(
          'profile',
          const Duration(seconds: 10),
        );

        expect(output, contains('profile'));
      } finally {
        session.close();
      }
    });
  }, skip: !_shouldRunPtyShell('fish', isFishAvailable));

  group('autocomplete zsh pty e2e', () {
    late String shellConfigDirectory;
    late String shellBinDirectory;
    late String systemPath;

    setUpAll(() async {
      _requireSelectedPtyShellAvailability('zsh', isZshAvailable);

      systemPath = Platform.environment['PATH'] ?? '';

      final directories = await _createTestShellDirectory([
        'autoload -Uz compinit',
        'zmodload zsh/complist',
        "zstyle ':completion:*' list-colors ''",
        "zstyle ':completion:*' menu no",
        "PROMPT='PROMPT> '",
        r'eval "$(dotweave autocomplete zsh)"',
      ], '.zshrc');

      shellBinDirectory = directories.binDirectory;
      shellConfigDirectory = directories.configDirectory;
    });

    tearDownAll(() async {
      await removeE2eWorkspace(shellConfigDirectory);
    });

    Future<PtySession> createZshSession() {
      return startPtySession(
        args: ['-f', '-i'],
        cwd: Directory.current.path,
        env: {
          'FORCE_COLOR': '0',
          'NO_COLOR': '1',
          'PATH': [shellBinDirectory, systemPath].join(_pathDelimiter),
          'ZDOTDIR': shellConfigDirectory,
        },
        file: zshPath ?? 'zsh',
      );
    }

    Future<void> sourceZshConfig(PtySession session) async {
      session.write(
        'source ${_shellQuote(p.join(shellConfigDirectory, '.zshrc'))}\r',
      );
      await session.waitFor('PROMPT> ', const Duration(seconds: 10));
      session.clearOutput();
    }

    test(
      'lists root subcommands in interactive zsh after dotweave tab tab',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final session = await createZshSession();

        try {
          await sourceZshConfig(session);

          session.write('dotweave \t\t');

          final output = await _waitForPtyRootSmokeCommands(session);

          for (final commandName in _ptyRootSmokeCommandNames) {
            expect(output, contains(commandName));
          }
        } finally {
          session.close();
        }
      },
    );

    test(
      'still lists root subcommands after running dotweave once in zsh',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final session = await createZshSession();

        try {
          await sourceZshConfig(session);

          session.write('dotweave\n');
          await session.waitFor('COMMANDS');
          await session.waitFor(RegExp(r'PROMPT> $', multiLine: true));

          session.clearOutput();

          session.write('dotweave \t\t');

          final output = await _waitForPtyRootSmokeCommands(session);

          for (final commandName in _ptyRootSmokeCommandNames) {
            expect(output, contains(commandName));
          }
        } finally {
          session.close();
        }
      },
    );
  }, skip: !_shouldRunPtyShell('zsh', isZshAvailable));

  group('autocomplete bash pty e2e', () {
    late String bashBinDirectory;
    late String bashConfigDirectory;
    late String systemPath;

    setUpAll(() async {
      _requireSelectedPtyShellAvailability('bash', isBashAvailable);

      systemPath = Platform.environment['PATH'] ?? '';

      final directories = await _createTestShellDirectory([
        r'eval "$(dotweave autocomplete bash)"',
        "PS1='PROMPT> '",
      ], '.bashrc');

      bashBinDirectory = directories.binDirectory;
      bashConfigDirectory = directories.configDirectory;
    });

    tearDownAll(() async {
      await removeE2eWorkspace(bashConfigDirectory);
    });

    Future<PtySession> createBashSession() {
      return startPtySession(
        args: ['--rcfile', p.join(bashConfigDirectory, '.bashrc'), '-i'],
        cwd: Directory.current.path,
        env: {
          'FORCE_COLOR': '0',
          'NO_COLOR': '1',
          'PATH': [bashBinDirectory, systemPath].join(_pathDelimiter),
        },
        file: bashPath ?? 'bash',
      );
    }

    test('lists root subcommands in interactive bash', () async {
      if (Platform.isWindows) {
        return;
      }

      final session = await createBashSession();

      try {
        await session.waitFor('PROMPT> ');

        session.write('dotweave \t\t');

        for (final commandName in _rootCommandNames) {
          await session.waitFor(commandName, const Duration(seconds: 10));
        }

        final output = session.getOutput();

        for (final commandName in _ptyRootSmokeCommandNames) {
          expect(output, contains(commandName));
        }
      } finally {
        session.close();
      }
    });

    test(
      'still lists root subcommands after running dotweave once in bash',
      () async {
        if (Platform.isWindows) {
          return;
        }

        final session = await createBashSession();

        try {
          await session.waitFor('PROMPT> ');

          session.write('dotweave\n');
          await session.waitFor('COMMANDS');
          await session.waitFor(RegExp(r'PROMPT> $', multiLine: true));

          session.clearOutput();

          session.write('dotweave \t\t');

          for (final commandName in _rootCommandNames) {
            await session.waitFor(commandName, const Duration(seconds: 10));
          }

          final output = session.getOutput();

          for (final commandName in _ptyRootSmokeCommandNames) {
            expect(output, contains(commandName));
          }
          expect(output, isNot(contains('AGENTS.md')));
          expect(output, isNot(contains('package.json')));
        } finally {
          session.close();
        }
      },
    );
  }, skip: !_shouldRunPtyShell('bash', isBashAvailable));

  group(
    'autocomplete powershell pty e2e',
    () {
      late String powerShellBinDirectory;
      late String powerShellConfigDirectory;
      late String powerShellFixtureDirectory;
      late String systemPath;

      setUpAll(() async {
        _requireSelectedPtyShellAvailability(
          'powershell',
          isPowerShellAvailable,
        );

        systemPath = Platform.environment['PATH'] ?? '';

        final directories = await _createPowerShellPtyDirectory();

        powerShellBinDirectory = directories.binDirectory;
        powerShellConfigDirectory = directories.configDirectory;
        powerShellFixtureDirectory = (await Directory.systemTemp.createTemp(
          'dotweave-autocomplete-powershell-pty-fixture-',
        )).path;
        await File(
          p.join(powerShellFixtureDirectory, 'file-alpha.txt'),
        ).writeAsString('');
      });

      tearDownAll(() async {
        await removeE2eWorkspace(powerShellConfigDirectory);
        await removeE2eWorkspace(powerShellFixtureDirectory);
      });

      Future<PtySession> createPowerShellSession() {
        return startPtySession(
          args: ['-NoLogo', '-NoProfile', '-NoExit'],
          cwd: powerShellFixtureDirectory,
          env: {
            'FORCE_COLOR': '0',
            'NO_COLOR': '1',
            'PATH': [powerShellBinDirectory, systemPath].join(_pathDelimiter),
          },
          file: powerShellPath ?? 'pwsh',
        );
      }

      Future<void> configurePowerShellSession(PtySession session) async {
        session.write(
          '${[r"$ErrorActionPreference = 'Stop'", 'Set-PSReadLineOption -PredictionSource None', 'Set-PSReadLineOption -EditMode Windows', "function global:prompt { 'PROMPT> ' }", r'. ([scriptblock]::Create(((dotweave autocomplete powershell) '
              '-join [Environment]::NewLine)))'].join('; ')}\r',
        );
        await session.waitFor('PROMPT> ', const Duration(seconds: 15));
        session.clearOutput();
      }

      test('lists root subcommands in interactive PowerShell', () async {
        if (Platform.isWindows) {
          return;
        }

        final session = await createPowerShellSession();

        try {
          await configurePowerShellSession(session);

          session.write('dotweave p\t');

          final output = await session.waitFor(
            'profile',
            const Duration(seconds: 10),
          );

          expect(output, contains('profile'));
        } finally {
          session.close();
          await session.waitForExit();
        }
      });
    },
    skip: !_shouldRunPtyShell('powershell', isPowerShellAvailable),
  );
}
