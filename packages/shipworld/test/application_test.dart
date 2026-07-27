import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('CLI exposes help for every public command', () async {
    for (final arguments in const [
      ['--help'],
      ['release', 'prepare', '--help'],
      ['release', 'finalize', '--help'],
      ['release', 'verify', '--help'],
      ['package', 'windows', 'msix', '--help'],
      ['package', 'windows', 'bundle', '--help'],
      ['package', 'macos', 'sign', '--help'],
      ['package', 'macos', 'archive', '--help'],
      ['package', 'linux', 'appimage', '--help'],
      ['package', 'homebrew', 'formula', '--help'],
      ['package', 'homebrew', 'cask', '--help'],
    ]) {
      final result = await _run(arguments);
      expect(result.exitCode, 0, reason: arguments.join(' '));
    }
  });

  test('CLI reports unknown commands without a stack trace', () async {
    final result = await _run(const ['unknown']);

    expect(result.exitCode, isNot(0));
    expect('${result.stdout}${result.stderr}', isNot(contains('Stack trace')));
  });

  test('CLI reports missing packaging credentials cleanly', () async {
    final result = await _run(const [
      'package',
      'windows',
      'msix',
      'fixture',
      '--config',
      'test/fixtures/flutter_app/shipworld.yaml',
      '--input',
      'test/fixtures/flutter_app',
      '--output',
      'ignored.msix',
      '--package-root',
      'ignored',
      '--arch',
      'x64',
    ]);

    expect(result.exitCode, 1);
    expect('${result.stdout}${result.stderr}', contains('SHIPWORLD_MSIX_NAME'));
    expect('${result.stdout}${result.stderr}', isNot(contains('Stack trace')));
  });

  test('CLI writes current and versioned Homebrew Formulae', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'shipworld-formula-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    for (final name in const [
      'shipworld-fixture-macos-arm64',
      'shipworld-fixture-macos-x64',
      'shipworld-fixture-linux-arm64',
      'shipworld-fixture-linux-x64',
    ]) {
      await File(p.join(temporary.path, name)).writeAsString(name);
    }
    final current = p.join(temporary.path, 'shipworld-fixture.rb');
    final versioned = p.join(temporary.path, 'shipworld-fixture@1.2.3.rb');

    final result = await _run([
      'package',
      'homebrew',
      'formula',
      'fixture',
      '--config',
      p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'flutter_app',
        'shipworld.yaml',
      ),
      '--artifacts-dir',
      temporary.path,
      '--output',
      current,
      '--versioned-output',
      versioned,
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      await File(current).readAsString(),
      contains('class ShipworldFixture'),
    );
    expect(
      await File(versioned).readAsString(),
      allOf(
        contains('class ShipworldFixtureAT123 < Formula'),
        contains('keg_only :versioned_formula'),
      ),
    );
  });
}

Future<ProcessResult> _run(List<String> arguments) {
  return Process.run(
    Platform.resolvedExecutable,
    ['run', 'bin/shipworld.dart', ...arguments],
    workingDirectory: Directory.current.path,
    runInShell: false,
    environment: {
      ...Platform.environment,
      'SHIPWORLD_MSIX_NAME': '',
      'SHIPWORLD_MSIX_PUBLISHER': '',
      'SHIPWORLD_MSIX_PUBLISHER_NAME': '',
    },
  );
}
