// Dart port of `tests/bin-entry.e2e.test.ts`.
//
// Adaptation: the TS suite exercises the published Node bin shim by spawning
// `node bin/index.js`; the Dart CLI ships a native executable instead, so
// this port spawns the AOT-compiled binary produced by `tool/build_e2e.dart`
// (the same artifact end users run). Test names say "the compiled binary"
// where the TS names said "bin/index.js"; assertions are otherwise verbatim
// (`toMatchObject` becomes per-key `containsPair` subset checks).

@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/util/version.g.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

typedef _BinEntryContext = ({
  Map<String, String> baseEnv,
  String homeDir,
  String workspace,
  String xdgDir,
});

Future<_BinEntryContext> _createBinEntryContext() async {
  final workspace = await createTemporaryDirectory('dotweave-bin-');
  final homeDir = p.join(workspace, 'home');
  final xdgDir = p.join(workspace, 'xdg');
  final localAppDataDir = p.join(workspace, 'local-appdata');

  await Directory(homeDir).create(recursive: true);

  return (
    baseEnv: <String, String>{
      'APPDATA': xdgDir,
      'FORCE_COLOR': '0',
      'HOME': homeDir,
      'LOCALAPPDATA': localAppDataDir,
      'NO_COLOR': '1',
      'USERPROFILE': homeDir,
      'XDG_CONFIG_HOME': xdgDir,
      ...gitTestEnvironment,
    },
    homeDir: homeDir,
    workspace: workspace,
    xdgDir: xdgDir,
  );
}

Future<CliRunResult> _runBin(
  List<String> args, {
  Map<String, String>? env,
  bool reject = true,
}) async {
  final result = await runCompiledCli(args, cwd: e2ePackageRoot(), env: env);

  if (reject && result.exitCode != 0) {
    throw CliRunException(args, result);
  }

  return result;
}

void main() {
  group('built bin entrypoint e2e', () {
    late _BinEntryContext ctx;

    setUp(() async {
      ctx = await _createBinEntryContext();
    });

    tearDown(() async {
      await removeE2eWorkspace(ctx.workspace);
    });

    test('shows the package version through the compiled binary', () async {
      final result = await _runBin(['--version'], env: ctx.baseEnv);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('dotweave/$packageVersion'));
      expect(result.stderr, '');
    });

    test('shows root help through the compiled binary', () async {
      final result = await _runBin(['--help'], env: ctx.baseEnv);

      expect(result.exitCode, 0);
      expect(result.stderr, '');

      final out = stripAnsi(result.stdout);
      expect(out, contains('USAGE'));
      expect(out, contains('init'));
      expect(out, contains('track'));
      expect(out, contains('push'));
      expect(out, contains('pull'));
      expect(out, contains('status'));
      expect(out, contains('doctor'));
      expect(out, contains('profile'));
    });

    test('runs a minimal init flow through the compiled binary', () async {
      final result = await _runBin(['init'], env: ctx.baseEnv);

      expect(result.exitCode, 0);
      expect(stripAnsi(result.stdout), contains('Sync directory initialized'));

      final settings =
          jsonDecode(
                await File(
                  p.join(ctx.xdgDir, 'dotweave', 'settings.jsonc'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      expect(settings, containsPair('activeProfile', 'default'));
      expect(settings, containsPair('version', 3));

      final manifest =
          jsonDecode(
                await File(
                  p.join(
                    ctx.xdgDir,
                    'dotweave',
                    'repository',
                    'manifest.jsonc',
                  ),
                ).readAsString(),
              )
              as Map<String, Object?>;
      expect(manifest, containsPair('entries', isEmpty));
      expect(manifest, containsPair('version', 8));
    });
  });
}
