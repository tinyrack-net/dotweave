import 'dart:io';

import 'package:dotweave/src/services/skill_install.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-skill-install-',
    );

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  tearDown(() async {
    while (temporaryDirectories.isNotEmpty) {
      final directory = temporaryDirectories.removeLast();

      if (await Directory(directory).exists()) {
        await Directory(directory).delete(recursive: true);
      }
    }
  });

  group('skill install service', () {
    test(
      'installs the bundled dotweave skill in an existing skills root',
      () async {
        final workspace = await createWorkspace();
        final skillsRoot = p.join(workspace, 'skills');

        await Directory(skillsRoot).create();

        final result = await installDotweaveSkill(
          SkillInstallRequest(directory: skillsRoot),
        );

        expect(
          result,
          equals(
            SkillInstallResult(
              action: 'installed',
              dryRun: false,
              targetPath: p.join(skillsRoot, 'dotweave', 'SKILL.md'),
            ),
          ),
        );
        expect(await Directory(skillsRoot).exists(), isTrue);
        expect(
          await File(result.targetPath).readAsString(),
          contains('name: dotweave'),
        );
      },
    );

    test(
      'rejects a missing skills root without creating directories or files',
      () async {
        final workspace = await createWorkspace();
        final skillsRoot = p.join(workspace, 'skills');

        await expectLater(
          installDotweaveSkill(SkillInstallRequest(directory: skillsRoot)),
          throwsA(
            predicate(
              (error) =>
                  error.toString().contains('Skills root must be a directory'),
            ),
          ),
        );
        expect(
          await FileSystemEntity.type(skillsRoot),
          FileSystemEntityType.notFound,
        );
      },
    );

    test('rejects an existing install path unless force is provided', () async {
      final workspace = await createWorkspace();
      final skillsRoot = p.join(workspace, 'skills');
      final targetPath = p.join(skillsRoot, 'dotweave', 'SKILL.md');

      await Directory(p.join(skillsRoot, 'dotweave')).create(recursive: true);
      await File(targetPath).writeAsString('existing skill\n');

      await expectLater(
        installDotweaveSkill(SkillInstallRequest(directory: skillsRoot)),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('Dotweave skill already exists'),
          ),
        ),
      );
      expect(await File(targetPath).readAsString(), 'existing skill\n');
    });

    test(
      'overwrites an existing install path when force is provided',
      () async {
        final workspace = await createWorkspace();
        final skillsRoot = p.join(workspace, 'skills');
        final targetPath = p.join(skillsRoot, 'dotweave', 'SKILL.md');

        await Directory(p.join(skillsRoot, 'dotweave')).create(recursive: true);
        await File(targetPath).writeAsString('existing skill\n');

        final result = await installDotweaveSkill(
          SkillInstallRequest(directory: skillsRoot, force: true),
        );

        expect(result.action, 'overwritten');
        expect(
          await File(targetPath).readAsString(),
          contains('name: dotweave'),
        );
      },
    );

    test('rejects a skills root path that exists as a file', () async {
      final workspace = await createWorkspace();
      final skillsRoot = p.join(workspace, 'skills');

      await File(skillsRoot).writeAsString('not a directory\n');

      await expectLater(
        installDotweaveSkill(SkillInstallRequest(directory: skillsRoot)),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('Skills root must be a directory'),
          ),
        ),
      );
    });

    test('does not create directories or files during dry runs', () async {
      final workspace = await createWorkspace();
      final skillsRoot = p.join(workspace, 'skills');

      await Directory(skillsRoot).create();

      final result = await installDotweaveSkill(
        SkillInstallRequest(directory: skillsRoot, dryRun: true),
      );

      expect(
        result,
        equals(
          SkillInstallResult(
            action: 'would-install',
            dryRun: true,
            targetPath: p.join(skillsRoot, 'dotweave', 'SKILL.md'),
          ),
        ),
      );
      expect(
        await FileSystemEntity.type(p.join(skillsRoot, 'dotweave')),
        FileSystemEntityType.notFound,
      );
    });
  });
}
