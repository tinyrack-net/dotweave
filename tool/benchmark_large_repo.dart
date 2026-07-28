// Benchmarks the Dart CLI (compiled AOT executable) standalone using a
// synthetic "large repository" fixture: thousands of small config-like files
// plus a handful of larger asset-like files, spread across nested
// directories. (An earlier version compared against the since-removed
// TypeScript CLI; that comparison served the migration and is gone.)
//
// Usage (from the repo root): dart run tool/benchmark_large_repo.dart
//
// This is a standalone diagnostic script, not part of the test suite: it
// prints a wall-clock timing table and the Dart binary size to stdout.
// Numbers are machine- and load-dependent; treat them as a rough signal,
// not a certified benchmark.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'build_e2e.dart';

int _dirCount = 50;
int _filesPerDir = 200; // 50 * 200 = 10,000 small files
const int _minFileBytes = 200;
const int _maxFileBytes = 6000;
int _bigFileCount = 20;
const int _bigFileBytes = 500 * 1024; // 20 * 500KB = ~10MB of "assets"
const double _touchFractionValue =
    0.03; // 3% of files changed before incremental push

void _log(String message) => stdout.writeln('[bench] $message');

String _fmtMs(Duration d) =>
    '${(d.inMicroseconds / 1000).toStringAsFixed(1)} ms';

String _fmtBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
}

Duration _average(List<Duration> values) {
  final totalMicros = values.fold<int>(0, (sum, d) => sum + d.inMicroseconds);
  return Duration(microseconds: totalMicros ~/ values.length);
}

/// Generates a deterministic "large repo" fixture under [root]: many small
/// text-like config files across [dirCount] nested directories, plus
/// [bigFileCount] larger binary-like asset files.
({int fileCount, int totalBytes}) _generateFixture(
  String root, {
  int seed = 42,
}) {
  final random = Random(seed);
  final rootDir = Directory(root);
  if (rootDir.existsSync()) {
    rootDir.deleteSync(recursive: true);
  }
  rootDir.createSync(recursive: true);

  var fileCount = 0;
  var totalBytes = 0;

  for (var d = 0; d < _dirCount; d++) {
    final subdir = Directory(p.join(root, 'module-$d'));
    subdir.createSync(recursive: true);
    for (var f = 0; f < _filesPerDir; f++) {
      final size =
          _minFileBytes + random.nextInt(_maxFileBytes - _minFileBytes);
      final bytes = List<int>.generate(size, (_) => 32 + random.nextInt(95));
      File(p.join(subdir.path, 'file-$f.conf')).writeAsBytesSync(bytes);
      fileCount++;
      totalBytes += size;
    }
  }

  final assetsDir = Directory(p.join(root, 'assets'));
  assetsDir.createSync(recursive: true);
  for (var i = 0; i < _bigFileCount; i++) {
    final bytes = List<int>.generate(_bigFileBytes, (_) => random.nextInt(256));
    File(p.join(assetsDir.path, 'blob-$i.bin')).writeAsBytesSync(bytes);
    fileCount++;
    totalBytes += _bigFileBytes;
  }

  return (fileCount: fileCount, totalBytes: totalBytes);
}

Future<void> _copyDirectory(String source, String destination) async {
  await Directory(destination).create(recursive: true);
  await for (final entity in Directory(
    source,
  ).list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source);
    final target = p.join(destination, relative);
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await Directory(p.dirname(target)).create(recursive: true);
      await entity.copy(target);
    }
  }
}

int _touchFraction(String root, double fraction, {int seed = 7}) {
  final random = Random(seed);
  final files = Directory(
    root,
  ).listSync(recursive: true).whereType<File>().toList();
  var touched = 0;
  for (final file in files) {
    if (random.nextDouble() < fraction) {
      file.writeAsBytesSync([random.nextInt(256)], mode: FileMode.append);
      touched++;
    }
  }
  return touched;
}

Map<String, String> _isolatedEnv(String home) {
  final passthrough = <String, String>{};
  for (final key in [
    'PATH',
    'Path',
    'SystemRoot',
    'ComSpec',
    'TEMP',
    'TMP',
    'TERM',
  ]) {
    final value = Platform.environment[key];
    if (value != null) {
      passthrough[key] = value;
    }
  }

  return {
    ...passthrough,
    'HOME': home,
    'USERPROFILE': home,
    'APPDATA': p.join(home, 'AppData', 'Roaming'),
    'LOCALAPPDATA': p.join(home, 'AppData', 'Local'),
    'XDG_CONFIG_HOME': p.join(home, '.config'),
    'NO_COLOR': '1',
    'FORCE_COLOR': '0',
  };
}

String _syncDirectoryFor(String home) {
  return Platform.isWindows
      ? p.join(home, 'AppData', 'Roaming', 'dotweave', 'repository')
      : p.join(home, '.config', 'dotweave', 'repository');
}

String _identityFileFor(String home) {
  return Platform.isWindows
      ? p.join(home, 'AppData', 'Roaming', 'dotweave', 'keys.txt')
      : p.join(home, '.config', 'dotweave', 'keys.txt');
}

