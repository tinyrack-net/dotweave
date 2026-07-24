// Helpers for the TS ↔ Dart cross-CLI compatibility suite (tag: `compat`).
//
// `runTsCli` spawns the TypeScript CLI (`node packages/cli/dist/index.js`)
// with the same environment-isolation contract as `runCompiledCli`:
// `includeParentEnvironment: false`, the minimal pass-through set, and
// `NODE_NO_WARNINGS=1` (the TS e2e baseEnv equivalent for a Node child).
//
// The dist bundle is built at most once per test run via
// `pnpm --filter @tinyrack/dotweave run build` when `dist/index.js` is
// missing or older than every file under `packages/cli/src`; concurrent test
// isolates are serialized through a lock file, mirroring the e2e binary
// build in `tool/build_e2e.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../helpers/e2e_context.dart';

/// The monorepo root (`packages/cli_dart` sits two levels below it).
String repoRoot() => p.dirname(p.dirname(e2ePackageRoot()));

/// The built TS CLI entry point.
String tsCliEntry() =>
    p.join(repoRoot(), 'packages', 'cli', 'dist', 'index.js');

Future<String>? _tsCliFuture;

/// Ensures `packages/cli/dist/index.js` exists and is newer than every
/// source file under `packages/cli/src`, building it through pnpm otherwise.
/// Memoized per isolate; cross-isolate builds serialize on a lock file.
Future<String> ensureTsCli() => _tsCliFuture ??= _ensureTsCliBuilt();

DateTime? _newestSourceModification(String sourceDirectory) {
  final directory = Directory(sourceDirectory);

  if (!directory.existsSync()) {
    return null;
  }

  DateTime? newest;

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

  return newest;
}

bool _isTsCliUpToDate(String entryPath) {
  final entry = File(entryPath);

  if (!entry.existsSync()) {
    return false;
  }

  final newestSource = _newestSourceModification(
    p.join(repoRoot(), 'packages', 'cli', 'src'),
  );

  if (newestSource == null) {
    return true;
  }

  return entry.statSync().modified.isAfter(newestSource);
}

Future<String> _ensureTsCliBuilt() async {
  final entryPath = tsCliEntry();
  final lockDirectory = Directory(
    p.join(e2ePackageRoot(), '.dart_tool', 'dotweave_compat'),
  );

  await lockDirectory.create(recursive: true);

  final lockHandle = await File(
    p.join(lockDirectory.path, 'ts_build.lock'),
  ).open(mode: FileMode.write);

  await lockHandle.lock(FileLock.blockingExclusive);

  try {
    if (_isTsCliUpToDate(entryPath)) {
      return entryPath;
    }

    // On Windows pnpm is a `pnpm.cmd` shim, and batch files can only be
    // spawned through a shell.
    final result = await Process.run(
      'pnpm',
      ['--filter', '@tinyrack/dotweave', 'run', 'build'],
      workingDirectory: repoRoot(),
      runInShell: Platform.isWindows,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode != 0 || !File(entryPath).existsSync()) {
      throw StateError(
        'pnpm --filter @tinyrack/dotweave run build failed with exit code '
        '${result.exitCode}\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}',
      );
    }

    return entryPath;
  } finally {
    await lockHandle.unlock();
    await lockHandle.close();
  }
}

/// Spawns the TS CLI with the same env-isolation contract as
/// [runCompiledCli] plus `NODE_NO_WARNINGS=1`. Like execa's default
/// `reject: true`, throws [CliRunException] on a non-zero exit code unless
/// [reject] is false.
Future<CliRunResult> runTsCli(
  List<String> args, {
  String? cwd,
  Map<String, String>? env,
  String? stdin,
  bool reject = true,
}) async {
  final entryPath = await ensureTsCli();
  final result = await _runNode(
    [entryPath, ...args],
    cwd: cwd,
    env: env,
    stdin: stdin,
  );

  if (reject && result.exitCode != 0) {
    throw CliRunException(['<ts>', ...args], result);
  }

  return result;
}

/// Decrypts an armored age ciphertext with the TypeScript `age-encryption`
/// package (through the interop harness script), returning the plaintext
/// bytes. Used to prove TS can read Dart-encrypted secret artifacts.
Future<List<int>> tsAgeDecrypt(String identity, String armored) async {
  final script = p.join(
    e2ePackageRoot(),
    'test',
    'crypto',
    'age',
    'interop',
    'age_interop.mjs',
  );
  final result = await _runNode([script, 'decrypt', identity], stdin: armored);

  if (result.exitCode != 0) {
    throw StateError(
      'TS age decrypt failed with exit code ${result.exitCode}\n'
      'stderr:\n${result.stderr}',
    );
  }

  return base64Decode(result.stdout.trim());
}

Future<CliRunResult> _runNode(
  List<String> args, {
  String? cwd,
  Map<String, String>? env,
  String? stdin,
}) async {
  final environment = mergeEnvironment(
    mergeEnvironment(passThroughEnvironment(), const {'NODE_NO_WARNINGS': '1'}),
    env ?? const {},
  );
  final process = await Process.start(
    'node',
    args,
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: false,
  );

  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();

  // The process may exit without reading stdin; swallow the broken-pipe
  // error instead of surfacing it as an unhandled async exception.
  unawaited(process.stdin.done.then((_) {}, onError: (Object _) {}));

  try {
    if (stdin != null) {
      process.stdin.write(stdin);
    }

    await process.stdin.close();
  } on IOException {
    // Ignore: stdin pipe already closed by the child.
  }

  final output = await Future.wait([stdoutFuture, stderrFuture]);
  final exitCode = await process.exitCode;

  return (exitCode: exitCode, stdout: output[0], stderr: output[1]);
}
