// Build tool for the e2e test binary.
//
// Compiles `bin/dotweave.dart` to a native executable under
// `.dart_tool/dotweave_e2e/` so the e2e suites can spawn the CLI as a real
// process (the Dart equivalent of the TS suites spawning `node` against
// `src/index.ts` / `bin/index.js`). Recompilation is skipped when the
// executable is newer than every file under `lib/` and `bin/` unless
// `--force` is passed.
//
// Usage: dart tool/build_e2e.dart [--force]
//
// Prints the absolute path of the compiled executable on success. The compile
// logic is also imported by `test/helpers/e2e_context.dart` so a test run can
// build the binary on demand when no prebuilt executable exists; a lock file
// serializes concurrent builds across test isolates.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Walks up from [start] (defaults to the current working directory) to the
/// dotweave Dart package root: the nearest directory whose `pubspec.yaml`
/// declares `name: dotweave`.
String findPackageRoot([String? start]) {
  var directory = p.normalize(p.absolute(start ?? Directory.current.path));

  while (true) {
    final pubspec = File(p.join(directory, 'pubspec.yaml'));

    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains(
          RegExp(r'^name: dotweave$', multiLine: true),
        )) {
      return directory;
    }

    final parent = p.dirname(directory);

    if (parent == directory) {
      throw StateError(
        'Could not find the dotweave package root (a pubspec.yaml with '
        '"name: dotweave") above ${start ?? Directory.current.path}. Run '
        'from the repo root.',
      );
    }

    directory = parent;
  }
}

/// Path of the compiled e2e executable for [packageRoot]
/// (`.dart_tool/dotweave_e2e/dotweave.exe` on Windows, no extension on
/// POSIX).
String e2eBinaryPath(String packageRoot) {
  return p.join(
    packageRoot,
    '.dart_tool',
    'dotweave_e2e',
    Platform.isWindows ? 'dotweave.exe' : 'dotweave',
  );
}

DateTime? _newestSourceModification(String packageRoot) {
  DateTime? newest;

  for (final directoryName in const ['lib', 'bin']) {
    final directory = Directory(p.join(packageRoot, directoryName));

    if (!directory.existsSync()) {
      continue;
    }

    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }

      final modified = entity.statSync().modified;

      if (newest == null || modified.isAfter(newest)) {
        newest = modified;
      }
    }
  }

  return newest;
}

bool _isUpToDate(String packageRoot, String binaryPath) {
  final binary = File(binaryPath);

  if (!binary.existsSync()) {
    return false;
  }

  final newestSource = _newestSourceModification(packageRoot);

  if (newestSource == null) {
    return true;
  }

  return binary.statSync().modified.isAfter(newestSource);
}

/// Ensures the compiled e2e executable exists and is newer than every source
/// file under `lib/` and `bin/`, compiling it via `dart compile exe` when it
/// is missing or stale (always when [force] is set). Returns the absolute
/// executable path. Concurrent callers (e.g. parallel test isolates compiling
/// on demand) are serialized through an exclusive lock file next to the
/// executable.
Future<String> ensureE2eBinary({
  bool force = false,
  String? packageRoot,
}) async {
  final root = packageRoot ?? findPackageRoot();
  final binaryPath = e2eBinaryPath(root);
  final outputDirectory = Directory(p.dirname(binaryPath));

  await outputDirectory.create(recursive: true);

  final lockHandle = await File(
    p.join(outputDirectory.path, 'build.lock'),
  ).open(mode: FileMode.write);

  await lockHandle.lock(FileLock.blockingExclusive);

  try {
    if (!force && _isUpToDate(root, binaryPath)) {
      return binaryPath;
    }

    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'exe',
        p.join(root, 'bin', 'dotweave.dart'),
        '-o',
        binaryPath,
      ],
      workingDirectory: root,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode != 0) {
      throw StateError(
        'dart compile exe failed with exit code ${result.exitCode}\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
      );
    }

    return binaryPath;
  } finally {
    await lockHandle.unlock();
    await lockHandle.close();
  }
}

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final binaryPath = await ensureE2eBinary(force: force);

  stdout.writeln(binaryPath);
}
