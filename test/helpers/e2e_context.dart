// Dart port of `src/test/helpers/e2e-context.ts` (plus the
// process-spawning seam that replaces `cli-entry.ts` / `node-test-hooks.ts`).
//
// The TS helpers spawn `node --import <ts-resolve-hook> src/index.ts`; the
// Dart port spawns the AOT-compiled executable produced by
// `tool/build_e2e.dart`. The executable is resolved from the
// `DOTWEAVE_E2E_BIN` environment variable when set, otherwise from
// `.dart_tool/dotweave_e2e/dotweave(.exe)`, compiling it on demand (once per
// test run, memoized per isolate and serialized across isolates by the build
// lock file) when missing or stale.
//
// Environment isolation matches the TS `createSyncE2EContext` baseEnv: the
// temp workspace provides HOME / USERPROFILE / APPDATA / LOCALAPPDATA /
// XDG_CONFIG_HOME, colors are disabled (NO_COLOR=1, FORCE_COLOR=0), and git
// runs hermetically via `gitTestEnvironment`. `NODE_NO_WARNINGS` from the TS
// baseEnv is omitted (Node-only). Children are spawned with
// `includeParentEnvironment: false`, so a minimal pass-through set is
// forwarded from the parent environment: PATH plus SystemRoot / ComSpec /
// TEMP / TMP on Windows (Windows processes need SystemRoot), PATH / TERM on
// POSIX.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../tool/build_e2e.dart' as build_e2e;
import 'sync_fixture.dart' as fixture;

/// Result of spawning the compiled CLI (the subset of the execa result the TS
/// e2e suites assert on).
typedef CliRunResult = ({int exitCode, String stdout, String stderr});

/// Mirror of execa's rejection on a non-zero exit code (`reject: true`, the
/// TS default): thrown by [SyncE2EContext.runCli] and suite-local runners so
/// a failing intermediate CLI step fails the test with full output attached.
class CliRunException implements Exception {
  CliRunException(this.args, this.result);

  final List<String> args;
  final CliRunResult result;

  @override
  String toString() {
    return 'dotweave ${args.join(' ')} failed with exit code '
        '${result.exitCode}\n'
        'stdout:\n${result.stdout}\n'
        'stderr:\n${result.stderr}';
  }
}

/// The dotweave Dart package root (mirror of the TS `cliPackageRoot`).
String e2ePackageRoot() => _packageRoot ??= build_e2e.findPackageRoot();

String? _packageRoot;

Future<String>? _binaryFuture;

/// Resolves the compiled CLI executable: `DOTWEAVE_E2E_BIN` when set, else
/// `.dart_tool/dotweave_e2e/dotweave(.exe)`, compiling on demand when
/// missing/stale. Memoized so a test isolate compiles at most once per run.
Future<String> resolveE2eBinary() {
  return _binaryFuture ??= () async {
    final override = Platform.environment['DOTWEAVE_E2E_BIN'];

    if (override != null && override.isNotEmpty) {
      return override;
    }

    return build_e2e.ensureE2eBinary(packageRoot: e2ePackageRoot());
  }();
}

const List<String> _windowsPassThroughKeys = [
  'PATH',
  'SystemRoot',
  'ComSpec',
  'TEMP',
  'TMP',
];

const List<String> _posixPassThroughKeys = ['PATH', 'TERM'];

/// The minimal environment forwarded from the parent process (children are
/// spawned with `includeParentEnvironment: false`).
Map<String, String> passThroughEnvironment() {
  final keys = Platform.isWindows
      ? _windowsPassThroughKeys
      : _posixPassThroughKeys;
  final environment = <String, String>{};

  for (final key in keys) {
    // Platform.environment lookups are case-insensitive on Windows.
    final value = Platform.environment[key];

    if (value != null) {
      environment[key] = value;
    }
  }

  return environment;
}

/// Merges [overrides] over [base]. On Windows the merge is case-insensitive
/// on key names (mirroring how Node normalizes `process.env` writes), so an
/// override like `{'Path': ''}` replaces an existing `PATH` entry instead of
/// producing a duplicate variable in the child environment block.
Map<String, String> mergeEnvironment(
  Map<String, String> base,
  Map<String, String> overrides,
) {
  final merged = <String, String>{...base};

  for (final entry in overrides.entries) {
    if (Platform.isWindows) {
      final upperKey = entry.key.toUpperCase();

      merged.removeWhere(
        (key, _) => key != entry.key && key.toUpperCase() == upperKey,
      );
    }

    merged[entry.key] = entry.value;
  }

  return merged;
}

