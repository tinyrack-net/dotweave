import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

import '../../tool/smoke.dart';

final class _SmokeExecutor implements ProcessExecutor {
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add(arguments);
    return switch (arguments) {
      ['--version'] => ProcessResult(0, 0, 'dotweave/2.0.0\n', ''),
      [] => ProcessResult(0, 0, 'autocomplete\ntrack\nprofile\n', ''),
      ['track', '--help'] => ProcessResult(0, 0, '--mode\n--profile\n', ''),
      ['profile', 'use', '--help'] => ProcessResult(
        0,
        0,
        'Profile name to activate\n',
        '',
      ),
      ['add', '~/.gitconfig'] => ProcessResult(
        0,
        64,
        '',
        'Command "add" not found.\n',
      ),
      _ => ProcessResult(0, 1, '', 'unexpected command'),
    };
  }

  @override
  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    throw UnsupportedError('not used');
  }
}

void main() {
  test('checks the complete Dotweave binary contract', () async {
    final root = await Directory.systemTemp.createTemp('dotweave-smoke-');
    addTearDown(() => root.delete(recursive: true));
    final cliDirectory = Directory(p.join(root.path, 'packages', 'cli'));
    await cliDirectory.create(recursive: true);
    await File(
      p.join(cliDirectory.path, 'pubspec.yaml'),
    ).writeAsString('name: dotweave\nversion: 2.0.0\n');
    final executor = _SmokeExecutor();

    await performSmoke(
      repoRoot: root.path,
      executablePath: p.join('packages', 'cli', 'dotweave'),
      executor: executor,
    );

    expect(executor.calls, [
      ['--version'],
      <String>[],
      ['track', '--help'],
      ['profile', 'use', '--help'],
      ['add', '~/.gitconfig'],
    ]);
  });
}
