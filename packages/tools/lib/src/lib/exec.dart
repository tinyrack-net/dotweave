import 'dart:io';

import 'error.dart';

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
/// Throws [ToolException] when the executable cannot be started. Callers are
/// responsible for interpreting non-zero exit codes.
Future<CommandResult> runCapture(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  ProcessResult result;

  try {
    result = await Process.run(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  } on ProcessException catch (error) {
    throw ToolException(
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
/// [ToolException] when the process exits with a non-zero code.
Future<CommandResult> runChecked(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await runCapture(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  if (result.exitCode != 0) {
    throw ToolException(
      '$executable ${args.join(' ')} failed with exit code '
      '${result.exitCode}.\nstdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }

  return result;
}

/// Runs [executable] with [args] with stdio inherited from the parent
/// process, throwing [ToolException] on a non-zero exit code.
Future<void> runInherited(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  Process process;

  try {
    process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (error) {
    throw ToolException(
      '$executable ${args.join(' ')} failed: ${error.message}',
    );
  }

  final exitCode = await process.exitCode;

  if (exitCode != 0) {
    throw ToolException(
      '$executable ${args.join(' ')} failed with exit code $exitCode',
    );
  }
}
