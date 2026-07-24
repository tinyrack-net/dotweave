import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';
import 'exec.dart';
import 'version_files.dart';

const Map<String, String> _smokeEnvironment = {
  'FORCE_COLOR': '0',
  'NODE_NO_WARNINGS': '1',
  'NODE_OPTIONS': '',
  'NO_COLOR': '1',
};

void _assertCommandSucceeded(String label, CommandResult result) {
  if (result.exitCode == 0) {
    return;
  }

  throw ToolException(
    '$label failed with exit code ${result.exitCode}.\n'
    'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
  );
}

void _assertIncludes(String label, String actual, String expected) {
  if (actual.contains(expected)) {
    return;
  }

  throw ToolException(
    '$label did not include "$expected".\nactual output:\n$actual',
  );
}

void _assertEmpty(String label, String actual) {
  if (actual.isEmpty) {
    return;
  }

  throw ToolException(
    '$label was expected to be empty.\nactual output:\n$actual',
  );
}

/// Runs the compiled dotweave executable and asserts the smoke contract:
/// version string, help output, and removed-command error.
Future<void> performSmoke({
  required String repoRoot,
  required String executablePath,
}) async {
  final resolvedExecutablePath = p.join(repoRoot, executablePath);
  final version = await readPubspecVersion(
    p.join(repoRoot, 'packages', 'cli_dart', 'pubspec.yaml'),
  );

  Future<CommandResult> runExecutable(List<String> args) {
    return runCapture(
      resolvedExecutablePath,
      args,
      workingDirectory: repoRoot,
      environment: _smokeEnvironment,
    );
  }

  final versionResult = await runExecutable(['--version']);
  _assertCommandSucceeded('smoke --version', versionResult);
  _assertIncludes(
    'smoke --version stdout',
    versionResult.stdout,
    'dotweave/$version',
  );
  _assertEmpty('smoke --version stderr', versionResult.stderr);

  final rootHelpResult = await runExecutable([]);
  _assertCommandSucceeded('smoke root help', rootHelpResult);
  _assertIncludes('smoke root help', rootHelpResult.stdout, 'autocomplete');
  _assertIncludes('smoke root help', rootHelpResult.stdout, 'track');
  _assertIncludes('smoke root help', rootHelpResult.stdout, 'profile');
  _assertEmpty('smoke root help stderr', rootHelpResult.stderr);

  final trackHelpResult = await runExecutable(['track', '--help']);
  _assertCommandSucceeded('smoke track --help', trackHelpResult);
  _assertIncludes('smoke track --help', trackHelpResult.stdout, '--mode');
  _assertIncludes('smoke track --help', trackHelpResult.stdout, '--profile');
  _assertEmpty('smoke track --help stderr', trackHelpResult.stderr);

  final profileHelpResult = await runExecutable(['profile', 'use', '--help']);
  _assertCommandSucceeded('smoke profile use --help', profileHelpResult);
  _assertIncludes(
    'smoke profile use --help',
    profileHelpResult.stdout,
    'Profile name to activate',
  );
  _assertEmpty('smoke profile use --help stderr', profileHelpResult.stderr);

  final removedCommandResult = await runExecutable(['add', '~/.gitconfig']);

  if (removedCommandResult.exitCode == 0) {
    throw ToolException(
      'smoke removed command unexpectedly succeeded.\n'
      'stdout:\n${removedCommandResult.stdout}\n'
      'stderr:\n${removedCommandResult.stderr}',
    );
  }

  _assertIncludes(
    'smoke removed command stderr',
    removedCommandResult.stderr,
    'not found',
  );

  stdout.writeln('smoke test passed with $resolvedExecutablePath');
}
