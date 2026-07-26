import 'dart:io';

import 'package:dotweave/src/assets/dotweave_skill.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/filesystem.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/skill-install.ts`: installation of the bundled dotweave
// skill into a skills root directory.

/// Mirror of the TS `SkillInstallAction` union:
/// `installed` | `overwritten` | `would-install` | `would-overwrite`.
typedef SkillInstallAction = String;

/// Mirror of the TS `SkillInstallRequest` readonly object.
class SkillInstallRequest {
  const SkillInstallRequest({required this.directory, this.dryRun, this.force});

  final String directory;
  final bool? dryRun;
  final bool? force;
}

/// Mirror of the TS `SkillInstallResult` readonly object.
class SkillInstallResult {
  const SkillInstallResult({
    required this.action,
    required this.dryRun,
    required this.targetPath,
  });

  final SkillInstallAction action;
  final bool dryRun;
  final String targetPath;

  @override
  bool operator ==(Object other) {
    return other is SkillInstallResult &&
        other.action == action &&
        other.dryRun == dryRun &&
        other.targetPath == targetPath;
  }

  @override
  int get hashCode => Object.hash(action, dryRun, targetPath);

  @override
  String toString() {
    return 'SkillInstallResult(action: $action, dryRun: $dryRun, '
        'targetPath: $targetPath)';
  }
}

Future<SkillInstallResult> installDotweaveSkill(
  SkillInstallRequest request,
) async {
  final targetPath = p.join(request.directory, 'dotweave', 'SKILL.md');
  final dryRun = request.dryRun == true;
  final rootStats = await getPathStats(request.directory);

  if (rootStats == null || !rootStats.isDirectory) {
    throw DotweaveError(
      'Skills root must be a directory.',
      code: 'SKILL_ROOT_NOT_DIRECTORY',
      details: [request.directory],
    );
  }

  final targetExists = (await getPathStats(targetPath)) != null;

  if (targetExists && request.force != true) {
    throw DotweaveError(
      'Dotweave skill already exists.',
      code: 'SKILL_ALREADY_EXISTS',
      details: [targetPath],
      hint: "Use '--force' to overwrite the existing skill.",
    );
  }

  if (dryRun) {
    return SkillInstallResult(
      action: targetExists ? 'would-overwrite' : 'would-install',
      dryRun: dryRun,
      targetPath: targetPath,
    );
  }

  await Directory(
    p.join(request.directory, 'dotweave'),
  ).create(recursive: true);
  await writeTextFileAtomically(targetPath, dotweaveSkillContent);

  return SkillInstallResult(
    action: targetExists ? 'overwritten' : 'installed',
    dryRun: dryRun,
    targetPath: targetPath,
  );
}
