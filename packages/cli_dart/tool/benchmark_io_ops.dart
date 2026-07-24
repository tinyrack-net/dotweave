// Micro-benchmarks per-operation filesystem costs for the Dart CLI to guide
// the choice between async dart:io, sync dart:io, and isolate-pool
// strategies for FS-heavy code paths (stat/read/write/mkdir/rename/delete).
//
// Usage (from packages/cli_dart): dart run tool/benchmark_io_ops.dart
//
// This is a standalone diagnostic script, not part of the test suite: it
// builds a deterministic temp fixture (2,000 x 1 KB + 2,000 x 6 KB files in
// 20 subdirectories), times each operation variant (median of 3 passes after
// 1 warmup pass), prints one aligned table in microseconds per operation,
// and projects a 10k-file cold push under three execution strategies. If a
// `node` executable is on PATH, it also measures a small Node.js reference
// set over the same fixture. Numbers are machine- and load-dependent; treat
// them as a rough signal, not a certified benchmark.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

const int _dirCount = 20;
const int _filesPerSizePerDir = 100; // 20 * 100 = 2,000 files per size class
const int _smallBytes = 1024;
const int _largeBytes = 6 * 1024;
const int _isolatePoolSize = 4;
const int _asyncWidth = 20;

void _log(String message) => stdout.writeln('[bench] $message');

/// One measured table row.
class _Row {
  _Row(this.operation, this.variant, this.usPerOp);

  final String operation;
  final String variant;
  final double usPerOp;
}

final List<_Row> _rows = [];

double? _lookup(String operation, String variant) {
  for (final row in _rows) {
    if (row.operation == operation && row.variant == variant) {
      return row.usPerOp;
    }
  }
  return null;
}

