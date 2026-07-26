import 'dart:io';

import 'package:dotweave/src/util/filesystem.dart';
import 'package:path/path.dart' as p;

// Mirror of `services/repository-ignore.ts`: keeps the managed secret
// artifact rules block in the sync repository .gitignore.

const String _gitIgnoreFileName = '.gitignore';
const String _beginMarker = '# BEGIN dotweave managed secret artifact rules';
const String _endMarker = '# END dotweave managed secret artifact rules';

const String managedSecretArtifactIgnoreBlock =
    '$_beginMarker\n'
    '!profiles/\n'
    '!profiles/**/\n'
    '!profiles/**/*.dotweave.secret\n'
    '!profiles/**/*.dotweave.symlink\n'
    '$_endMarker\n';

final RegExp _managedSecretArtifactIgnoreBlockPattern = RegExp(
  '$_beginMarker[\\s\\S]*?$_endMarker\\n?',
);

Future<void> ensureManagedSecretArtifactIgnoreRules(
  String syncDirectory,
) async {
  final ignorePath = p.join(syncDirectory, _gitIgnoreFileName);
  final existingContents = await pathExists(ignorePath)
      ? await File(ignorePath).readAsString()
      : '';

  final withoutManagedBlock = existingContents.replaceAll(
    _managedSecretArtifactIgnoreBlockPattern,
    '',
  );
  final nextContents =
      '$withoutManagedBlock'
      '${withoutManagedBlock == '' || withoutManagedBlock.endsWith('\n') ? '' : '\n'}'
      '$managedSecretArtifactIgnoreBlock';

  if (nextContents == existingContents) {
    return;
  }

  await writeTextFileAtomically(ignorePath, nextContents);
}
