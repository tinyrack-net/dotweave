import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/migrations/repo_format_v2.dart';
import 'package:dotweave/src/config/repo_format_migration.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late String repoDir;
  late String profilesDir;

  const emptyConfig = ResolvedSyncConfig(entries: [], profiles: [], version: 8);

  final suffix = AppConstants.sync.symlinkArtifactSuffix;

  /// A HOME that exists only as a string: the migration matches lexically and
  /// never touches the filesystem outside the repository.
  const fakeHome = '/tmp/dotweave-home';

  Future<String> writeArtifact(String relativePath, String contents) async {
    final path = p.joinAll([profilesDir, ...relativePath.split('/')]);
    await writeFileNode(path, (contents: contents, executable: false));
    return path;
  }

  setUp(() async {
    repoDir = (await Directory.systemTemp.createTemp(
      'dotweave-repo-format-v2-',
    )).path;
    profilesDir = p.join(repoDir, 'profiles', 'default');
    await Directory(profilesDir).create(recursive: true);
  });

  tearDown(() async {
    await removePath(repoDir);
  });

  group('migrateRepositoryFormatV1ToV2', () {
    test('does nothing when there is no profiles directory', () async {
      final bareRepo = (await Directory.systemTemp.createTemp(
        'dotweave-repo-format-v2-bare-',
      )).path;

      try {
        await expectLater(
          migrateRepositoryFormatV1ToV2(bareRepo, emptyConfig),
          completes,
        );
      } finally {
        await removePath(bareRepo);
      }
    });
  });

  group('rewriteSymlinkArtifactTargets', () {
    test('anchors nested in-HOME absolute targets and is idempotent', () async {
      final note = await writeArtifact(
        '.config/note.md$suffix',
        '$fakeHome/.agents/note.md',
      );
      final skills = await writeArtifact(
        '.config/nested/skills$suffix',
        '$fakeHome/.agents/skills',
      );
      final keep = await writeArtifact('.config/keep.txt', 'keep\n');

      await rewriteSymlinkArtifactTargets(profilesDir, fakeHome);

      expect(await File(note).readAsString(), '~/.agents/note.md');
      expect(await File(skills).readAsString(), '~/.agents/skills');
      expect(await File(keep).readAsString(), 'keep\n');

      final firstModified = await File(note).lastModified();

      await rewriteSymlinkArtifactTargets(profilesDir, fakeHome);

      expect(await File(note).readAsString(), '~/.agents/note.md');
      expect(
        await File(note).lastModified(),
        firstModified,
        reason: 'an already-portable artifact must not be rewritten',
      );
    });

    test('leaves relative targets unchanged', () async {
      final note = await writeArtifact('note.md$suffix', '../.agents/note.md');

      await rewriteSymlinkArtifactTargets(profilesDir, fakeHome);

      expect(await File(note).readAsString(), '../.agents/note.md');
    });

    test('leaves absolute targets outside HOME unchanged', () async {
      final tool = await writeArtifact('tool$suffix', '/opt/homebrew/bin/tool');

      await rewriteSymlinkArtifactTargets(profilesDir, fakeHome);

      expect(await File(tool).readAsString(), '/opt/homebrew/bin/tool');
    });

    test('ignores files without the symlink artifact suffix', () async {
      final plain = await writeArtifact(
        'config.json',
        '$fakeHome/.agents/note.md',
      );

      await rewriteSymlinkArtifactTargets(profilesDir, fakeHome);

      expect(await File(plain).readAsString(), '$fakeHome/.agents/note.md');
    });

    test('skips a physical symlink left by a partial format-0 repo', () async {
      final linkPath = p.join(profilesDir, 'legacy.md');
      await createSymlink('$fakeHome/.agents/legacy.md', linkPath);

      await rewriteSymlinkArtifactTargets(profilesDir, fakeHome);

      expect((await getPathStats(linkPath))!.isSymbolicLink, isTrue);
      expect(
        toPosixLinkTarget(await readLinkTarget(linkPath)),
        '$fakeHome/.agents/legacy.md',
      );
    });
  });
}
