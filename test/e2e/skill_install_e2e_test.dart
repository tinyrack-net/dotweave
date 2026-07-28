// Dart port of `tests/skill-install.e2e.test.ts`.
//
// `await expect(readFile(...)).rejects.toThrow()` becomes
// `expectLater(File(...).readAsString(), throwsA(isA<FileSystemException>()))`
// (the target file must not exist).

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

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

  group('skill install CLI e2e', () {
    test('installs, dry-runs, rejects existing installs, and overwrites with '
        '--force', () async {
      final skillsRoot = p.join(ctx.workspace, 'skills');
      final targetPath = p.join(skillsRoot, 'dotweave', 'SKILL.md');

      await Directory(skillsRoot).create(recursive: true);

      final dryRun = await ctx.runCli([
        'skill',
        'install',
        skillsRoot,
        '--dry-run',
      ]);
      expect(
        stripAnsi(dryRun.stdout),
        contains('Would install dotweave skill'),
      );
      await expectLater(
        File(targetPath).readAsString(),
        throwsA(isA<FileSystemException>()),
      );

      final install = await ctx.runCli(['skill', 'install', skillsRoot]);
      expect(stripAnsi(install.stdout), contains('Installed dotweave skill'));
      expect(await File(targetPath).readAsString(), contains('name: dotweave'));

      final existing = await ctx.runCli([
        'skill',
        'install',
        skillsRoot,
      ], reject: false);
      expect(existing.exitCode, isNot(0));
      expect(
        stripAnsi(existing.stderr),
        contains('Dotweave skill already exists'),
      );

      await File(targetPath).writeAsString('local override\n');
      final dryOverwrite = await ctx.runCli([
        'skill',
        'install',
        skillsRoot,
        '--dry-run',
        '--force',
      ]);
      expect(
        stripAnsi(dryOverwrite.stdout),
        contains('Would overwrite dotweave skill'),
      );
      expect(await File(targetPath).readAsString(), 'local override\n');

      final overwrite = await ctx.runCli([
        'skill',
        'install',
        skillsRoot,
        '--force',
      ]);
      expect(stripAnsi(overwrite.stdout), contains('Overwrote dotweave skill'));
      expect(await File(targetPath).readAsString(), contains('name: dotweave'));
    });

    test('rejects a missing skills root without creating it', () async {
      final skillsRoot = p.join(ctx.workspace, 'missing-skills');
      final result = await ctx.runCli([
        'skill',
        'install',
        skillsRoot,
      ], reject: false);

      expect(result.exitCode, isNot(0));
      expect(
        stripAnsi(result.stderr),
        contains('Skills root must be a directory'),
      );
      await expectLater(
        File(p.join(skillsRoot, 'dotweave', 'SKILL.md')).readAsString(),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