/// Limits the number of concurrent asynchronous operations.
///
/// Copied (inlined, per benchmark convention of having no lib/ imports) from
/// `lib/src/lib/concurrency.dart`: a pool of at most [concurrency] workers
/// drains [items] in order and results keep the input index order.
Future<List<R>> _limitConcurrency<T, R>(
  int concurrency,
  List<T> items,
  Future<R> Function(T item, int index) mapper,
) async {
  final results = List<R?>.filled(items.length, null);
  var currentIndex = 0;

  Future<void> worker() async {
    while (currentIndex < items.length) {
      final index = currentIndex;
      currentIndex += 1;
      results[index] = await mapper(items[index], index);
    }
  }

  final workerCount = concurrency < items.length ? concurrency : items.length;
  await Future.wait([for (var i = 0; i < workerCount; i += 1) worker()]);

  return [for (final result in results) result as R];
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

/// Deterministic printable content for file [fileIndex] of [size] bytes.
List<int> _contentFor(int fileIndex, int size) =>
    List<int>.generate(size, (i) => 33 + ((fileIndex * 7 + i) % 90));

/// Splits [items] into at most [parts] contiguous chunks of near-equal size.
List<List<T>> _chunk<T>(List<T> items, int parts) {
  final chunks = <List<T>>[];
  final base = items.length ~/ parts;
  final remainder = items.length % parts;
  var offset = 0;
  for (var i = 0; i < parts && offset < items.length; i++) {
    final size = base + (i < remainder ? 1 : 0);
    chunks.add(items.sublist(offset, offset + size));
    offset += size;
  }
  return chunks;
}

/// Runs 1 warmup pass plus 3 timed passes of [run] and records the median
/// microseconds-per-operation as a table row. [setup]/[teardown] run outside
/// the timed region (used to create fresh victims for rename/delete/write).
Future<void> _bench(
  String operation,
  String variant,
  int ops,
  Future<void> Function(int pass) run, {
  Future<void> Function(int pass)? setup,
  Future<void> Function(int pass)? teardown,
}) async {
  final samples = <double>[];
  for (var pass = 0; pass < 4; pass++) {
    if (setup != null) await setup(pass);
    final stopwatch = Stopwatch()..start();
    await run(pass);
    stopwatch.stop();
    if (teardown != null) await teardown(pass);
    if (pass > 0) samples.add(stopwatch.elapsedMicroseconds / ops);
  }
  samples.sort();
  final median = samples[1];
  _rows.add(_Row(operation, variant, median));
  _log(
    '$operation | $variant: ${median.toStringAsFixed(1)} us/op '
    '(min ${samples.first.toStringAsFixed(1)}, '
    'max ${samples.last.toStringAsFixed(1)})',
  );
}

/// Generates the fixture: [_dirCount] subdirectories, each holding
/// [_filesPerSizePerDir] 1 KB files and the same number of 6 KB files,
/// all with deterministic content. Returns (smallFiles, largeFiles).
(List<String>, List<String>) _generateFixture(String root) {
  final small = <String>[];
  final large = <String>[];
  for (var d = 0; d < _dirCount; d++) {
    final dir = Directory(p.join(root, 'dir-${d.toString().padLeft(2, '0')}'))
      ..createSync(recursive: true);
    for (var f = 0; f < _filesPerSizePerDir; f++) {
      final index = d * _filesPerSizePerDir + f;
      final smallPath = p.join(
        dir.path,
        'f1k-${f.toString().padLeft(3, '0')}.dat',
      );
      File(smallPath).writeAsBytesSync(_contentFor(index, _smallBytes));
      small.add(smallPath);
      final largePath = p.join(
        dir.path,
        'f6k-${f.toString().padLeft(3, '0')}.dat',
      );
      File(largePath).writeAsBytesSync(_contentFor(index, _largeBytes));
      large.add(largePath);
    }
  }
  return (small, large);
}

Future<void> _isolateReadPool(List<String> paths) async {
  final chunks = _chunk(paths, _isolatePoolSize);
  await Future.wait<int>([
    for (final chunk in chunks)
      Isolate.run(() {
        var total = 0;
        for (final path in chunk) {
          total += File(path).readAsBytesSync().length;
        }
        return total;
      }),
  ]);
}

Future<void> _isolateWritePool(List<String> paths, List<int> bytes) async {
  final chunks = _chunk(paths, _isolatePoolSize);
  await Future.wait<int>([
    for (final chunk in chunks)
      Isolate.run(() {
        for (final path in chunk) {
          File(path).writeAsBytesSync(bytes);
        }
        return chunk.length;
      }),
  ]);
}

Future<void> _benchStats(String operation, List<String> paths) async {
  final n = paths.length;
  await _bench(operation, 'FileStat.stat (async, c=1)', n, (_) async {
    for (final path in paths) {
      await FileStat.stat(path);
    }
  });
  await _bench(operation, 'FileStat.stat (async, c=20)', n, (_) async {
    await _limitConcurrency<String, FileStat>(
      _asyncWidth,
      paths,
      (path, _) => FileStat.stat(path),
    );
  });
  await _bench(operation, 'FileSystemEntity.type (async, c=1)', n, (_) async {
    for (final path in paths) {
      await FileSystemEntity.type(path, followLinks: false);
    }
  });
  await _bench(operation, 'FileStat.statSync (c=1)', n, (_) async {
    for (final path in paths) {
      FileStat.statSync(path);
    }
  });
  await _bench(operation, 'FileSystemEntity.typeSync (c=1)', n, (_) async {
    for (final path in paths) {
      FileSystemEntity.typeSync(path, followLinks: false);
    }
  });
}

Future<void> _benchReads(String operation, List<String> paths) async {
  final n = paths.length;
  await _bench(operation, 'readAsBytes (async, c=1)', n, (_) async {
    for (final path in paths) {
      await File(path).readAsBytes();
    }
  });
  await _bench(operation, 'readAsBytes (async, c=20)', n, (_) async {
    await _limitConcurrency<String, List<int>>(
      _asyncWidth,
      paths,
      (path, _) => File(path).readAsBytes(),
    );
  });
  await _bench(operation, 'readAsBytesSync (c=1)', n, (_) async {
    for (final path in paths) {
      File(path).readAsBytesSync();
    }
  });
  await _bench(operation, 'Isolate.run pool (4, sync)', n, (_) async {
    await _isolateReadPool(paths);
  });
}

Future<void> _benchWrites(String operation, String scratchRoot) async {
  const n = _dirCount * _filesPerSizePerDir;
  final bytes = _contentFor(0, _smallBytes);
  var batch = 0;
  late List<String> targets;

  Future<void> setup(int pass) async {
    final dir = Directory(p.join(scratchRoot, 'w-$batch'));
    batch++;
    dir.createSync(recursive: true);
    targets = [for (var i = 0; i < n; i++) p.join(dir.path, 'new-$i.dat')];
  }

  Future<void> teardown(int pass) async {
    await _deleteDirectoryWithRetry(Directory(p.dirname(targets.first)));
  }

  await _bench(
    operation,
    'writeAsBytes (async, c=1)',
    n,
    (_) async {
      for (final path in targets) {
        await File(path).writeAsBytes(bytes);
      }
    },
    setup: setup,
    teardown: teardown,
  );
  await _bench(
    operation,
    'writeAsBytes (async, c=20)',
    n,
    (_) async {
      await _limitConcurrency<String, File>(
        _asyncWidth,
        targets,
        (path, _) => File(path).writeAsBytes(bytes),
      );
    },
    setup: setup,
    teardown: teardown,
  );
  await _bench(
    operation,
    'writeAsBytesSync (c=1)',
    n,
    (_) async {
      for (final path in targets) {
        File(path).writeAsBytesSync(bytes);
      }
    },
    setup: setup,
    teardown: teardown,
  );
  await _bench(
    operation,
    'Isolate.run pool (4, sync)',
    n,
    (_) async {
      await _isolateWritePool(targets, bytes);
    },
    setup: setup,
    teardown: teardown,
  );
}

Future<void> _benchMkdir(String scratchRoot) async {
  const n = _dirCount * _filesPerSizePerDir;

  // Already-existing target directories (created once, reused every pass:
  // create(recursive: true) on an existing directory is a no-op success).
  final existingBase = p.join(scratchRoot, 'mk-exist');
  final existing = <String>[
    for (var i = 0; i < n; i++) p.join(existingBase, 'd-$i'),
  ];
  for (final path in existing) {
    Directory(path).createSync(recursive: true);
  }

  await _bench('mkdir existing', 'Directory.create (async, c=1)', n, (_) async {
    for (final path in existing) {
      await Directory(path).create(recursive: true);
    }
  });
  await _bench('mkdir existing', 'Directory.create (async, c=20)', n, (
    _,
  ) async {
    await _limitConcurrency<String, Directory>(
      _asyncWidth,
      existing,
      (path, _) => Directory(path).create(recursive: true),
    );
  });
  await _bench('mkdir existing', 'Directory.createSync (c=1)', n, (_) async {
    for (final path in existing) {
      Directory(path).createSync(recursive: true);
    }
  });

  // Missing two-level targets: each op creates `a-<i>/b` where neither
  // level exists yet; a fresh base directory is used for every pass.
  var batch = 0;
  late List<String> missing;
  Future<void> setup(int pass) async {
    final base = Directory(p.join(scratchRoot, 'mk-miss-$batch'));
    batch++;
    base.createSync(recursive: true);
    missing = [for (var i = 0; i < n; i++) p.join(base.path, 'a-$i', 'b')];
  }

  Future<void> teardown(int pass) async {
    await _deleteDirectoryWithRetry(
      Directory(p.dirname(p.dirname(missing.first))),
    );
  }

  await _bench(
    'mkdir missing (2-level)',
    'Directory.create (async, c=1)',
    n,
    (_) async {
      for (final path in missing) {
        await Directory(path).create(recursive: true);
      }
    },
    setup: setup,
    teardown: teardown,
  );
  await _bench(
    'mkdir missing (2-level)',
    'Directory.createSync (c=1)',
    n,
    (_) async {
      for (final path in missing) {
        Directory(path).createSync(recursive: true);
      }
    },
    setup: setup,
    teardown: teardown,
  );
}

Future<void> _benchRenameAndDelete(String scratchRoot) async {
  const n = _dirCount * _filesPerSizePerDir;
  final bytes = _contentFor(0, _smallBytes);
  var batch = 0;
  late String dirPath;

  Future<void> setup(int pass) async {
    dirPath = p.join(scratchRoot, 'rd-$batch');
    batch++;
    Directory(dirPath).createSync(recursive: true);
    for (var i = 0; i < n; i++) {
      File(p.join(dirPath, 'v-$i.dat')).writeAsBytesSync(bytes);
    }
  }

  Future<void> teardown(int pass) async {
    await _deleteDirectoryWithRetry(Directory(dirPath));
  }

  await _bench(
    'rename (same dir)',
    'File.rename (async)',
    n,
    (_) async {
      for (var i = 0; i < n; i++) {
        await File(
          p.join(dirPath, 'v-$i.dat'),
        ).rename(p.join(dirPath, 'v-$i.moved'));
      }
    },
    setup: setup,
    teardown: teardown,
  );
  await _bench(
    'rename (same dir)',
    'File.renameSync',
    n,
    (_) async {
      for (var i = 0; i < n; i++) {
        File(
          p.join(dirPath, 'v-$i.dat'),
        ).renameSync(p.join(dirPath, 'v-$i.moved'));
      }
    },
    setup: setup,
    teardown: teardown,
  );
  await _bench(
    'delete',
    'File.delete (async)',
    n,
    (_) async {
      for (var i = 0; i < n; i++) {
        await File(p.join(dirPath, 'v-$i.dat')).delete();
      }
    },
    setup: setup,
    teardown: teardown,
  );
  await _bench(
    'delete',
    'File.deleteSync',
    n,
    (_) async {
      for (var i = 0; i < n; i++) {
        File(p.join(dirPath, 'v-$i.dat')).deleteSync();
      }
    },
    setup: setup,
    teardown: teardown,
  );
}

/// Node.js reference measurements over the same fixture. Embedded script
/// prints `NODE|<variant>|<usPerOp>` lines (median of 3 passes after 1
/// warmup, mirroring the Dart harness); skipped when `node` is not on PATH.
const String _nodeScript = r'''
const fs = require('fs');
const path = require('path');
const root = process.argv[1];
const oneK = [];
for (const d of fs.readdirSync(root)) {
  if (!d.startsWith('dir-')) continue;
  for (const f of fs.readdirSync(path.join(root, d))) {
    if (f.startsWith('f1k-')) oneK.push(path.join(root, d, f));
  }
}
oneK.sort();
async function pool(width, items, fn) {
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      await fn(items[i]);
    }
  }
  const workers = [];
  for (let i = 0; i < Math.min(width, items.length); i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
}
async function bench(name, ops, run) {
  const samples = [];
  for (let pass = 0; pass < 4; pass++) {
    const t0 = process.hrtime.bigint();
    await run(pass);
    const us = Number(process.hrtime.bigint() - t0) / 1000;
    if (pass > 0) samples.push(us / ops);
  }
  samples.sort((a, b) => a - b);
  console.log('NODE|' + name + '|' + samples[1].toFixed(2));
}
const buf = Buffer.alloc(1024, 97);
const writeDir = path.join(root, 'node-write');
fs.mkdirSync(writeDir, { recursive: true });
(async () => {
  await bench('fs.promises.lstat (c=20)', oneK.length,
    () => pool(20, oneK, (f) => fs.promises.lstat(f)));
  await bench('fs.promises.readFile (c=20, 1KB)', oneK.length,
    () => pool(20, oneK, (f) => fs.promises.readFile(f)));
  await bench('fs.promises.writeFile (c=20, 1KB)', oneK.length, (pass) => {
    const targets = oneK.map((_, i) =>
      path.join(writeDir, 'w-' + pass + '-' + i + '.dat'));
    return pool(20, targets, (f) => fs.promises.writeFile(f, buf));
  });
  await bench('fs.readFileSync (c=1, 1KB)', oneK.length, async () => {
    for (const f of oneK) fs.readFileSync(f);
  });
})().catch((e) => { console.error(e); process.exit(1); });
''';

Future<void> _benchNodeReference(String fixtureRoot) async {
  ProcessResult result;
  try {
    result = await Process.run(
      'node',
      ['-e', _nodeScript, fixtureRoot],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  } on ProcessException {
    _log('node not found on PATH; skipping Node reference measurements.');
    return;
  }
  if (result.exitCode != 0) {
    _log(
      'node reference script failed (exit ${result.exitCode}); skipping.\n'
      'stderr: ${result.stderr}',
    );
    return;
  }
  for (final line in (result.stdout as String).split(RegExp(r'\r?\n'))) {
    final parts = line.trim().split('|');
    if (parts.length != 3 || parts[0] != 'NODE') continue;
    final value = double.tryParse(parts[2]);
    if (value == null) continue;
    _rows.add(_Row('node reference', parts[1], value));
    _log('node reference | ${parts[1]}: ${parts[2]} us/op');
  }
}

void _printTable() {
  const opHeader = 'operation';
  const variantHeader = 'variant';
  const valueHeader = 'us/op';
  var opWidth = opHeader.length;
  var variantWidth = variantHeader.length;
  var valueWidth = valueHeader.length;
  for (final row in _rows) {
    if (row.operation.length > opWidth) opWidth = row.operation.length;
    if (row.variant.length > variantWidth) variantWidth = row.variant.length;
    final rendered = row.usPerOp.toStringAsFixed(1);
    if (rendered.length > valueWidth) valueWidth = rendered.length;
  }

  stdout.writeln();
  stdout.writeln('=== Per-operation cost (median of 3 passes, us/op) ===');
  stdout.writeln(
    '${opHeader.padRight(opWidth)} | ${variantHeader.padRight(variantWidth)} '
    '| ${valueHeader.padLeft(valueWidth)}',
  );
  stdout.writeln(
    '${'-' * opWidth}-+-${'-' * variantWidth}-+-${'-' * valueWidth}',
  );
  String? previousOp;
  for (final row in _rows) {
    final opCell = row.operation == previousOp ? '' : row.operation;
    previousOp = row.operation;
    stdout.writeln(
      '${opCell.padRight(opWidth)} | ${row.variant.padRight(variantWidth)} '
      '| ${row.usPerOp.toStringAsFixed(1).padLeft(valueWidth)}',
    );
  }
}

void _printProjection() {
  const files = 10000;

  final statAsync20 = _lookup('stat existing', 'FileStat.stat (async, c=20)');
  final missAsync20 = _lookup('stat missing', 'FileStat.stat (async, c=20)');
  final readAsync20 = _lookup('read 1KB', 'readAsBytes (async, c=20)');
  final mkdirAsync20 = _lookup(
    'mkdir existing',
    'Directory.create (async, c=20)',
  );
  final writeAsync20 = _lookup('write 1KB new', 'writeAsBytes (async, c=20)');

  final statSync = _lookup('stat existing', 'FileStat.statSync (c=1)');
  final missSync = _lookup('stat missing', 'FileStat.statSync (c=1)');
  final readSync = _lookup('read 1KB', 'readAsBytesSync (c=1)');
  final mkdirSync = _lookup('mkdir existing', 'Directory.createSync (c=1)');
  final writeSync = _lookup('write 1KB new', 'writeAsBytesSync (c=1)');

  final readIso = _lookup('read 1KB', 'Isolate.run pool (4, sync)');
  final writeIso = _lookup('write 1KB new', 'Isolate.run pool (4, sync)');

  if (statAsync20 == null ||
      missAsync20 == null ||
      readAsync20 == null ||
      mkdirAsync20 == null ||
      writeAsync20 == null ||
      statSync == null ||
      missSync == null ||
      readSync == null ||
      mkdirSync == null ||
      writeSync == null ||
      readIso == null ||
      writeIso == null) {
    stdout.writeln('Projection skipped: missing measurements.');
    return;
  }

  // Isolate-pool speedup factor observed on read+write, applied to the ops
  // (stat, mkdir, exists-check) that were not measured inside isolates.
  final isolateFactor = ((readIso / readSync) + (writeIso / writeSync)) / 2;

  final asyncPerFile =
      statAsync20 + readAsync20 + mkdirAsync20 + missAsync20 + writeAsync20;
  final syncPerFile = statSync + readSync + mkdirSync + missSync + writeSync;
  final isolatePerFile =
      statSync * isolateFactor +
      readIso +
      mkdirSync * isolateFactor +
      missSync * isolateFactor +
      writeIso;

  String seconds(double usPerFile) =>
      (files * usPerFile / 1e6).toStringAsFixed(2);

  stdout.writeln();
  stdout.writeln(
    '=== Projected 10k-file cold push '
    '(per file: 1 lstat + 1 read + 1 mkdir + 1 exists-check + 1 write) ===',
  );
  stdout.writeln(
    '(a) all-async, c=20:        '
    '${asyncPerFile.toStringAsFixed(1)} us/file -> '
    '${seconds(asyncPerFile)} s',
  );
  stdout.writeln(
    '(b) all-sync, sequential:   '
    '${syncPerFile.toStringAsFixed(1)} us/file -> '
    '${seconds(syncPerFile)} s',
  );
  stdout.writeln(
    '(c) sync in 4-isolate pool: '
    '${isolatePerFile.toStringAsFixed(1)} us/file -> '
    '${seconds(isolatePerFile)} s',
  );
  stdout.writeln(
    'Note: (c) uses measured isolate-pool numbers for read/write; stat, '
    'exists-check, and mkdir are scaled from their sync cost by the '
    'observed pool factor ${isolateFactor.toStringAsFixed(2)}x.',
  );
}

Future<void> main() async {
  final workDir = await Directory.systemTemp.createTemp('dotweave-io-ops-');
  final fixtureRoot = p.join(workDir.path, 'fixture');
  final scratchRoot = p.join(workDir.path, 'scratch');
  Directory(scratchRoot).createSync(recursive: true);

  try {
    _log('Generating fixture at $fixtureRoot ...');
    final (smallFiles, largeFiles) = _generateFixture(fixtureRoot);
    _log(
      'Fixture: ${smallFiles.length} x 1KB + ${largeFiles.length} x 6KB '
      'files across $_dirCount directories.',
    );

    final missingPaths = <String>[
      for (var i = 0; i < smallFiles.length; i++)
        p.join(
          fixtureRoot,
          'dir-${(i % _dirCount).toString().padLeft(2, '0')}',
          'missing-$i.dat',
        ),
    ];

    await _benchStats('stat existing', smallFiles);
    await _benchStats('stat missing', missingPaths);
    await _benchReads('read 1KB', smallFiles);
    await _benchReads('read 6KB', largeFiles);
    await _benchWrites('write 1KB new', scratchRoot);
    await _benchMkdir(scratchRoot);
    await _benchRenameAndDelete(scratchRoot);
    await _benchNodeReference(fixtureRoot);

    _printTable();
    _printProjection();

    stdout.writeln();
    stdout.writeln(
      'Note: numbers are wall-clock on this machine under current load; '
      'treat as directional, not certified.',
    );
  } finally {
    try {
      await _deleteDirectoryWithRetry(workDir);
    } on FileSystemException {
      // Best-effort cleanup; leftover temp dirs don't affect results.
    }
  }
}
