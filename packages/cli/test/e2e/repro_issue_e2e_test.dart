// Dart port of `packages/cli/tests/repro-issue.e2e.test.ts`.
//
// The TS suite is wrapped in `describe.runIf(process.platform === "win32")`;
// the Dart port guards each test with `if (!Platform.isWindows) return;`.

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

  group('issue always updating directory (Windows case sensitivity)', () {
    test('should not show pull changes when child directory physical casing '
        'differs on Windows', () async {
      if (!Platform.isWindows) {
        return;
      }

      final parentDir = p.join(ctx.homeDir, 'parent');
      final childDir = p.join(parentDir, 'SKILLS'); // Physical: SKILLS
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(childDir).create(recursive: true);
      await File(p.join(childDir, 'test.txt')).writeAsString('hello\n');

      await ctx.runCli(['init']);

      // Track the PARENT directory
      await ctx.runCli(['track', parentDir]);

      // Push
      await ctx.runCli(['push']);

      // Manually lowercase the repo artifacts to simulate mismatch
      final manifestPath = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );
      var manifestContent = await File(manifestPath).readAsString();
      manifestContent = manifestContent.replaceAll('SKILLS', 'skills');
      await File(manifestPath).writeAsString(manifestContent);

      final repoChildDir = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'parent',
        'SKILLS',
      );
      final repoChildDirLower = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'parent',
        'skills',
      );
      await Directory(repoChildDir).rename(repoChildDirLower);

      // First pull - with the fix, it should say "Already up to date"
      // because it's case-insensitive
      final firstPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(firstPull.stdout), contains('Already up to date'));

      // Second pull - should definitely still be "Already up to date"
      final secondPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(secondPull.stdout), contains('Already up to date'));
    });

    test('should not show pull changes when top-level tracked directory repo '
        'casing differs on Windows', () async {
      if (!Platform.isWindows) {
        return;
      }

      final skillsDir = p.join(ctx.homeDir, 'SKILLS'); // Physical: SKILLS
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(skillsDir).create(recursive: true);
      await File(p.join(skillsDir, 'test.txt')).writeAsString('hello\n');

      await ctx.runCli(['init']);

      // Track the SKILLS directory - repo path will be "SKILLS"
      await ctx.runCli(['track', skillsDir]);

      // Push
      await ctx.runCli(['push']);

      // Manually lowercase the repo artifacts to simulate mismatch from
      // case-sensitive system
      final manifestPath = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'manifest.jsonc',
      );
      var manifestContent = await File(manifestPath).readAsString();
      manifestContent = manifestContent.replaceAll('SKILLS', 'skills');
      await File(manifestPath).writeAsString(manifestContent);

      final repoSkillsDir = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'SKILLS',
      );
      final repoSkillsDirLower = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'skills',
      );
      await Directory(repoSkillsDir).rename(repoSkillsDirLower);

      // First pull - should say "Already up to date" because it's
      // case-insensitive
      final firstPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(firstPull.stdout), contains('Already up to date'));

      // Second pull - should definitely still be "Already up to date"
      final secondPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(secondPull.stdout), contains('Already up to date'));
    });

    test('should not show pull changes when symlink target casing differs '
        'on Windows', () async {
      if (!Platform.isWindows) {
        return;
      }

      final targetDir = p.join(ctx.homeDir, 'TARGET'); // Physical: TARGET
      final linkPath = p.join(ctx.homeDir, 'link');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(targetDir).create(recursive: true);

      // Create symlink (junction) to TARGET
      await createSymlink(targetDir, linkPath, SymlinkType.junction);

      await ctx.runCli(['init']);
      await ctx.runCli(['track', linkPath]);
      await ctx.runCli(['push']);

      // Manually lowercase the link target in the repo artifact. Symlinks are
      // stored as regular metadata files whose contents are the POSIX target.
      final repoLinkArtifact = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        'link${AppConstants.sync.symlinkArtifactSuffix}',
      );
      final targetDirLower = p.join(ctx.homeDir, 'target');
      await File(
        repoLinkArtifact,
      ).writeAsString(targetDirLower.replaceAll('\\', '/'));

      // First pull - with the fix, it should say "Already up to date"
      // because it's case-insensitive
      final firstPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(firstPull.stdout), contains('Already up to date'));

      // Second pull
      final secondPull = await ctx.runCli(['pull', '-y']);
      expect(stripAnsi(secondPull.stdout), contains('Already up to date'));
    });
  });
}
