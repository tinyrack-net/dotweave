import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main() async {
  final packageRoot = p.normalize(
    p.absolute(p.join(p.dirname(Platform.script.toFilePath()), '..')),
  );
  final temporary = await Directory.systemTemp.createTemp(
    'shipworld-standalone-',
  );
  try {
    final destination = p.join(temporary.path, 'shipworld');
    await _copyPackage(packageRoot, destination);
    final pubspec = File(p.join(destination, 'pubspec.yaml'));
    final content = await pubspec.readAsLines();
    await pubspec.writeAsString(
      '${content.where((line) => line.trim() != 'resolution: workspace').join('\n')}\n',
    );
    for (final command in const [
      ['pub', 'get'],
      ['analyze', '--fatal-infos'],
      ['test'],
      ['doc'],
      ['pub', 'publish', '--dry-run'],
      ['pub', 'global', 'run', 'pana:pana', '--exit-code-threshold', '0', '.'],
    ]) {
      final result = await Process.run(
        Platform.resolvedExecutable,
        command,
        workingDirectory: destination,
        runInShell: false,
      );
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      if (result.exitCode != 0) {
        throw StateError('dart ${command.join(' ')} failed');
      }
    }
    stdout.writeln('Standalone Shipworld package validation passed.');
  } finally {
    await temporary.delete(recursive: true);
  }
}

Future<void> _copyPackage(String sourcePath, String destinationPath) async {
  final source = Directory(sourcePath);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: sourcePath);
    final segments = p.split(relative);
    if (segments.any(
      (segment) =>
          segment == '.dart_tool' ||
          segment == 'build' ||
          segment == 'doc' && segments.length > 1 && segments[1] == 'api',
    )) {
      continue;
    }
    final destination = p.join(destinationPath, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await Directory(p.dirname(destination)).create(recursive: true);
      await entity.copy(destination);
    }
  }
}
