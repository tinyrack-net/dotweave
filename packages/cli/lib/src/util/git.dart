import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/util/error.dart';

class GitCommandOptions {
  const GitCommandOptions({this.cwd});

  final String? cwd;
}

class GitCommandResult {
  const GitCommandResult({required this.stderr, required this.stdout});

  final String stderr;
  final String stdout;
}

/// Mirrors the Node execFile failure shape that carries captured output.
class GitExecFileException implements Exception {
  GitExecFileException(this.message, {this.stderr, this.stdout});

  final String message;
  final String? stderr;
  final String? stdout;

  @override
  String toString() => message;
}

typedef GitExecFileAsync =
    Future<GitCommandResult> Function(
      String file,
      List<String> args, {
      String? cwd,
    });

/// Mirrors the Node spawn child: output streams plus a future that completes
/// with the exit code (null when the child closed without one) or errors when
/// spawning fails.
class GitStreamingChild {
  const GitStreamingChild({this.stderr, this.stdout, required this.result});

  final Stream<String>? stderr;
  final Stream<String>? stdout;
  final Future<int?> result;
}

typedef GitSpawn =
    GitStreamingChild Function(
      String command,
      List<String> args, {
      String? cwd,
    });

class GitCommandDependencies {
  const GitCommandDependencies({required this.execFileAsync});

  final GitExecFileAsync execFileAsync;
}

class StreamingGitCommandDependencies {
  const StreamingGitCommandDependencies({required this.spawnGit});

  final GitSpawn spawnGit;
}

class InitializeRepositoryResult {
  const InitializeRepositoryResult({required this.action, this.source});

  final String action;
  final String? source;
}

const _missingGitExecutableCode = 'GIT_EXECUTABLE_NOT_FOUND';

/// Error code for "git ran but exited non-zero".
const String gitCommandFailedCode = 'GIT_COMMAND_FAILED';

/// Whether [error] is a non-zero git exit surfaced by this module.
bool isGitCommandFailedError(Object? error) {
  return error is DotweaveError && error.code == gitCommandFailedCode;
}

/// Builds the user-facing failure for a git command that exited non-zero.
///
/// [primary] keeps the historical first line (stderr, else stdout, else the
/// exec failure message). [discarded] carries output the old
/// `throw Exception(primary)` dropped on the floor -- in practice only the
/// rare case where git wrote to both streams.
DotweaveError _createGitCommandFailedError(
  String primary, {
  List<String?> discarded = const [],
}) {
  return DotweaveError(
    primary,
    code: gitCommandFailedCode,
    details: compactLines(
      discarded.where((line) => line?.trim() != primary.trim()),
    ),
  );
}

bool _isEnoentError(Object error) {
  return error is ProcessException && error.errorCode == 2;
}

DotweaveError _createMissingGitExecutableError() {
  return DotweaveError(
    'Git is not installed or not on PATH.',
    code: _missingGitExecutableCode,
    hint:
        'Install Git and ensure the git executable is available on PATH, '
        'then run dotweave again.',
  );
}

bool isMissingGitExecutableError(Object? error) {
  return error is DotweaveError && error.code == _missingGitExecutableCode;
}

/// Runs a git command and normalizes failures into concise errors.
Future<GitCommandResult> runGitCommandWithDependencies(
  List<String> args,
  GitCommandOptions? options,
  GitCommandDependencies dependencies,
) async {
  try {
    final result = await dependencies.execFileAsync(
      'git',
      List.of(args),
      cwd: options?.cwd,
    );

    return GitCommandResult(stderr: result.stderr, stdout: result.stdout);
  } catch (error) {
    if (_isEnoentError(error)) {
      throw _createMissingGitExecutableError();
    }

    if (error is GitExecFileException) {
      final stderr = error.stderr?.trim();
      final stdout = error.stdout?.trim();
      final message = stderr != null && stderr.isNotEmpty
          ? stderr
          : stdout != null && stdout.isNotEmpty
          ? stdout
          : error.message;

      throw _createGitCommandFailedError(message, discarded: [stdout]);
    }

    throw _createGitCommandFailedError(
      error is Exception || error is Error
          ? extractErrorMessage(error)
          : 'git failed.',
    );
  }
}