/// Drives the compiled CLI executable through an isolated-environment
/// process invocation.
class CliDriver {
  CliDriver(this.label, this.executable);

  final String label;
  final String executable;

  Future<ProcessResult> run(
    List<String> args, {
    required String cwd,
    required Map<String, String> env,
  }) {
    return Process.run(
      executable,
      args,
      workingDirectory: cwd,
      environment: env,
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }
}

Future<void> _runOrThrow(
  CliDriver driver,
  List<String> args,
  String cwd,
  Map<String, String> env,
) async {
  final result = await driver.run(args, cwd: cwd, env: env);
  if (result.exitCode != 0) {
    throw StateError(
      '${driver.label} `${args.join(' ')}` failed (exit ${result.exitCode})\n'
      'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
  }
}

Future<void> _runGit(List<String> args, String cwd) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: cwd,
    environment: {
      'GIT_AUTHOR_NAME': 'bench',
      'GIT_AUTHOR_EMAIL': 'bench@example.com',
      'GIT_COMMITTER_NAME': 'bench',
      'GIT_COMMITTER_EMAIL': 'bench@example.com',
    },
  );
  if (result.exitCode != 0) {
    throw StateError(
      'git ${args.join(' ')} failed (exit ${result.exitCode})\n'
      'stdout: ${result.stdout}\nstderr: ${result.stderr}',
    );
  }
}

Future<Duration> _time(Future<void> Function() action) async {
  final stopwatch = Stopwatch()..start();
  await action();
  stopwatch.stop();
  return stopwatch.elapsed;
}

/// Deletes [directory] recursively, retrying briefly on Windows where a
/// just-exited child process can hold a file handle open for a few
/// milliseconds after `Process.run` returns.
Future<void> _deleteDirectoryWithRetry(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }
  }
}

Future<Map<String, Duration>> _benchmarkCli(
  CliDriver driver,
  String fixtureSource,
) async {
  final timings = <String, Duration>{};
  final workDir = await Directory.systemTemp.createTemp(
    'dotweave-bench-${driver.label}-',
  );

  try {
    final homeA = p.join(workDir.path, 'machine-a');
    Directory(homeA).createSync(recursive: true);
    final envA = _isolatedEnv(homeA);
    final bigDir = p.join(homeA, 'big-project');

    _log('${driver.label}: copying fixture into machine A workspace...');
    await _copyDirectory(fixtureSource, bigDir);

    final versionTimes = <Duration>[];
    for (var i = 0; i < 5; i++) {
      final stopwatch = Stopwatch()..start();
      await driver.run(['--version'], cwd: homeA, env: envA);
      stopwatch.stop();
      versionTimes.add(stopwatch.elapsed);
    }
    timings['startup (--version, avg of 5)'] = _average(versionTimes);

    timings['init'] = await _time(
      () => _runOrThrow(driver, ['init'], homeA, envA),
    );

    timings['track (one directory entry)'] = await _time(
      () => _runOrThrow(
        driver,
        ['track', bigDir, '--kind', 'directory'],
        homeA,
        envA,
      ),
    );

    timings['push (cold, full sync)'] = await _time(
      () => _runOrThrow(driver, ['push'], homeA, envA),
    );

    final syncDirA = _syncDirectoryFor(homeA);
    await _runGit(['init', '-b', 'main'], syncDirA).catchError((_) async {
      // Already a repo from `dotweave init`; ignore.
    });
    await _runGit(['add', '-A'], syncDirA);
    await _runGit(['commit', '-m', 'cold sync'], syncDirA);

    final touched = _touchFraction(bigDir, _touchFractionValue);
    _log('${driver.label}: touched $touched files before incremental push');

    timings['push (incremental, ~3% changed)'] = await _time(
      () => _runOrThrow(driver, ['push'], homeA, envA),
    );

    await _runGit(['add', '-A'], syncDirA);
    await _runGit(['commit', '-m', 'incremental sync'], syncDirA);

    timings['status (clean, no changes)'] = await _time(
      () => _runOrThrow(driver, ['status'], homeA, envA),
    );

    final homeB = p.join(workDir.path, 'machine-b');
    Directory(homeB).createSync(recursive: true);
    final envB = _isolatedEnv(homeB);

    // Reuse machine A's identity via --key-file so machine B's clone never
    // prompts interactively (no secrets are tracked in this benchmark, so
    // the identity content itself is never actually exercised for decrypt).
    final identityFileA = _identityFileFor(homeA);
    timings['init (clone existing repo)'] = await _time(
      () => _runOrThrow(
        driver,
        ['init', syncDirA, '--key-file', identityFileA],
        homeB,
        envB,
      ),
    );

    timings['pull (materialize entire tree)'] = await _time(
      () => _runOrThrow(driver, ['pull', '-y'], homeB, envB),
    );
  } finally {
    try {
      await _deleteDirectoryWithRetry(workDir);
    } on FileSystemException {
      // Best-effort cleanup; leftover temp dirs don't affect results.
    }
  }

  return timings;
}

