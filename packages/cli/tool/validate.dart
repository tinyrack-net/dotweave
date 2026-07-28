import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';

/// A single repository validation process.
class ValidationTask {
  const ValidationTask({
    required this.name,
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
  });

  final String name;
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

/// The result of one [ValidationTask].
class ValidationTaskResult {
  const ValidationTaskResult({required this.task, required this.exitCode});

  final ValidationTask task;
  final int exitCode;

  bool get succeeded => exitCode == 0;
}

/// Supported subsets of the Dart workspace validation graph.
enum ValidationTarget {
  dartAll,
  dartStatic('dart-static'),
  dartTests('dart-tests');

  const ValidationTarget([this.cliName]);

  final String? cliName;

  static ValidationTarget? fromCliName(String value) {
    for (final target in values) {
      if (target.cliName == value) return target;
    }
    return null;
  }
}

typedef ValidationTaskRunner =
    Future<ValidationTaskResult> Function(ValidationTask task);
typedef ValidationLogger = void Function(String message);

/// Runs a validation process with inherited stdio.
Future<ValidationTaskResult> runValidationTask(
  ValidationTask task, {
  ProcessExecutor executor = defaultProcessExecutor,
}) async {
  try {
    final exitCode = await executor.runInherited(
      task.executable,
      task.arguments,
      workingDirectory: task.workingDirectory,
    );
    return ValidationTaskResult(task: task, exitCode: exitCode);
  } on ProcessException {
    return ValidationTaskResult(task: task, exitCode: 127);
  }
}

/// Runs the selected validation graph and returns the first failing exit code.
///
/// Every task already running in a parallel stage is allowed to finish before
/// the stage fails. Dependent stages are not started after a failure.
Future<int> runValidation({
  required String repoRoot,
  required ValidationTarget target,
  ValidationTaskRunner runner = runValidationTask,
  ValidationLogger log = _defaultLog,
}) async {
  final paths = _ValidationPaths(repoRoot);

  switch (target) {
    case ValidationTarget.dartStatic:
      final prepared = await _runStage(
        [paths.dartPubGet],
        runner: runner,
        log: log,
      );
      if (prepared != 0) return prepared;
      return _runStage(paths.dartStatic, runner: runner, log: log);
    case ValidationTarget.dartTests:
      final prepared = await _runStage(
        [paths.dartPubGet],
        runner: runner,
        log: log,
      );
      if (prepared != 0) return prepared;
      final built = await _runStage([paths.buildE2e], runner: runner, log: log);
      if (built != 0) return built;
      return _runStage(paths.dartTests, runner: runner, log: log);
    case ValidationTarget.dartAll:
      final prepared = await _runStage(
        [paths.dartPubGet],
        runner: runner,
        log: log,
      );
      if (prepared != 0) return prepared;
      final checked = await _runStage(
        [...paths.dartStatic, paths.buildE2e],
        runner: runner,
        log: log,
      );
      if (checked != 0) return checked;
      return _runStage(paths.dartTests, runner: runner, log: log);
  }
}

Future<int> _runStage(
  List<ValidationTask> tasks, {
  required ValidationTaskRunner runner,
  required ValidationLogger log,
}) async {
  for (final task in tasks) {
    log('▶ ${task.name}');
  }

  final results = await Future.wait([for (final task in tasks) runner(task)]);

  for (final result in results) {
    log(
      result.succeeded
          ? '✔ ${result.task.name}'
          : '✖ ${result.task.name} (exit ${result.exitCode})',
    );
  }
  for (final result in results) {
    if (!result.succeeded) return result.exitCode;
  }
  return 0;
}

void _defaultLog(String message) {
  stdout.writeln('[validate] $message');
}

final class _ValidationPaths {
  const _ValidationPaths(this.repoRoot);

  final String repoRoot;

  String get cliRoot => p.join(repoRoot, 'packages', 'cli');

  ValidationTask get dartPubGet => ValidationTask(
    name: 'Dart dependencies',
    executable: 'dart',
    arguments: const ['pub', 'get'],
    workingDirectory: repoRoot,
  );

  List<ValidationTask> get dartStatic => [
    ValidationTask(
      name: 'Dart format',
      executable: 'dart',
      arguments: const [
        'format',
        '--output=none',
        '--set-exit-if-changed',
        'packages/cli',
      ],
      workingDirectory: repoRoot,
    ),
    ValidationTask(
      name: 'Dart analyze',
      executable: 'dart',
      arguments: const ['analyze', '--fatal-infos'],
      workingDirectory: repoRoot,
    ),
  ];

  ValidationTask get buildE2e => ValidationTask(
    name: 'CLI e2e binary',
    executable: 'dart',
    arguments: const ['tool/build_e2e.dart'],
    workingDirectory: cliRoot,
  );

  List<ValidationTask> get dartTests => [_dartTest('CLI tests', 'cli')];

  ValidationTask _dartTest(String name, String packageName) {
    return ValidationTask(
      name: name,
      executable: 'dart',
      arguments: const ['test'],
      workingDirectory: p.join(repoRoot, 'packages', packageName),
    );
  }
}

Future<String> _repoRoot() {
  return const IoGitClient().run(const [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: Directory.current.path);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length > 1 ||
      (arguments.isNotEmpty &&
          !const {'dart-static', 'dart-tests'}.contains(arguments.single))) {
    stderr.writeln(
      'Usage: dart run packages/cli/tool/validate.dart '
      '[dart-static|dart-tests]',
    );
    exitCode = 64;
    return;
  }

  final target = arguments.isEmpty
      ? ValidationTarget.dartAll
      : ValidationTarget.fromCliName(arguments.single)!;
  exitCode = await runValidation(repoRoot: await _repoRoot(), target: target);
}
