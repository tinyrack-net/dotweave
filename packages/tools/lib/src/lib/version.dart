import 'error.dart';

/// Semver bump type accepted by the release command.
enum ReleaseType { patch, minor, major }

ReleaseType parseReleaseType(String input) {
  for (final releaseType in ReleaseType.values) {
    if (releaseType.name == input) {
      return releaseType;
    }
  }

  throw ToolException(
    'release-type: Invalid release type: $input. '
    'Must be one of: patch, minor, major',
  );
}

class Version {
  const Version({
    required this.major,
    required this.minor,
    required this.patch,
  });

  final int major;
  final int minor;
  final int patch;

  @override
  bool operator ==(Object other) {
    return other is Version &&
        other.major == major &&
        other.minor == minor &&
        other.patch == patch;
  }

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => formatVersion(this);
}

final RegExp _versionPattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');
final RegExp _versionTagPattern = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$');

Version parseVersion(String version) {
  final match = _versionPattern.firstMatch(version);

  if (match == null) {
    throw ToolException('Invalid version: $version');
  }

  return Version(
    major: int.parse(match.group(1)!),
    minor: int.parse(match.group(2)!),
    patch: int.parse(match.group(3)!),
  );
}

Version parseVersionTag(String tag) {
  final match = _versionTagPattern.firstMatch(tag);

  if (match == null) {
    throw ToolException('Invalid release tag: $tag');
  }

  return Version(
    major: int.parse(match.group(1)!),
    minor: int.parse(match.group(2)!),
    patch: int.parse(match.group(3)!),
  );
}

String formatVersion(Version version) {
  return '${version.major}.${version.minor}.${version.patch}';
}

String formatVersionTag(Version version) {
  return 'v${formatVersion(version)}';
}

Version bumpVersion(Version version, ReleaseType releaseType) {
  switch (releaseType) {
    case ReleaseType.patch:
      return Version(
        major: version.major,
        minor: version.minor,
        patch: version.patch + 1,
      );
    case ReleaseType.minor:
      return Version(major: version.major, minor: version.minor + 1, patch: 0);
    case ReleaseType.major:
      return Version(major: version.major + 1, minor: 0, patch: 0);
  }
}