void _printTimingTable(Map<String, Duration> dartTimings) {
  final labels = dartTimings.keys.toList();
  final labelWidth = labels.fold<int>(
    'Operation'.length,
    (max, l) => l.length > max ? l.length : max,
  );

  String pad(String s, int width) => s.padRight(width);

  stdout.writeln();
  stdout.writeln('=== Performance (large-repo sync) ===');
  stdout.writeln('${pad('Operation', labelWidth)}  Dart (AOT)');
  stdout.writeln('-' * (labelWidth + 12));

  for (final label in labels) {
    final dart = dartTimings[label]!;
    stdout.writeln('${pad(label, labelWidth)}  ${_fmtMs(dart)}');
  }
}

/// Runs cold `push` at increasing file counts to reveal whether wall-clock
/// time scales linearly (constant per-file overhead) or super-linearly (an
/// O(n^2)-shaped algorithmic issue) with repo size.
Future<void> _runScalingProbe(CliDriver dartDriver) async {
  const sizes = [500, 1000, 2000, 4000, 8000];
  stdout.writeln();
  stdout.writeln('=== Cold push scaling probe (files vs. time) ===');
  stdout.writeln(
    '${'files'.padRight(8)}${'Dart ms'.padRight(12)}${'Dart ms/file'.padRight(14)}',
  );

  for (final size in sizes) {
    final fixtureRoot = p.join(
      (await Directory.systemTemp.createTemp('dotweave-scale-fixture-')).path,
      'source',
    );
    final previousDirCount = _dirCount;
    final previousFilesPerDir = _filesPerDir;
    final previousBigFileCount = _bigFileCount;
    _dirCount = 1;
    _filesPerDir = size;
    _bigFileCount = 0;
    _generateFixture(fixtureRoot);
    _dirCount = previousDirCount;
    _filesPerDir = previousFilesPerDir;
    _bigFileCount = previousBigFileCount;

    Future<Duration> coldPushFor(CliDriver driver) async {
      final workDir = await Directory.systemTemp.createTemp(
        'dotweave-scale-${driver.label}-',
      );
      try {
        final home = p.join(workDir.path, 'machine-a');
        Directory(home).createSync(recursive: true);
        final env = _isolatedEnv(home);
        final bigDir = p.join(home, 'big-project');
        await _copyDirectory(fixtureRoot, bigDir);
        await _runOrThrow(driver, ['init'], home, env);
        await _runOrThrow(
          driver,
          ['track', bigDir, '--kind', 'directory'],
          home,
          env,
        );
        // Must be awaited here (not `return _time(...)` directly): a
        // `finally` block runs as soon as control leaves the `try` block,
        // which happens the instant an unawaited Future is returned — not
        // when that Future resolves. Without this `await`, `workDir` gets
        // deleted out from under the still-running `push` process.
        final duration = await _time(
          () => _runOrThrow(driver, ['push'], home, env),
        );
        return duration;
      } finally {
        await _deleteDirectoryWithRetry(workDir);
      }
    }

    final dartTime = await coldPushFor(dartDriver);
    await _deleteDirectoryWithRetry(Directory(p.dirname(fixtureRoot)));

    stdout.writeln(
      '${size.toString().padRight(8)}'
      '${dartTime.inMilliseconds.toString().padRight(12)}'
      '${(dartTime.inMicroseconds / 1000 / size).toStringAsFixed(3).padRight(14)}',
    );
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--quick')) {
    _dirCount = 5;
    _filesPerDir = 20;
    _bigFileCount = 2;
    _log(
      'Quick mode: reduced fixture to ${_dirCount * _filesPerDir + _bigFileCount} files.',
    );
  }

  final packageRoot = findPackageRoot();

  _log('Package root: $packageRoot');

  _log('Building/locating Dart AOT binary...');
  final dartBinary = await ensureE2eBinary(
    force: args.contains('--force-dart-build'),
  );

  final dartDriver = CliDriver('dart', dartBinary);

  if (args.contains('--scaling')) {
    await _runScalingProbe(dartDriver);
    return;
  }

  final fixtureRoot = p.join(
    (await Directory.systemTemp.createTemp('dotweave-bench-fixture-')).path,
    'source',
  );
  _log('Generating large-repo fixture at $fixtureRoot ...');
  final fixture = _generateFixture(fixtureRoot);
  _log(
    'Fixture: ${fixture.fileCount} files, '
    '${_fmtBytes(fixture.totalBytes)} total.',
  );

  _log('Running Dart benchmark...');
  final dartTimings = await _benchmarkCli(dartDriver, fixtureRoot);

  await Directory(p.dirname(fixtureRoot)).delete(recursive: true);

  _printTimingTable(dartTimings);

  stdout.writeln();
  stdout.writeln('=== Binary size ===');
  final dartSize = File(dartBinary).lengthSync();
  stdout.writeln(
    'Dart AOT executable (self-contained, no runtime needed): '
    '${_fmtBytes(dartSize)}',
  );
  stdout.writeln();
  stdout.writeln(
    'Note: numbers are wall-clock, single-run-per-operation on this '
    'machine under current load; treat as directional, not certified.',
  );
}
