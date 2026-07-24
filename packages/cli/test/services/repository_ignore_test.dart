import 'dart:io';

import 'package:dotweave/src/services/repository_ignore.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-ignore-test-',
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

  group('repository ignore rules', () {
    test('creates the managed secret artifact block', () async {
      final workspace = await createWorkspace();

      await ensureManagedSecretArtifactIgnoreRules(workspace);

      expect(
        await File(p.join(workspace, '.gitignore')).readAsString(),
        managedSecretArtifactIgnoreBlock,
      );
    });

    test('appends the managed block after existing user rules', () async {
      final workspace = await createWorkspace();
      final ignorePath = p.join(workspace, '.gitignore');

      await Directory(workspace).create(recursive: true);
      await File(ignorePath).writeAsString('*.dotweave.secret\nbuild/\n');

      await ensureManagedSecretArtifactIgnoreRules(workspace);

      expect(
        await File(ignorePath).readAsString(),
        '*.dotweave.secret\nbuild/\n$managedSecretArtifactIgnoreBlock',
      );
    });

    test('replaces an existing managed block without duplicating it', () async {
      final workspace = await createWorkspace();
      final ignorePath = p.join(workspace, '.gitignore');

      await Directory(workspace).create(recursive: true);
      await File(ignorePath).writeAsString(
        'node_modules/\n'
        '# BEGIN dotweave managed secret artifact rules\n'
        'old\n'
        '# END dotweave managed secret artifact rules\n'
        '*.log\n',
      );

      await ensureManagedSecretArtifactIgnoreRules(workspace);
      await ensureManagedSecretArtifactIgnoreRules(workspace);

      expect(
        await File(ignorePath).readAsString(),
        'node_modules/\n*.log\n$managedSecretArtifactIgnoreBlock',
      );
    });
  });
}
