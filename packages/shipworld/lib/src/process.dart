import 'dart:async';
import 'dart:io';

import 'error.dart';

/// Injectable process boundary used by packaging and signing operations.
abstract interface class ProcessExecutor {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });

  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

final class IoProcessExecutor implements ProcessExecutor {
  const IoProcessExecutor();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  }

  @override
  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

const ProcessExecutor defaultProcessExecutor = IoProcessExecutor();

final Object _processExecutorZoneKey = Object();

ProcessExecutor get _activeProcessExecutor =>
    Zone.current[_processExecutorZoneKey] as ProcessExecutor? ??
    defaultProcessExecutor;

Future<T> runWithProcessExecutor<T>(
  ProcessExecutor executor,
  Future<T> Function() body,
) {
  return runZoned(
    body,
    zoneValues: <Object, Object>{_processExecutorZoneKey: executor},
  );
}

/// Result of a captured child process run.
class CommandResult {
  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs [executable] with [args] and captures stdout/stderr.
///
/// Throws [ShipworldException] when the executable cannot be started. Callers are
/// responsible for interpreting non-zero exit codes.
Future<CommandResult> runCapture(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessExecutor? executor,
}) async {
  ProcessResult result;

  try {
    result = await (executor ?? _activeProcessExecutor).run(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  } on ProcessException catch (error) {
    throw ShipworldException(
      '$executable ${args.join(' ')} failed: ${error.message}',
    );
  }

  return CommandResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

/// Runs [executable] with [args], capturing output, and throws
/// [ShipworldException] when the process exits with a non-zero code.
Future<CommandResult> runChecked(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessExecutor? executor,
}) async {
  final result = await runCapture(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
    executor: executor,
  );

  if (result.exitCode != 0) {
    throw ShipworldException(
      '$executable ${args.join(' ')} failed with exit code '
      '${result.exitCode}.\nstdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }

  return result;
}

/// Runs [executable] with [args] with stdio inherited from the parent
/// process, throwing [ShipworldException] on a non-zero exit code.
Future<void> runInherited(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessExecutor? executor,
}) async {
  int exitCode;

  try {
    exitCode = await (executor ?? _activeProcessExecutor).runInherited(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  } on ProcessException catch (error) {
    throw ShipworldException(
      '$executable ${args.join(' ')} failed: ${error.message}',
    );
  }

  if (exitCode != 0) {
    throw ShipworldException(
      '$executable ${args.join(' ')} failed with exit code $exitCode',
    );
  }
}