/// Spawns a command and captures its output, mirroring the Node
/// `promisify(execFile)` call shape, and raising [GitExecFileException] on a
/// non-zero exit.
///
/// Public because `services/repo_artifacts.dart` runs its own `git show` and
/// needs the same default rather than a second copy of this function.
Future<GitCommandResult> defaultGitExecFile(
  String file,
  List<String> args, {
  String? cwd,
}) async {
  final result = await Process.run(
    file,
    args,
    workingDirectory: cwd,
    runInShell: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final stdout = result.stdout as String;
  final stderr = result.stderr as String;

  if (result.exitCode != 0) {
    throw GitExecFileException(
      'Command failed: $file ${args.join(' ')}',
      stderr: stderr,
      stdout: stdout,
    );
  }

  return GitCommandResult(stderr: stderr, stdout: stdout);
}

Future<GitCommandResult> _runGitCommand(
  List<String> args, [
  GitCommandOptions? options,
]) async {
  return runGitCommandWithDependencies(
    args,
    options,
    const GitCommandDependencies(execFileAsync: defaultGitExecFile),
  );
}

/// Runs a git command while collecting output.
Future<GitCommandResult> runStreamingGitCommandWithDependencies(
  List<String> args,
  GitCommandOptions? options,
  StreamingGitCommandDependencies dependencies,
) async {
  final child = dependencies.spawnGit('git', List.of(args), cwd: options?.cwd);
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final stdoutDone =
      child.stdout?.forEach(stdoutBuffer.write) ?? Future<void>.value();
  final stderrDone =
      child.stderr?.forEach(stderrBuffer.write) ?? Future<void>.value();

  final int? code;
  try {
    code = await child.result;
  } catch (error) {
    if (_isEnoentError(error)) {
      throw _createMissingGitExecutableError();
    }

    throw _createGitCommandFailedError(
      error is Exception || error is Error
          ? extractErrorMessage(error)
          : 'git failed.',
    );
  }

  await stdoutDone;
  await stderrDone;

  final stdout = stdoutBuffer.toString();
  final stderr = stderrBuffer.toString();

  if (code == 0) {
    return GitCommandResult(stderr: stderr, stdout: stdout);
  }

  final trimmedStderr = stderr.trim();
  final trimmedStdout = stdout.trim();

  throw _createGitCommandFailedError(
    trimmedStderr.isNotEmpty
        ? trimmedStderr
        : trimmedStdout.isNotEmpty
        ? trimmedStdout
        : 'git exited with code ${code ?? 'unknown'}.',
    discarded: [trimmedStdout],
  );
}

/// Pumps a spawned child's output into [stdoutSink]/[stderrSink] and completes
/// [result] with its exit code.
///
/// Takes the streams rather than the `Process` on purpose. The one way this
/// can go wrong is for the pump to fail without completing [result], which
/// leaves every caller of `GitStreamingChild.result` awaiting forever — and
/// that failure is only reachable in a test if the streams can be supplied
/// directly.
Future<void> pumpProcessOutput({
  required Stream<List<int>> stdout,
  required Stream<List<int>> stderr,
  required Future<int> exitCode,
  required StreamController<String> stdoutSink,
  required StreamController<String> stderrSink,
  required Completer<int?> result,
}) async {
  Future<void>? stdoutDone;
  Future<void>? stderrDone;

  try {
    stdoutDone = stdoutSink.addStream(stdout.transform(utf8.decoder));
    stderrDone = stderrSink.addStream(stderr.transform(utf8.decoder));

    final code = await exitCode;

    await stdoutDone;
    await stderrDone;
    result.complete(code);
  } catch (error, stackTrace) {
    if (!result.isCompleted) {
      result.completeError(error, stackTrace);
    }
  } finally {
    // `close()` throws while an `addStream` is still in flight, so a pump left
    // running by the failure path above has to settle first. The child is gone
    // by then, so its streams end promptly.
    await _settle(stdoutDone);
    await _settle(stderrDone);
    await stdoutSink.close();
    await stderrSink.close();
  }
}

/// Awaits [pending], discarding any error: it has already been reported
/// through the pump's result completer.
Future<void> _settle(Future<void>? pending) async {
  if (pending == null) {
    return;
  }

  try {
    await pending;
  } catch (_) {
    // Intentionally ignored; see doc comment.
  }
}

GitStreamingChild _spawnGitProcess(
  String command,
  List<String> args, {
  String? cwd,
}) {
  final stdoutController = StreamController<String>();
  final stderrController = StreamController<String>();
  final resultCompleter = Completer<int?>();

  unawaited(
    Process.start(command, args, workingDirectory: cwd, runInShell: false).then(
      (process) => pumpProcessOutput(
        stdout: process.stdout,
        stderr: process.stderr,
        exitCode: process.exitCode,
        stdoutSink: stdoutController,
        stderrSink: stderrController,
        result: resultCompleter,
      ),
      onError: (Object error, StackTrace stackTrace) async {
        await stdoutController.close();
        await stderrController.close();
        if (!resultCompleter.isCompleted) {
          resultCompleter.completeError(error, stackTrace);
        }
      },
    ),
  );

  return GitStreamingChild(
    stderr: stderrController.stream,
    stdout: stdoutController.stream,
    result: resultCompleter.future,
  );
}

Future<GitCommandResult> _runStreamingGitCommand(
  List<String> args, [
  GitCommandOptions? options,
]) async {
  return runStreamingGitCommandWithDependencies(
    args,
    options,
    const StreamingGitCommandDependencies(spawnGit: _spawnGitProcess),
  );
}

/// Verifies that a directory is already a git working tree.
Future<void> verifyIsGitRepository(String directory) async {
  await _runGitCommand(['-C', directory, 'rev-parse', '--is-inside-work-tree']);
}

/// Creates a sync directory locally or clones it from a remote source.
Future<InitializeRepositoryResult> initializeRepository(
  String directory, [
  String? source,
]) async {
  if (source == null) {
    await _runStreamingGitCommand(['init', '-b', 'main', directory]);

    return const InitializeRepositoryResult(action: 'initialized');
  }

  await _runStreamingGitCommand(['clone', source, directory]);

  return InitializeRepositoryResult(action: 'cloned', source: source);
}

/// Ensures the sync directory is a usable git repository for dotweave
/// commands.
Future<void> requireGitRepository(String syncDirectory) async {
  try {
    await verifyIsGitRepository(syncDirectory);
  } catch (error) {
    throw wrapUnknownError(
      'Sync repository is not initialized.',
      error,
      code: 'SYNC_REPO_INVALID',
      details: ['Sync directory: $syncDirectory'],
      hint: "Run 'dotweave init' to create or clone the sync directory.",
    );
  }
}
