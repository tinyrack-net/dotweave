import 'dart:io';

import 'package:dotweave_tools/src/lib/verify.dart';
import 'package:dotweave_tools/src/lib/version_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final tempDirectories = <Directory>[];

  tearDown(() async {
    while (tempDirectories.isNotEmpty) {
      final directory = tempDirectories.removeLast();

      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    }
  });

  Future<String> createRepo({
    String packageJsonVersion = '1.2.3',
    String pubspecVersion = '1.2.3',
    String constantVersion = '1.2.3',
  }) async {
    final directory = await Directory.systemTemp.createTemp('dotweave-verify-');
    tempDirectories.add(directory);

    final repoRoot = directory.path;

    await Directory(
      p.join(repoRoot, 'packages', 'cli'),
    ).create(recursive: true);
    await Directory(
      p.join(repoRoot, 'packages', 'cli_dart', 'lib', 'src', 'lib'),
    ).create(recursive: true);

    await File(
      p.join(repoRoot, 'packages', 'cli', 'package.json'),
    ).writeAsString(
      '{\n  "name": "@tinyrack/dotweave",\n'
      '  "version": "$packageJsonVersion"\n}\n',
    );
    await File(
      p.join(repoRoot, 'packages', 'cli_dart', 'pubspec.yaml'),
    ).writeAsString('name: dotweave\nversion: $pubspecVersion\n');
    await File(
      p.join(
        repoRoot,
        'packages',
        'cli_dart',
        'lib',
        'src',
        'lib',
        'version.g.dart',
      ),
    ).writeAsString(renderVersionConstant(constantVersion));

    return repoRoot;
  }

  test('passes when tag and all release versions match', () async {
    final repoRoot = await createRepo();

    await performVerifyReleaseTag(
      repoRoot: repoRoot,
      environment: const {'GITHUB_REF_NAME': 'v1.2.3'},
    );
  });

  test('throws when GITHUB_REF_NAME is not set', () async {
    final repoRoot = await createRepo();

    await expectLater(
      performVerifyReleaseTag(repoRoot: repoRoot, environment: const {}),
      throwsA(
        predicate((Object? error) => '$error'.contains('GITHUB_REF_NAME')),
      ),
    );
  });

  test('throws when the tag does not match the version', () async {
    final repoRoot = await createRepo();

    await expectLater(
      performVerifyReleaseTag(
        repoRoot: repoRoot,
        environment: const {'GITHUB_REF_NAME': 'v9.9.9'},
      ),
      throwsA(
        predicate(
          (Object? error) =>
              '$error'.contains('Tag v9.9.9 does not match') &&
              '$error'.contains('v1.2.3'),
        ),
      ),
    );
  });

  test('throws when pubspec version disagrees with package.json', () async {
    final repoRoot = await createRepo(pubspecVersion: '1.2.4');

    await expectLater(
      performVerifyReleaseTag(
        repoRoot: repoRoot,
        environment: const {'GITHUB_REF_NAME': 'v1.2.3'},
      ),
      throwsA(
        predicate(
          (Object? error) => '$error'.contains('Release versions do not match'),
        ),
      ),
    );
  });

  test('throws when version.g.dart disagrees with pubspec', () async {
    final repoRoot = await createRepo(constantVersion: '1.2.9');

    await expectLater(
      performVerifyReleaseTag(
        repoRoot: repoRoot,
        environment: const {'GITHUB_REF_NAME': 'v1.2.3'},
      ),
      throwsA(
        predicate(
          (Object? error) => '$error'.contains('Release versions do not match'),
        ),
      ),
    );
  });
}
