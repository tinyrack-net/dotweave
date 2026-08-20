// Dart port of `tests/symlink-cross-platform.e2e.test.ts`.
//
// `lstat(...).isSymbolicLink()` becomes a `FileSystemEntity.typeSync(...,
// followLinks: false)` link check, `readlink` becomes the ported
// `readLinkTarget` (which normalizes Windows reparse-point targets), and
// `await expect(lstat(path)).rejects.toThrow()` becomes a typeSync
// notFound check.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';

/// Mirror of the TS suite-local `GitTreeEntry`.
typedef GitTreeEntry = ({String mode, String path});

void main() {
  late SyncE2EContext ctx;

  setUp(() async {
    ctx = await createSyncE2EContext();
  });

  tearDown(() async {
    await ctx.cleanup();
  });

  // Parses `git ls-files -s` into { mode, path } entries.
  Future<List<GitTreeEntry>> gitTree(String repoDir) async {
    final ls = await ctx.runGit(['ls-files', '-s'], repoDir);

    return ls.stdout.trim().split('\n').where((line) => line.isNotEmpty).map((
      line,
    ) {
      final parts = line.split('\t');
      final meta = parts.isNotEmpty ? parts[0] : '';
      final path = parts.length > 1 ? parts[1] : '';
      final mode = meta.split(' ').first;

      return (mode: mode, path: path);
    }).toList();
  }

  ({String homeB, String xdgB, Map<String, String> env}) machineBEnv(
    String label,
  ) {
    final homeB = p.join(ctx.workspace, 'home-$label');
    final xdgB = p.join(ctx.workspace, 'xdg-$label');

    return (
      homeB: homeB,
      xdgB: xdgB,
      env: mergeEnvironment(ctx.baseEnv, {
        'APPDATA': xdgB,
        'HOME': homeB,
        'LOCALAPPDATA': p.join(ctx.workspace, 'lad-$label'),
        'USERPROFILE': homeB,
        'XDG_CONFIG_HOME': xdgB,
      }),
    );
  }

  /// Proves symlinks now round-trip across machines and operating systems by
  /// being stored as regular `.dotweave.symlink` metadata files (git-safe
  /// blobs) rather than physical filesystem symlinks/junctions. On pull each
  /// machine re-materializes a native OS link in its own HOME.
  group('symlink sync across machines (portable metadata-file format)', () {
    test('syncs a symlink-to-FILE as a regular metadata file, restored as a '
        'native link on a second machine', () async {
      final remote = p.join(ctx.workspace, 'remote-file.git');
      final keyFile = p.join(ctx.workspace, 'file.agekey');
      final ageKeys = await ctx.createAgeKeyPair();

      // Machine A: ~/.claude/note.md -> ../.agents/note.md
      final realFile = p.join(ctx.homeDir, '.agents', 'note.md');
      final link = p.join(ctx.homeDir, '.claude', 'note.md');

      await ctx.runGit(['init', '--bare', '-b', 'main', remote]);
      await ctx.writeIdentityFile(ageKeys.identity);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');
      await Directory(p.join(ctx.homeDir, '.agents')).create(recursive: true);
      await File(realFile).writeAsString('# real note (machine A)\n');
      await Directory(p.join(ctx.homeDir, '.claude')).create(recursive: true);
      await createSymlink(p.join('..', '.agents', 'note.md'), link);

      await ctx.runCli(['init', remote]);
      await ctx.runCli(['track', link]);
      await ctx.runCli(['push']);

      final repoDir = p.join(ctx.xdgDir, 'dotweave', 'repository');
      await ctx.runGit(['add', '.'], repoDir);
      await ctx.runGit(['commit', '-m', 'sync file symlink'], repoDir);
      await ctx.runGit(['push', '-u', 'origin', 'main'], repoDir);

      // Repo stores a REGULAR FILE with the .dotweave.symlink suffix (mode
      // 100644), not a git symlink blob (120000) or a physical link.
      final tree = await gitTree(repoDir);
      GitTreeEntry? artifact;

      for (final entry in tree) {
        if (entry.path.endsWith('.claude/note.md.dotweave.symlink')) {
          artifact = entry;
          break;
        }
      }

      expect(artifact?.mode, '100644');
      expect(tree.any((e) => e.mode == '120000'), false);

      final artifactFile = p.join(
        repoDir,
        'profiles',
        'default',
        '.claude',
        'note.md.dotweave.symlink',
      );
      expect(await File(artifactFile).readAsString(), '../.agents/note.md');

      // Machine B: different HOME, no core.symlinks needed.
      final machineB = machineBEnv('B1');
      final homeB = machineB.homeB;
      final envB = machineB.env;

      await Directory(p.join(homeB, '.agents')).create(recursive: true);
      await File(
        p.join(homeB, '.agents', 'note.md'),
      ).writeAsString('# real note (machine B)\n');

      await ctx.runCli(['init', remote, '--key-file', keyFile], env: envB);
      final pull = await ctx.runCli(['pull', '-y'], env: envB);
      expect(pull.exitCode, 0);

      final linkB = p.join(homeB, '.claude', 'note.md');
      expect(
        FileSystemEntity.typeSync(linkB, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(
        (await readLinkTarget(linkB)).replaceAll(r'\', '/'),
        contains('.agents/note.md'),
      );
      expect(await File(linkB).readAsString(), contains('machine B'));
    });

    test('syncs a symlink-to-DIRECTORY (~/.claude/skills -> ../.agents/skills) '
        'as a native link on a second machine', () async {
      final remote = p.join(ctx.workspace, 'remote-dir.git');
      final keyFile = p.join(ctx.workspace, 'dir.agekey');
      final ageKeys = await ctx.createAgeKeyPair();

      // Machine A
      final agentsSkills = p.join(ctx.homeDir, '.agents', 'skills');
      final claudeSkills = p.join(ctx.homeDir, '.claude', 'skills');

      await ctx.runGit(['init', '--bare', '-b', 'main', remote]);
      await ctx.writeIdentityFile(ageKeys.identity);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');
      await Directory(agentsSkills).create(recursive: true);
      await File(
        p.join(agentsSkills, 's.md'),
      ).writeAsString('skill (machine A)\n');
      await Directory(p.join(ctx.homeDir, '.claude')).create(recursive: true);
      await createSymlink(p.join('..', '.agents', 'skills'), claudeSkills);

      await ctx.runCli(['init', remote]);
      await ctx.runCli(['track', claudeSkills]);
      await ctx.runCli(['push']);

      final repoDir = p.join(ctx.xdgDir, 'dotweave', 'repository');
      await ctx.runGit(['add', '.'], repoDir);
      await ctx.runGit(['commit', '-m', 'sync dir symlink'], repoDir);
      await ctx.runGit(['push', '-u', 'origin', 'main'], repoDir);

      // The directory symlink is stored as a single regular metadata file
      // -- NOT a directory of copied contents (the old Windows junction
      // failure).
      final tree = await gitTree(repoDir);
      expect(
        tree.any((e) => e.path.endsWith('.claude/skills.dotweave.symlink')),
        true,
      );
      expect(tree.any((e) => e.path.contains('.claude/skills/')), false);

      // Machine B: different HOME.
      final machineB = machineBEnv('B2');
      final homeB = machineB.homeB;
      final envB = machineB.env;

      await Directory(
        p.join(homeB, '.agents', 'skills'),
      ).create(recursive: true);
      await File(
        p.join(homeB, '.agents', 'skills', 's.md'),
      ).writeAsString('skill (machine B)\n');

      await ctx.runCli(['init', remote, '--key-file', keyFile], env: envB);
      final pull = await ctx.runCli(['pull', '-y'], env: envB);
      expect(pull.exitCode, 0);

      // HOME gets a working native link (junction on Windows, symlink on
      // Unix) resolving to machine B's own target directory.
      final linkB = p.join(homeB, '.claude', 'skills');
      expect(
        FileSystemEntity.typeSync(linkB, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(
        await File(p.join(linkB, 's.md')).readAsString(),
        contains('machine B'),
      );

      // Second pull is a no-op.
      final secondPull = await ctx.runCli(['pull'], env: envB);
      expect(secondPull.stdout.contains('Already up to date'), true);
    });

    /// The failure this whole feature exists to fix: an ABSOLUTE target is
    /// machine- and user-specific, so before home-anchoring it pulled as a
    /// dangling link on every other machine.
    test('syncs a symlink whose target is an ABSOLUTE path inside HOME and '
        "resolves it against the second machine's own HOME", () async {
      final remote = p.join(ctx.workspace, 'remote-abs.git');
      final keyFile = p.join(ctx.workspace, 'abs.agekey');
      final ageKeys = await ctx.createAgeKeyPair();

      final realFile = p.join(ctx.homeDir, '.agents', 'AGENTS.md');
      final link = p.join(ctx.homeDir, '.claude', 'AGENTS.md');

      await ctx.runGit(['init', '--bare', '-b', 'main', remote]);
      await ctx.writeIdentityFile(ageKeys.identity);
      await File(keyFile).writeAsString('${ageKeys.identity}\n');
      await Directory(p.join(ctx.homeDir, '.agents')).create(recursive: true);
      await File(realFile).writeAsString('# agents (machine A)\n');
      await Directory(p.join(ctx.homeDir, '.claude')).create(recursive: true);
      // Absolute target, not relative -- this is the regression.
      await createSymlink(realFile, link);

      await ctx.runCli(['init', remote]);
      await ctx.runCli(['track', link]);
      await ctx.runCli(['push']);

      final repoDir = p.join(ctx.xdgDir, 'dotweave', 'repository');
      await ctx.runGit(['add', '.'], repoDir);
      await ctx.runGit(['commit', '-m', 'sync absolute symlink'], repoDir);
      await ctx.runGit(['push', '-u', 'origin', 'main'], repoDir);

      final artifactFile = p.join(
        repoDir,
        'profiles',
        'default',
        '.claude',
        'AGENTS.md${AppConstants.sync.symlinkArtifactSuffix}',
      );

      // Machine A's absolute HOME path never reaches the repository.
      expect(await File(artifactFile).readAsString(), '~/.agents/AGENTS.md');

      final tree = await gitTree(repoDir);
      GitTreeEntry? artifact;

      for (final entry in tree) {
        if (entry.path.endsWith('.claude/AGENTS.md.dotweave.symlink')) {
          artifact = entry;
          break;
        }
      }

      expect(artifact?.mode, '100644');
      expect(tree.any((e) => e.mode == '120000'), false);

      // Machine B: a different HOME entirely.
      final machineB = machineBEnv('B3');
      final homeB = machineB.homeB;
      final envB = machineB.env;

      await Directory(p.join(homeB, '.agents')).create(recursive: true);
      await File(
        p.join(homeB, '.agents', 'AGENTS.md'),
      ).writeAsString('# agents (machine B)\n');

      await ctx.runCli(['init', remote, '--key-file', keyFile], env: envB);
      final pull = await ctx.runCli(['pull', '-y'], env: envB);
      expect(pull.exitCode, 0);

      final linkB = p.join(homeB, '.claude', 'AGENTS.md');
      expect(
        FileSystemEntity.typeSync(linkB, followLinks: false),
        FileSystemEntityType.link,
      );

      // The `~` expanded against machine B's HOME, not machine A's...
      expect(
        (await readLinkTarget(linkB)).replaceAll(r'\', '/'),
        startsWith(homeB.replaceAll(r'\', '/')),
      );
      // ...and the link actually resolves instead of dangling.
      expect(await File(linkB).readAsString(), contains('machine B'));

      // The materialized link is recognized as current on the next pass; a
      // missing `~` expansion in the freshness check would rewrite it forever.
      final secondPull = await ctx.runCli(['pull'], env: envB);
      expect(secondPull.stdout.contains('Already up to date'), true);
    });

    test('warns on push when a symlink target points outside HOME', () async {
      final ageKeys = await ctx.createAgeKeyPair();
      final outsideTarget = p.join(ctx.workspace, 'outside', 'shared.md');
      final link = p.join(ctx.homeDir, '.claude', 'shared.md');

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(p.dirname(outsideTarget)).create(recursive: true);
      await File(outsideTarget).writeAsString('# shared\n');
      await Directory(p.join(ctx.homeDir, '.claude')).create(recursive: true);
      await createSymlink(outsideTarget, link);

      await ctx.runCli(['init']);
      await ctx.runCli(['track', link]);
      final push = await ctx.runCli(['push']);

      // logger.warn writes to stderr. The push itself still succeeds -- a
      // non-portable target is a warning, never a failure.
      expect(push.exitCode, 0);
      expect(push.stderr, contains('points outside your home directory'));
      expect(push.stderr, contains('.claude/shared.md'));
    });

    test('reads a legacy physical-symlink artifact and migrates it to the '
        'metadata-file format on push', () async {
      final realFile = p.join(ctx.homeDir, '.agents', 'note.md');
      final link = p.join(ctx.homeDir, '.claude', 'note.md');
      final ageKeys = await ctx.createAgeKeyPair();

      await ctx.writeIdentityFile(ageKeys.identity);
      await Directory(p.join(ctx.homeDir, '.agents')).create(recursive: true);
      await File(realFile).writeAsString('# note\n');
      await Directory(p.join(ctx.homeDir, '.claude')).create(recursive: true);
      await createSymlink(p.join('..', '.agents', 'note.md'), link);

      await ctx.runCli(['init']);
      await ctx.runCli(['track', link]);
      await ctx.runCli(['push']);

      final plainArtifact = p.join(
        ctx.xdgDir,
        'dotweave',
        'repository',
        'profiles',
        'default',
        '.claude',
        'note.md',
      );
      final metaArtifact =
          '$plainArtifact${AppConstants.sync.symlinkArtifactSuffix}';

      // Simulate an OLD repository: replace the metadata file with a
      // physical symlink at the plain path (the pre-.dotweave.symlink
      // format).
      await removePath(metaArtifact);
      await createSymlink(p.join('..', '.agents', 'note.md'), plainArtifact);

      // The legacy physical symlink is still readable: pull sees no drift.
      final pull = await ctx.runCli(['pull']);
      expect(pull.stdout.contains('Already up to date'), true);

      // Pushing migrates it to the portable metadata-file format and
      // removes the legacy physical symlink.
      await ctx.runCli(['push']);
      expect(
        FileSystemEntity.typeSync(metaArtifact, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(await File(metaArtifact).readAsString(), '../.agents/note.md');
      expect(
        FileSystemEntity.typeSync(plainArtifact, followLinks: false),
        FileSystemEntityType.notFound,
      );
    });
  });
}
