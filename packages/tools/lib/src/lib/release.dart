import 'package:path/path.dart' as p;

import 'error.dart';
import 'git.dart';
import 'version.dart';
import 'version_files.dart';

/// A version-carrying file updated by the release command.
abstract class ReleaseTarget {
  /// Repo-relative path (forward slashes) used for logging and git staging.
  String get path;

  Future<String> readVersion(String repoRoot);

  Future<void> writeVersion(String repoRoot, String version);
}

class PubspecReleaseTarget implements ReleaseTarget {
  const PubspecReleaseTarget(this.path);

  @override
  final String path;

  @override
  Future<String> readVersion(String repoRoot) {
    return readPubspecVersion(p.join(repoRoot, path));
  }

  @override
  Future<void> writeVersion(String repoRoot, String version) {
    return writePubspecVersion(p.join(repoRoot, path), version);
  }
}

class VersionConstantReleaseTarget implements ReleaseTarget {
  const VersionConstantReleaseTarget(this.path);

  @override
  final String path;

  @override
  Future<String> readVersion(String repoRoot) {
    return readVersionConstant(p.join(repoRoot, path));
  }

  @override
  Future<void> writeVersion(String repoRoot, String version) {
    return writeVersionConstant(p.join(repoRoot, path), version);
  }
}

/// Files whose versions are bumped together by `release`.
const List<ReleaseTarget> releaseTargets = [
  PubspecReleaseTarget('packages/cli/pubspec.yaml'),
  VersionConstantReleaseTarget('packages/cli/lib/src/util/version.g.dart'),
];

class ReleaseLogger {
  const ReleaseLogger({required this.info, required this.start});

  final void Function(String message) info;
  final void Function(String message) start;
}

class ReleaseResult {
  const ReleaseResult({
    required this.dryRun,
    required this.previousTag,
    required this.tag,
    required this.version,
  });

  final bool dryRun;
  final String previousTag;
  final String tag;
  final String version;
}

Future<ReleaseResult> performRelease({
  required String cwd,
  required bool dryRun,
  required ReleaseLogger logger,
  required ReleaseType releaseType,
  bool signTag = true,
  List<ReleaseTarget> targets = releaseTargets,
}) async {
  final repoRoot = await getRepoRoot(cwd);
  final worktreeStatus = await getWorktreeStatus(repoRoot);

  if (!dryRun && worktreeStatus.isNotEmpty) {
    throw const ToolException('Git worktree must be clean before releasing');
  }

  final currentPackageVersions = <String>[
    for (final target in targets) await target.readVersion(repoRoot),
  ];

  if (currentPackageVersions.isEmpty) {
    throw const ToolException('Release targets are missing versions');
  }

  final expectedVersion = currentPackageVersions.first;
  final hasMismatchedVersion = currentPackageVersions.any(
    (version) => version != expectedVersion,
  );

  if (hasMismatchedVersion) {
    throw ToolException(
      'Release targets must share the same version. '
      'Found: ${currentPackageVersions.join(', ')}',
    );
  }

  final currentVersion = parseVersion(expectedVersion);
  final currentTag = formatVersionTag(currentVersion);
  final nextVersion = bumpVersion(currentVersion, releaseType);
  final nextTag = formatVersionTag(nextVersion);
  final nextVersionText = formatVersion(nextVersion);

  if (await hasTag(repoRoot, nextTag)) {
    throw ToolException('Release tag already exists: $nextTag');
  }

  if (dryRun) {
    logger.start('Dry run for $nextTag from $currentTag');

    if (worktreeStatus.isNotEmpty) {
      logger.info(
        'Worktree is dirty; dry run will not modify files or git state',
      );
    }

    for (final target in targets) {
      logger.info('Would update ${target.path} to $nextVersionText');
    }

    return ReleaseResult(
      dryRun: true,
      previousTag: currentTag,
      tag: nextTag,
      version: nextVersionText,
    );
  }

  logger.start('Releasing $nextTag from $currentTag');

  for (final target in targets) {
    await target.writeVersion(repoRoot, nextVersionText);
    logger.info('Updated ${target.path} to $nextVersionText');
  }

  await stageFiles(repoRoot, [for (final target in targets) target.path]);

  final commitMessage = 'release: v$nextVersionText';
  final tagMessage = 'release: v$nextVersionText';

  await createCommit(repoRoot, commitMessage);
  await createTag(repoRoot, nextTag, tagMessage, sign: signTag);

  return ReleaseResult(
    dryRun: false,
    previousTag: currentTag,
    tag: nextTag,
    version: nextVersionText,
  );
}
