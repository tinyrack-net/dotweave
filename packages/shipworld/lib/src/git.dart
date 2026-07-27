import 'dart:io';

import 'error.dart';

/// Injectable Git command boundary.
abstract interface class GitClient {
  Future<String> run(
    List<String> arguments, {
    required String workingDirectory,
  });
}

/// Git client backed by the system `git` executable.
final class IoGitClient implements GitClient {
  const IoGitClient({this.environment});

  final Map<String, String>? environment;

  @override
  Future<String> run(
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    final command = 'git ${arguments.join(' ')}';
    ProcessResult result;

    try {
      result = await Process.run(
        'git',
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false,
      );
    } on ProcessException catch (error) {
      final message = error.message.trim();
      throw ShipworldException(
        message.isEmpty ? '$command failed' : '$command failed: $message',
        code: 'git_start_failed',
      );
    }

    if (result.exitCode != 0) {
      final stderrText = (result.stderr as String).trim();
      throw ShipworldException(
        stderrText.isEmpty ? '$command failed' : '$command failed: $stderrText',
        code: 'git_command_failed',
      );
    }

    // Git's porcelain formats use leading spaces as structural data. Remove
    // only trailing line endings so callers can parse those formats safely.
    return (result.stdout as String).trimRight();
  }
}
