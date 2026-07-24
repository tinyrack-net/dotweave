import 'dart:io';

import 'error.dart';

/// Runs a git subcommand and returns the raw [ProcessResult].
typedef GitRunner =
    Future<ProcessResult> Function(List<String> args, String workingDirectory);

Future<ProcessResult> _runGitProcess(
  List<String> args,
  String workingDirectory,
) {
  return Process.run(
    'git',
    args,
    workingDirectory: workingDirectory,
    runInShell: false,
  );
}

/// The default runner that spawns a real `git` process.
final GitRunner defaultGitRunner = _runGitProcess;

/// Process runner used by the git helpers. Overridable for tests.
GitRunner gitRunner = _runGitProcess;

Future<String> getRepoRoot(String cwd) {
  return _runGit(['rev-parse', '--show-toplevel'], cwd);
}

Future<String> getWorktreeStatus(String repoRoot) {
  return _runGit(['status', '--porcelain'], repoRoot);
}

Future<bool> hasTag(String repoRoot, String tag) async {
  final stdout = await _runGit(['tag', '--list', tag], repoRoot);

  return stdout == tag;
}

Future<void> stageFiles(String repoRoot, List<String> filePaths) async {
  await _runGit(['add', ...filePaths], repoRoot);
}

Future<void> createCommit(String repoRoot, String message) async {
  await _runGit(['commit', '-m', message], repoRoot);
}

Future<void> createTag(
  String repoRoot,
  String tag,
  String message, {
  bool sign = true,
}) async {
  final tagMode = sign ? '-s' : '-a';

  await _runGit(['tag', tagMode, tag, '-m', message], repoRoot);
}

Future<String> _runGit(List<String> args, String workingDirectory) async {
  final command = 'git ${args.join(' ')}';
  ProcessResult result;

  try {
    result = await gitRunner(args, workingDirectory);
  } on ProcessException catch (error) {
    final message = error.message.trim();

    throw ToolException(
      message.isEmpty ? '$command failed' : '$command failed: $message',
    );
  }

  if (result.exitCode != 0) {
    final stderrText = (result.stderr as String).trim();

    throw ToolException(
      stderrText.isEmpty ? '$command failed' : '$command failed: $stderrText',
    );
  }

  return (result.stdout as String).trim();
}
