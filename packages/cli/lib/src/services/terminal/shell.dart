// Dart port of `packages/cli/src/services/terminal/shell.ts`.

import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/lib/env.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/string.dart';

/// Mirror of the TS `ShellCommand` readonly object.
class ShellCommand {
  const ShellCommand({required this.args, required this.command});

  final List<String> args;
  final String command;

  @override
  bool operator ==(Object other) {
    if (other is! ShellCommand ||
        other.command != command ||
        other.args.length != args.length) {
      return false;
    }
    for (var i = 0; i < args.length; i++) {
      if (other.args[i] != args[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(command, Object.hashAll(args));

  @override
  String toString() => 'ShellCommand(args: $args, command: $command)';
}

/// Mirror of the Node child `close` event payload: `(code, signal)`.
class ShellCloseEvent {
  const ShellCloseEvent({this.code, this.signal});

  final int? code;
  final String? signal;
}

/// Spawns the shell with inherited stdio and completes with its close event;
/// throws when spawning fails. Mirrors the Node `spawn` + error/close events.
typedef ShellSpawn =
    Future<ShellCloseEvent> Function(
      String command,
      List<String> args,
      String directory,
    );

/// DI seams replacing the vitest module mocks of `#app/lib/env.ts`,
/// `#app/config/runtime-env.ts`, and `node:child_process`.
class ShellDependencies {
  const ShellDependencies({
    this.env,
    this.resolveCurrentPlatformKey,
    this.spawn,
  });

  final Env? env;
  final PlatformKey Function()? resolveCurrentPlatformKey;
  final ShellSpawn? spawn;
}

Future<ShellCommand> resolveShellCommandForPlatform(
  PlatformKey platformKey, {
  Env? env,
}) async {
  final environment = env ?? ENV;

  if (platformKey == 'win') {
    return ShellCommand(
      args: const [],
      command: normalizeConfiguredValue(environment.COMSPEC) ?? 'cmd.exe',
    );
  }

  return ShellCommand(
    args: const [],
    command: normalizeConfiguredValue(environment.SHELL) ?? '/bin/sh',
  );
}

Future<ShellCommand> resolveShellCommand({
  ShellDependencies? dependencies,
}) async {
  final resolvePlatformKey =
      dependencies?.resolveCurrentPlatformKey ?? resolveCurrentPlatformKey;

  return resolveShellCommandForPlatform(
    resolvePlatformKey(),
    env: dependencies?.env,
  );
}

String _createShellFailureHint(PlatformKey Function() resolvePlatformKey) {
  return resolvePlatformKey() == 'win'
      ? 'Set COMSPEC to a valid shell executable.'
      : 'Set SHELL to a valid shell executable.';
}

/// Shell-exit failure carrying the exit code the CLI should propagate,
/// mirroring the `DotweaveError & { exitCode?: number }` cast in TS.
class ShellExitError extends DotweaveError {
  ShellExitError(
    super.message, {
    super.details,
    super.hint,
    required this.exitCode,
  });

  final int exitCode;
}

ShellExitError _createShellExitError(
  String command,
  int? code,
  String? signal,
) {
  return ShellExitError(
    signal == null
        ? 'Shell exited with code ${code ?? 'unknown'}.'
        : 'Shell exited due to signal $signal.',
    details: ['Shell: $command'],
    hint: "Exit the spawned shell normally when you're done.",
    exitCode: code ?? 1,
  );
}

/// POSIX signal names for the negative exit codes `dart:io` reports when a
/// child dies from a signal (Node surfaces the name via the close event).
const Map<int, String> _posixSignalNames = {
  1: 'SIGHUP',
  2: 'SIGINT',
  3: 'SIGQUIT',
  4: 'SIGILL',
  5: 'SIGTRAP',
  6: 'SIGABRT',
  7: 'SIGBUS',
  8: 'SIGFPE',
  9: 'SIGKILL',
  10: 'SIGUSR1',
  11: 'SIGSEGV',
  12: 'SIGUSR2',
  13: 'SIGPIPE',
  14: 'SIGALRM',
  15: 'SIGTERM',
};

Future<ShellCloseEvent> _spawnShellProcess(
  String command,
  List<String> args,
  String directory,
) async {
  // Mirrors `spawn(command, args, { cwd, env: process.env, stdio:
  // "inherit" })`: the environment is inherited by default and stdio is
  // attached to the parent terminal.
  final process = await Process.start(
    command,
    args,
    workingDirectory: directory,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;

  if (code < 0) {
    return ShellCloseEvent(signal: _posixSignalNames[-code] ?? 'SIG${-code}');
  }

  return ShellCloseEvent(code: code);
}

Future<void> launchShellInDirectory(
  String directory, {
  ShellDependencies? dependencies,
}) async {
  final shellCommand = await resolveShellCommand(dependencies: dependencies);
  final command = shellCommand.command;
  final spawn = dependencies?.spawn ?? _spawnShellProcess;
  final resolvePlatformKey =
      dependencies?.resolveCurrentPlatformKey ?? resolveCurrentPlatformKey;

  final ShellCloseEvent close;
  try {
    close = await spawn(command, List.of(shellCommand.args), directory);
  } catch (error) {
    throw DotweaveError(
      'Failed to launch shell.',
      details: ['Shell: $command', extractErrorMessage(error)],
      hint: _createShellFailureHint(resolvePlatformKey),
    );
  }

  if (close.code == 0) {
    return;
  }

  throw _createShellExitError(command, close.code, close.signal);
}
