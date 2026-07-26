import 'dart:io';

import 'error.dart';
import 'release.dart';

/// Verifies that GITHUB_REF_NAME matches the release version and that all
/// release version files agree with each other.
///
/// Reads the same [releaseTargets] the release command writes, so the two can
/// never disagree about where a version lives.
Future<void> performVerifyReleaseTag({
  required String repoRoot,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final versions = <String, String>{
    for (final target in releaseTargets)
      target.path: await target.readVersion(repoRoot),
  };

  final releaseVersion = versions.values.first;

  if (versions.values.any((version) => version != releaseVersion)) {
    throw ToolException(
      'Release versions do not match: '
      '${versions.entries.map((entry) => '${entry.key}=${entry.value}').join(', ')}',
    );
  }

  final tag = env['GITHUB_REF_NAME'];

  if (tag == null || tag.isEmpty) {
    throw const ToolException(
      'GITHUB_REF_NAME environment variable is not set',
    );
  }

  final expectedTag = 'v$releaseVersion';

  if (tag != expectedTag) {
    throw ToolException(
      'Tag $tag does not match pubspec.yaml version $expectedTag',
    );
  }

  stdout.writeln('Verified tag $tag matches version $releaseVersion');
}
