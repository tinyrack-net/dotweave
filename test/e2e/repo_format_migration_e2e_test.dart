// Dart port of `tests/repo-format-migration.e2e.test.ts`.
//
// The TS `manifest.repositoryFormat = undefined; delete
// manifest.repositoryFormat;` downgrade becomes a plain map `remove`, and
// `await expect(lstat(plainArtifact)).rejects.toThrow()` becomes
// `expectPathAbsent` (the plain path must not exist, not even as a broken
// symlink).

@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

String _manifestPathOf(SyncE2EContext ctx) =>
    p.join(ctx.xdgDir, 'dotweave', 'repository', 'manifest.jsonc');

Future<Map<String, Object?>> _readManifest(SyncE2EContext ctx) async =>
    jsonDecode(await File(_manifestPathOf(ctx)).readAsString())
        as Map<String, Object?>;

Future<void> _writeManifest(SyncE2EContext ctx, Object? manifest) =>
    File(_manifestPathOf(ctx)).writeAsString('${jsonStringify(manifest)}\n');

void main() {
  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('repository format migration', () {
    test('migrates a legacy format-0 repository (physical symlink) on push '
        'and records the marker', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);

      final realFile = p.join(ctx.homeDir, '.agents', 'note.md');
      final link = p.join(ctx.homeDir, '.claude', 'note.md');
      await Directory(p.join(ctx.homeDir, '.agents')).create(recursive: true);
      await File(realFile).writeAsString('# note\n');
      await Directory(p.join(ctx.homeDir, '.claude')).create(recursive: true);
      await createSymlink(p.join('..', '.agents', 'note.md'), link);

      await ctx.runCli(['init']);
      await ctx.runCli(['track', link]);
      await ctx.runCli(['push']);

      final suffix = AppConstants.sync.symlinkArtifactSuffix;
      final plainArtifact = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.claude',
        'note.md',
      );

      // Downgrade to the legacy format 0: drop the marker and replace the
      // metadata file with a physical symlink at the plain path.
      final manifest = await _readManifest(ctx);
      manifest.remove('repositoryFormat');
      await _writeManifest(ctx, manifest);
      final marker = File('$plainArtifact$suffix');
      if (await marker.exists()) {
        await marker.delete();
      }
      await createSymlink(p.join('..', '.agents', 'note.md'), plainArtifact);

      // Push migrates: converts the physical symlink and records format 1.
      await ctx.runCli(['push']);

      expect(
        (await _readManifest(ctx))['repositoryFormat'],
        AppConstants.sync.repositoryFormat,
      );
      expectPathAbsent(plainArtifact);
      expect(
        await File('$plainArtifact$suffix').readAsString(),
        '../.agents/note.md',
      );

      // Idempotent: a second push keeps the marker and the metadata file.
      await ctx.runCli(['push']);
      expect(
        (await _readManifest(ctx))['repositoryFormat'],
        AppConstants.sync.repositoryFormat,
      );
      expect(
        await File('$plainArtifact$suffix').readAsString(),
        '../.agents/note.md',
      );
    });

    test('rewrites a format-1 absolute in-HOME symlink target to the '
        'home-anchored form on push', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);

      final realFile = p.join(ctx.homeDir, '.agents', 'AGENTS.md');
      final link = p.join(ctx.homeDir, '.claude', 'AGENTS.md');
      await Directory(p.join(ctx.homeDir, '.agents')).create(recursive: true);
      await File(realFile).writeAsString('# agents\n');
      await Directory(p.join(ctx.homeDir, '.claude')).create(recursive: true);
      await createSymlink(realFile, link);

      await ctx.runCli(['init']);
      await ctx.runCli(['track', link]);
      await ctx.runCli(['push']);

      final artifact = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.claude',
        'AGENTS.md${AppConstants.sync.symlinkArtifactSuffix}',
      );

      // Downgrade to format 1: an absolute target written by an older CLI.
      final absoluteTarget = realFile.replaceAll(r'\', '/');
      final manifest = await _readManifest(ctx);
      manifest['repositoryFormat'] = 1;
      await _writeManifest(ctx, manifest);
      await File(artifact).writeAsString(absoluteTarget);

      await ctx.runCli(['push']);

      expect(
        (await _readManifest(ctx))['repositoryFormat'],
        AppConstants.sync.repositoryFormat,
      );
      expect(await File(artifact).readAsString(), '~/.agents/AGENTS.md');

      // Idempotent: a second push leaves the anchored target alone.
      await ctx.runCli(['push']);
      expect(await File(artifact).readAsString(), '~/.agents/AGENTS.md');
    });

    test('refuses a repository whose format is newer than the CLI '
        'supports', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      await ctx.writeIdentityFile(ageKeys.identity);
      await ctx.runCli(['init']);

      final manifest = await _readManifest(ctx);
      manifest['repositoryFormat'] = 999;
      await _writeManifest(ctx, manifest);

      final result = await ctx.runCli(['status'], reject: false);
      expect(result.exitCode, isNot(0));
      expect(
        stripAnsi(result.stderr),
        contains('newer than this CLI supports'),
      );
    });
  });
}
