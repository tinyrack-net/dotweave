// Dart port of `tests/windows-junctions.e2e.test.ts`.
//
// Node's `fs.symlink(target, path, "junction")` becomes the ported
// `createSymlink(target, path, SymlinkType.junction)`, `rm(..., { force:
// true, recursive: true })` becomes `removePath`, and `lstat(...)
// .isSymbolicLink()` becomes a `FileSystemEntity.typeSync(..., followLinks:
// false)` link check. `it.skipIf(process.platform !== "win32")` becomes an
// early return on non-Windows platforms.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';
import '../helpers/sync_fixture.dart';

void main() {
  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  group('Windows junction and symlink target normalization', () {
    test('should not show pull changes when a tracked directory is a junction '
        'on Windows', () async {
      if (!Platform.isWindows) return;

      final realDir = p.join(ctx.homeDir, 'real_dir');
      final syncTarget = p.join(ctx.homeDir, 'junction_target');
      final targetFile = p.join(realDir, 'file.txt');

      await Directory(realDir).create(recursive: true);
      await File(targetFile).writeAsString('content');

      // 1. Initialize and track the path as a directory
      await ctx.runCli(['init']);
      // Create as real directory first to track it
      await Directory(syncTarget).create(recursive: true);
      await File(p.join(syncTarget, 'placeholder.txt')).writeAsString('data');
      await ctx.runCli(['track', syncTarget]);
      await ctx.runCli(['push']);

      // 2. Replace with a junction
      await removePath(syncTarget);
      await createSymlink(realDir, syncTarget, SymlinkType.junction);

      // 3. Pull - should follow the junction and update internal files, but
      // NOT replace the junction itself
      final firstPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(firstPull.stdout), contains('Update from repository'));

      // Verify it's still a junction (symlink on Node)
      expect(
        FileSystemEntity.typeSync(syncTarget, followLinks: false),
        FileSystemEntityType.link,
      );

      // 4. Second pull - should be already up to date
      final secondPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(secondPull.stdout), contains('Already up to date'));
    });

    test(
      'should normalize relative and absolute symlink targets on Windows',
      () async {
        if (!Platform.isWindows) return;

        final targetDir = p.join(ctx.homeDir, 'link_target_dir');
        final linkPath = p.join(ctx.homeDir, 'link_entry');

        await Directory(targetDir).create(recursive: true);
        await File(p.join(targetDir, 'file.txt')).writeAsString('content');

        await ctx.runCli(['init']);

        // 1. Create a local junction (absolute) and push it
        await createSymlink(targetDir, linkPath, SymlinkType.junction);
        await ctx.runCli(['track', linkPath]);
        await ctx.runCli(['push']);

        // 2. Manually modify the repo artifact to store a RELATIVE target
        // (simulating a push from Linux/Mac). Symlinks are stored as regular
        // metadata files whose contents are the POSIX-normalized target.
        final repoLinkArtifact = p.join(
          ctx.xdgDir,
          'dotweave',
          'repository',
          'profiles',
          'default',
          'link_entry${AppConstants.sync.symlinkArtifactSuffix}',
        );
        final relativeTarget = p.relative(targetDir, from: p.dirname(linkPath));

        await File(
          repoLinkArtifact,
        ).writeAsString(relativeTarget.replaceAll(r'\', '/'));

        // 3. Pull - should match the absolute local junction with the
        // relative repo target and report "Already up to date" because they
        // point to the same location.
        final pullResult = await ctx.runCli(['pull', '-y']);
        expect(stripAnsi(pullResult.stdout), contains('Already up to date'));
      },
    );
  });
}
