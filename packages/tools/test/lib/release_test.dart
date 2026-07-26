import 'dart:io';

import 'package:dotweave_tools/src/lib/git.dart';
import 'package:dotweave_tools/src/lib/release.dart';
import 'package:dotweave_tools/src/lib/version.dart';
import 'package:test/test.dart';

class FakeReleaseTarget implements ReleaseTarget {
  FakeReleaseTarget(this.path, {this.version = '1.2.3', this.readError});

  @override
  final String path;

  final String version;

  /// Typed rather than `Object?` so the rethrow below is a legal `throw`; the
  /// only value any test injects is a `FormatException`.
  final Exception? readError;
  final List<String> writtenVersions = [];

  @override
  Future<String> readVersion(String repoRoot) async {
    final error = readError;

    if (error != null) {
      throw error;
    }

    return version;
  }

  @override
  Future<void> writeVersion(String repoRoot, String version) async {
    writtenVersions.add(version);
  }
}

void main() {
  final gitCalls = <List<String>>[];
  var worktreeStatus = '';
  var tagExists = false;
  final infoMessages = <String>[];
  final startMessages = <String>[];

  final logger = ReleaseLogger(
    info: infoMessages.add,
    start: startMessages.add,
  );

  setUp(() {
    gitCalls.clear();
    infoMessages.clear();
    startMessages.clear();
    worktreeStatus = '';
    tagExists = false;

    gitRunner = (args, workingDirectory) async {
      gitCalls.add(args);

      switch (args.first) {
        case 'rev-parse':
          return ProcessResult(0, 0, '/repo\n', '');
        case 'status':
          return ProcessResult(0, 0, worktreeStatus, '');
        case 'tag' when args[1] == '--list':
          return ProcessResult(0, 0, tagExists ? args.last : '', '');
        default:
          return ProcessResult(0, 0, '', '');
      }
    };
  });

  tearDown(() {
    gitRunner = defaultGitRunner;
  });

  List<List<String>> gitCallsFor(String subcommand) {
    return [
      for (final call in gitCalls)
        if (call.first == subcommand) call,
    ];
  }

  group('release targets', () {
    test('updates the cli pubspec and version.g.dart', () {
      expect(releaseTargets.map((target) => target.path), [
        'packages/cli/pubspec.yaml',
        'packages/cli/lib/src/lib/version.g.dart',
      ]);
    });
  });

  group('happy path', () {
    test('bumps version, writes, stages, commits, and tags', () async {
      final targets = [
        FakeReleaseTarget('packages/cli/package.json'),
        FakeReleaseTarget('packages/cli/pubspec.yaml'),
      ];

      final result = await performRelease(
        cwd: '/repo',
        dryRun: false,
        logger: logger,
        releaseType: ReleaseType.patch,
        targets: targets,
      );

      expect(targets[0].writtenVersions, ['1.2.4']);
      expect(targets[1].writtenVersions, ['1.2.4']);
      expect(gitCallsFor('add').single, [
        'add',
        'packages/cli/package.json',
        'packages/cli/pubspec.yaml',
      ]);
      expect(gitCallsFor('commit').single, ['commit', '-m', 'release: v1.2.4']);
      expect(gitCalls.last, ['tag', '-s', 'v1.2.4', '-m', 'release: v1.2.4']);
      expect(result.dryRun, isFalse);
      expect(result.previousTag, 'v1.2.3');
      expect(result.tag, 'v1.2.4');
      expect(result.version, '1.2.4');
    });
  });

  group('signTag option', () {
    test('defaults signTag to true (signed tag)', () async {
      await performRelease(
        cwd: '/repo',
        dryRun: false,
        logger: logger,
        releaseType: ReleaseType.patch,
        targets: [FakeReleaseTarget('packages/cli/package.json')],
      );

      expect(gitCalls.last, ['tag', '-s', 'v1.2.4', '-m', 'release: v1.2.4']);
    });

    test('passes signTag:false through as unsigned', () async {
      await performRelease(
        cwd: '/repo',
        dryRun: false,
        logger: logger,
        releaseType: ReleaseType.patch,
        signTag: false,
        targets: [FakeReleaseTarget('packages/cli/package.json')],
      );

      expect(gitCalls.last, ['tag', '-a', 'v1.2.4', '-m', 'release: v1.2.4']);
    });
  });

  group('dirty worktree', () {
    test('throws when worktree dirty and dryRun is false', () async {
      worktreeStatus = 'M file.ts';

      await expectLater(
        performRelease(
          cwd: '/repo',
          dryRun: false,
          logger: logger,
          releaseType: ReleaseType.patch,
          targets: [FakeReleaseTarget('packages/cli/package.json')],
        ),
        throwsA(
          predicate(
            (Object? error) => '$error'.contains('worktree must be clean'),
          ),
        ),
      );
    });

    test('succeeds with warning when worktree dirty and dryRun', () async {
      worktreeStatus = 'M file.ts';

      final result = await performRelease(
        cwd: '/repo',
        dryRun: true,
        logger: logger,
        releaseType: ReleaseType.patch,
        targets: [FakeReleaseTarget('packages/cli/package.json')],
      );

      expect(result.dryRun, isTrue);
      expect(infoMessages, anyElement(contains('dirty')));
    });
  });

  group('missing version', () {
    test('throws when target readVersion fails', () async {
      await expectLater(
        performRelease(
          cwd: '/repo',
          dryRun: false,
          logger: logger,
          releaseType: ReleaseType.patch,
          targets: [
            FakeReleaseTarget(
              'packages/cli/package.json',
              readError: const FormatException(
                'Missing version in /repo/packages/cli/package.json',
              ),
            ),
          ],
        ),
        throwsA(
          predicate((Object? error) => '$error'.contains('Missing version')),
        ),
      );
    });
  });

  group('mismatched versions', () {
    test('throws when targets disagree on the current version', () async {
      await expectLater(
        performRelease(
          cwd: '/repo',
          dryRun: false,
          logger: logger,
          releaseType: ReleaseType.patch,
          targets: [
            FakeReleaseTarget('packages/cli/package.json'),
            FakeReleaseTarget('packages/cli/pubspec.yaml', version: '9.9.9'),
          ],
        ),
        throwsA(
          predicate(
            (Object? error) =>
                '$error'.contains('must share the same version') &&
                '$error'.contains('1.2.3, 9.9.9'),
          ),
        ),
      );
    });
  });

  group('tag collision', () {
    test('throws when target tag already exists', () async {
      tagExists = true;

      await expectLater(
        performRelease(
          cwd: '/repo',
          dryRun: false,
          logger: logger,
          releaseType: ReleaseType.patch,
          targets: [FakeReleaseTarget('packages/cli/package.json')],
        ),
        throwsA(
          predicate((Object? error) => '$error'.contains('tag already exists')),
        ),
      );
    });
  });

  group('dry-run path', () {
    test('does not write, stage, commit, or tag', () async {
      final target = FakeReleaseTarget('packages/cli/package.json');

      await performRelease(
        cwd: '/repo',
        dryRun: true,
        logger: logger,
        releaseType: ReleaseType.patch,
        targets: [target],
      );

      expect(target.writtenVersions, isEmpty);
      expect(gitCallsFor('add'), isEmpty);
      expect(gitCallsFor('commit'), isEmpty);
      expect(
        gitCalls.where(
          (call) => call.first == 'tag' && !call.contains('--list'),
        ),
        isEmpty,
      );
    });

    test('returns dryRun true with correct version info', () async {
      final result = await performRelease(
        cwd: '/repo',
        dryRun: true,
        logger: logger,
        releaseType: ReleaseType.minor,
        targets: [FakeReleaseTarget('packages/cli/package.json')],
      );

      expect(result.dryRun, isTrue);
      expect(result.previousTag, 'v1.2.3');
      expect(result.tag, 'v1.3.0');
      expect(result.version, '1.3.0');
    });

    test('logs dry-run info messages', () async {
      await performRelease(
        cwd: '/repo',
        dryRun: true,
        logger: logger,
        releaseType: ReleaseType.patch,
        targets: [FakeReleaseTarget('packages/cli/package.json')],
      );

      expect(startMessages, anyElement(contains('Dry run')));
      expect(infoMessages, anyElement(contains('Would update')));
    });
  });
}