/// Spawns the compiled dotweave executable with an isolated environment
/// (pass-through set plus [env]) and returns its exit code and decoded
/// output. Never throws on a non-zero exit code; callers wanting execa-style
/// rejection wrap it (see [SyncE2EContext.runCli]).
Future<CliRunResult> runCompiledCli(
  List<String> args, {
  String? cwd,
  Map<String, String>? env,
  String? stdin,
}) async {
  final binary = await resolveE2eBinary();
  final environment = mergeEnvironment(
    passThroughEnvironment(),
    env ?? const {},
  );
  final process = await Process.start(
    binary,
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

/// Mirror of the TS `createMachineEnv`: a per-machine HOME/XDG/AppData set
/// layered over [baseEnv], for suites that simulate multiple machines inside
/// one workspace.
({
  Map<String, String> env,
  String homeDir,
  String localAppDataDir,
  String xdgDir,
})
createMachineEnv(String workspace, String name, Map<String, String> baseEnv) {
  final homeDir = p.join(workspace, 'home-$name');
  final xdgDir = p.join(workspace, 'xdg-$name');
  final localAppDataDir = p.join(workspace, 'local-appdata-$name');

  return (
    env: mergeEnvironment(baseEnv, {
      'APPDATA': xdgDir,
      'HOME': homeDir,
      'LOCALAPPDATA': localAppDataDir,
      'USERPROFILE': homeDir,
      'XDG_CONFIG_HOME': xdgDir,
    }),
    homeDir: homeDir,
    localAppDataDir: localAppDataDir,
    xdgDir: xdgDir,
  );
}

/// Mirror of the TS `readRepositoryArtifact`.
Future<String> readRepositoryArtifact(
  String xdgDir,
  String profile,
  String repoPath,
) {
  return File(
    p.joinAll([
      xdgDir,
      'dotweave',
      'repository',
      'profiles',
      profile,
      ...repoPath.split('/'),
    ]),
  ).readAsString();
}

/// Mirror of the TS `rm(workspace, { force: true, recursive: true })` with
/// the Windows retry for read-only git object files.
Future<void> removeE2eWorkspace(String directory) async {
  final target = Directory(directory);

  if (!await target.exists()) {
    return;
  }

  try {
    await target.delete(recursive: true);
  } on FileSystemException {
    if (!Platform.isWindows) {
      rethrow;
    }

    // Git object files are read-only on Windows; clear attributes and retry.
    await Process.run('cmd', [
      '/c',
      'rmdir',
      '/s',
      '/q',
      directory,
    ], runInShell: false);
  }
}

/// Mirror of the TS `SyncE2EContext` (the object returned by
/// `createSyncE2EContext`).
class SyncE2EContext {
  SyncE2EContext._({
    required this.workspace,
    required this.homeDir,
    required this.xdgDir,
    required this.localAppDataDir,
    required this.baseEnv,
  });

  final String workspace;
  final String homeDir;
  final String xdgDir;
  final String localAppDataDir;
  final Map<String, String> baseEnv;

  /// Mirror of the TS `ctx.runCli`: spawns the compiled CLI with [baseEnv]
  /// (plus [env] overrides merged on top). Like execa's default `reject:
  /// true`, throws [CliRunException] on a non-zero exit code unless [reject]
  /// is false.
  Future<CliRunResult> runCli(
    List<String> args, {
    String? cwd,
    Map<String, String>? env,
    String? stdin,
    bool reject = true,
  }) async {
    final result = await runCompiledCli(
      args,
      cwd: cwd,
      env: env == null ? baseEnv : mergeEnvironment(baseEnv, env),
      stdin: stdin,
    );

    if (reject && result.exitCode != 0) {
      throw CliRunException(args, result);
    }

    return result;
  }

  /// Mirror of the TS `ctx.runGit` (delegates to the sync-fixture helper).
  Future<({String stdout, String stderr})> runGit(
    List<String> args, [
    String? cwd,
  ]) {
    return fixture.runGit(args, cwd);
  }

  /// Mirror of the TS `ctx.createAgeKeyPair`.
  Future<({String identity, String recipient})> createAgeKeyPair() {
    return fixture.createAgeKeyPair();
  }

  /// Mirror of the TS `ctx.writeIdentityFile` (bound to this workspace's
  /// XDG config home).
  Future<String> writeIdentityFile(String identity) {
    return fixture.writeIdentityFile(xdgDir, identity);
  }

  /// Mirror of the TS `ctx.cleanup`.
  Future<void> cleanup() => removeE2eWorkspace(workspace);
}

/// Mirror of the TS `createSyncE2EContext`.
Future<SyncE2EContext> createSyncE2EContext() async {
  final workspace = await fixture.createTemporaryDirectory('dotweave-e2e-');
  final homeDir = p.join(workspace, 'home');
  final xdgDir = p.join(workspace, 'xdg');
  final localAppDataDir = p.join(workspace, 'local-appdata');

  await Directory(homeDir).create(recursive: true);

  final baseEnv = <String, String>{
    'APPDATA': xdgDir,
    'FORCE_COLOR': '0',
    'HOME': homeDir,
    'LOCALAPPDATA': localAppDataDir,
    'NO_COLOR': '1',
    'USERPROFILE': homeDir,
    'XDG_CONFIG_HOME': xdgDir,
    ...fixture.gitTestEnvironment,
  };

  return SyncE2EContext._(
    workspace: workspace,
    homeDir: homeDir,
    xdgDir: xdgDir,
    localAppDataDir: localAppDataDir,
    baseEnv: baseEnv,
  );
}
