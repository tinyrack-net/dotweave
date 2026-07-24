import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';
import 'version_files.dart';

const String _packageJsonPath = 'packages/cli/package.json';
const String _pubspecPath = 'packages/cli/pubspec.yaml';
const String _versionConstantPath = 'packages/cli/lib/src/lib/version.g.dart';

/// Verifies that GITHUB_REF_NAME matches the release version and that all
/// release version files agree with each other.
Future<void> performVerifyReleaseTag({
  required String repoRoot,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final packageJsonVersion = await readPackageJsonVersion(
    p.join(repoRoot, _packageJsonPath),
  );
  final pubspecVersion = await readPubspecVersion(
    p.join(repoRoot, _pubspecPath),
  );
  final constantVersion = await readVersionConstant(
    p.join(repoRoot, _versionConstantPath),
  );

  if (pubspecVersion != constantVersion ||
      packageJsonVersion != pubspecVersion) {
    throw ToolException(
      'Release versions do not match: '
      '$_packageJsonPath=$packageJsonVersion, '
      '$_pubspecPath=$pubspecVersion, '
      '$_versionConstantPath=$constantVersion',
    );
  }

  final tag = env['GITHUB_REF_NAME'];

  if (tag == null || tag.isEmpty) {
    throw const ToolException(
      'GITHUB_REF_NAME environment variable is not set',
    );
  }

  final expectedTag = 'v$packageJsonVersion';

  if (tag != expectedTag) {
    throw ToolException(
      'Tag $tag does not match package.json version $expectedTag',
    );
  }

  stdout.writeln('Verified tag $tag matches version $packageJsonVersion');
}
