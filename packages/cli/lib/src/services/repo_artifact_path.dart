import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/util/error.dart';

// The artifact path codec: the pure half of `services/repo-artifacts.ts`.
//
// Repository artifacts live at `profiles/<profile>/<repoPath>`, with a `.age`
// suffix for secrets and a `.dotweave.symlink` suffix for symlink metadata
// files. Encoding and decoding that layout involves no I/O, so it lives here
// rather than in the artifact reader/writer, where it used to sit alongside
// filesystem walking, ownership rules, and git invocation.

/// Mirror of the TS inline return shape of [parseArtifactRelativePath].
typedef ParsedArtifactPath = ({
  String profile,
  String repoPath,
  bool secret,
  bool symlink,
});

/// Physical directory under the sync repository holding every profile tree.
const String artifactProfilesRoot = 'profiles';

/// Mirror of the TS `resolveArtifactLogicalPath` whose parameter picks
/// `category`/`profile`/`repoPath` from `RepoArtifact` with an optional
/// `kind`; [kind] is optional accordingly.
String resolveArtifactLogicalPath({
  required String category,
  String? kind,
  required String profile,
  required String repoPath,
}) {
  final profileRelativePath = '$profile/$repoPath';

  if (kind == 'symlink') {
    return '$profileRelativePath${AppConstants.sync.symlinkArtifactSuffix}';
  }

  return category == 'secret'
      ? '$profileRelativePath${AppConstants.sync.secretArtifactSuffix}'
      : profileRelativePath;
}

bool isSecretArtifactPath(String relativePath) {
  return relativePath.endsWith(AppConstants.sync.secretArtifactSuffix);
}

String? stripSecretArtifactSuffix(String relativePath) {
  if (!isSecretArtifactPath(relativePath)) {
    return null;
  }

  return relativePath.substring(
    0,
    relativePath.length - AppConstants.sync.secretArtifactSuffix.length,
  );
}

bool isSymlinkArtifactPath(String relativePath) {
  return relativePath.endsWith(AppConstants.sync.symlinkArtifactSuffix);
}

String? stripSymlinkArtifactSuffix(String relativePath) {
  if (!isSymlinkArtifactPath(relativePath)) {
    return null;
  }

  return relativePath.substring(
    0,
    relativePath.length - AppConstants.sync.symlinkArtifactSuffix.length,
  );
}

void assertStorageSafeRepoPath(String repoPath) {
  if (!hasReservedSyncArtifactSuffixSegment(repoPath)) {
    return;
  }

  throw DotweaveError(
    'Tracked sync paths must not use the reserved suffixes '
    '${AppConstants.sync.secretArtifactSuffix} or '
    '${AppConstants.sync.symlinkArtifactSuffix}.',
    code: 'RESERVED_ARTIFACT_SUFFIX',
    details: ['Repository path: $repoPath'],
    hint:
        'Rename the tracked path so no segment ends with a reserved artifact '
        'suffix.',
  );
}

/// Mirror of the TS `resolveArtifactRelativePath`; see
/// [resolveArtifactLogicalPath] for the parameter shape.
String resolveArtifactRelativePath({
  required String category,
  String? kind,
  required String profile,
  required String repoPath,
}) {
  final logicalPath = resolveArtifactLogicalPath(
    category: category,
    kind: kind,
    profile: profile,
    repoPath: repoPath,
  );

  return '$artifactProfilesRoot/$logicalPath';
}

({String logicalPath, bool secret, bool symlink}) _stripArtifactSuffix(
  String relativePath,
) {
  final symlink = relativePath.endsWith(
    AppConstants.sync.symlinkArtifactSuffix,
  );
  final secret =
      !symlink && relativePath.endsWith(AppConstants.sync.secretArtifactSuffix);
  final suffixLength = symlink
      ? AppConstants.sync.symlinkArtifactSuffix.length
      : secret
      ? AppConstants.sync.secretArtifactSuffix.length
      : 0;

  return (
    logicalPath: suffixLength == 0
        ? relativePath
        : relativePath.substring(0, relativePath.length - suffixLength),
    secret: secret,
    symlink: symlink,
  );
}

/// Parses a repository-relative artifact path (`profiles/<profile>/...`).
ParsedArtifactPath parseArtifactRelativePath(String relativePath) {
  final stripped = _stripArtifactSuffix(relativePath);
  final segments = stripped.logicalPath.split('/');

  if (segments.length < 3 || segments[0] != artifactProfilesRoot) {
    throw DotweaveError(
      'Repository artifact path is invalid.',
      code: 'INVALID_REPO_ENTRY',
      details: ['Repository path: $relativePath'],
    );
  }

  final profile = segments[1];
  final repoPathSegments = segments.sublist(2);
  final normalizedProfile = normalizeSyncProfileName(
    profile,
    'Repository artifact profile',
  );

  return (
    profile: normalizedProfile,
    repoPath: repoPathSegments.join('/'),
    secret: stripped.secret,
    symlink: stripped.symlink,
  );
}

/// Parses an artifact key (`<profile>/...`), which omits the profiles root.
ParsedArtifactPath parseArtifactLogicalPath(String relativePath) {
  final stripped = _stripArtifactSuffix(relativePath);
  final segments = stripped.logicalPath.split('/');

  if (segments.length < 2) {
    throw DotweaveError(
      'Repository artifact key is invalid.',
      code: 'INVALID_REPO_ENTRY',
      details: ['Artifact key: $relativePath'],
    );
  }

  final profile = segments[0];
  final repoPathSegments = segments.sublist(1);

  return (
    profile: normalizeSyncProfileName(profile, 'Repository artifact profile'),
    repoPath: repoPathSegments.join('/'),
    secret: stripped.secret,
    symlink: stripped.symlink,
  );
}
