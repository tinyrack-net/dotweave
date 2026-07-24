import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/repo_format_migration.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/migrations/repo_format_v1.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late String repoDir;

  const emptyConfig = ResolvedSyncConfig(entries: [], profiles: [], version: 8);

  final suffix = AppConstants.sync.symlinkArtifactSuffix;

  setUp(() async {
    repoDir = (await Directory.systemTemp.createTemp(
      'dotweave-repo-format-',
    )).path;
  });

  tearDown(() async {
    await removePath(repoDir);
  });

  group('migrateRepositoryFormatV0ToV1', () {
    test('does nothing when there is no profiles directory', () async {
      await expectLater(
        migrateRepositoryFormatV0ToV1(repoDir, emptyConfig),
        completes,
      );
    });

    test('converts physical symlink artifacts (nested) to metadata files '
        'and is idempotent', () async {
      final profileDir = p.join(repoDir, 'profiles', 'default', '.config');
      await Directory(profileDir).create(recursive: true);

      // A regular file that must be left untouched.
      await File(p.join(profileDir, 'keep.txt')).writeAsString('keep\n');

      // A physical file symlink artifact.
      await createSymlink('../.agents/note.md', p.join(profileDir, 'note.md'));

      // A physical directory symlink artifact one level deeper.
      final nested = p.join(profileDir, 'nested');
      await Directory(nested).create(recursive: true);
      await createSymlink('../../.agents/skills', p.join(nested, 'skills'));

      await migrateRepositoryFormatV0ToV1(repoDir, emptyConfig);

      // Physical links are gone; metadata files carry the POSIX target.
      expect(await getPathStats(p.join(profileDir, 'note.md')), isNull);
      expect(
        await File(p.join(profileDir, 'note.md$suffix')).readAsString(),
        '../.agents/note.md',
      );

      expect(await getPathStats(p.join(nested, 'skills')), isNull);
      expect(
        await File(p.join(nested, 'skills$suffix')).readAsString(),
        '../../.agents/skills',
      );

      // Regular file preserved.
      expect(
        await File(p.join(profileDir, 'keep.txt')).readAsString(),
        'keep\n',
      );

      // Metadata files are regular files, not symlinks.
      expect(
        (await getPathStats(
          p.join(profileDir, 'note.md$suffix'),
        ))!.isSymbolicLink,
        isFalse,
      );

      // Idempotent: a second run makes no further changes and does not throw.
      await migrateRepositoryFormatV0ToV1(repoDir, emptyConfig);
      expect(
        await File(p.join(profileDir, 'note.md$suffix')).readAsString(),
        '../.agents/note.md',
      );
    });
  });
}
