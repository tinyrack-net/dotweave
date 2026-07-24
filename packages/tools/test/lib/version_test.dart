import 'package:dotweave_tools/src/lib/version.dart';
import 'package:test/test.dart';

void main() {
  group('version helpers', () {
    test('parses release tags', () {
      expect(
        parseVersionTag('v0.39.22'),
        const Version(major: 0, minor: 39, patch: 22),
      );
    });

    test('parses versions', () {
      expect(
        parseVersion('0.39.22'),
        const Version(major: 0, minor: 39, patch: 22),
      );
    });

    test('bumps versions by release type', () {
      final version = parseVersionTag('v0.39.22');

      expect(formatVersion(bumpVersion(version, ReleaseType.patch)), '0.39.23');
      expect(formatVersion(bumpVersion(version, ReleaseType.minor)), '0.40.0');
      expect(
        formatVersionTag(bumpVersion(version, ReleaseType.major)),
        'v1.0.0',
      );
    });

    test('rejects invalid tags', () {
      expect(
        () => parseVersionTag('1.2.3'),
        throwsA(
          predicate(
            (Object? error) => '$error'.contains('Invalid release tag'),
          ),
        ),
      );
    });

    test('rejects invalid versions', () {
      expect(
        () => parseVersion('v1.2.3'),
        throwsA(
          predicate((Object? error) => '$error'.contains('Invalid version')),
        ),
      );
    });
  });

  group('parseReleaseType', () {
    test('parses valid release types', () {
      expect(parseReleaseType('patch'), ReleaseType.patch);
      expect(parseReleaseType('minor'), ReleaseType.minor);
      expect(parseReleaseType('major'), ReleaseType.major);
    });

    test('rejects invalid release types', () {
      expect(
        () => parseReleaseType('huge'),
        throwsA(
          predicate(
            (Object? error) => '$error'.contains('Invalid release type'),
          ),
        ),
      );
    });
  });
}
