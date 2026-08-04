import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

import '../../tool/release.dart';

/// Records git invocations and replays canned stdout for the queries the
/// release commands make.
final class _FakeGit implements GitClient {
  _FakeGit({
    required this.worktreeListing,
    this.status = '',
    this.synced = true,
  });

  final String worktreeListing;
  final String status;
  final bool synced;

  final calls = <List<String>>[];

  @override
  Future<String> run(
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    calls.add(arguments);

    return switch (arguments) {
      ['worktree', 'list', '--porcelain'] => worktreeListing,
      ['status', '--porcelain'] => status,
      ['rev-parse', 'HEAD'] => 'aaaa',
      ['rev-parse', final ref] when ref.contains('/') =>
        synced ? 'aaaa' : 'bbbb',
      _ => '',
    };
  }
}

final class _RecordingExecutor implements ProcessExecutor {
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    throw UnsupportedError('not used');
  }

  @override
  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add(arguments);
    return 0;
  }
}

const String _mainWorktree = '/repo/main';
const String _featureWorktree = '/repo/feature';

const String _listing =
    'worktree $_featureWorktree\n'
    'HEAD 1111111111111111111111111111111111111111\n'
    'branch refs/heads/feature\n'
    '\n'
    'worktree $_mainWorktree\n'
    'HEAD 2222222222222222222222222222222222222222\n'
    'branch refs/heads/main\n';

void main() {
  group('release command parsing', () {
    test('accepts each bump, with and without --dry-run', () {
      for (final bump in const ['major', 'minor', 'patch']) {
        expect(
          parseReleaseCommand(['prepare', bump]),
          isA<PrepareCommand>()
              .having((command) => command.bump, 'bump', bump)
              .having((command) => command.dryRun, 'dryRun', false),
        );
        expect(
          parseReleaseCommand(['prepare', bump, '--dry-run']),
          isA<PrepareCommand>()
              .having((command) => command.bump, 'bump', bump)
              .having((command) => command.dryRun, 'dryRun', true),
        );
      }

      expect(parseReleaseCommand(const ['finalize']), isA<FinalizeCommand>());
    });

    test('rejects unknown bumps, stray flags, and missing commands', () {
      expect(parseReleaseCommand(const []), isNull);
      expect(parseReleaseCommand(const ['prepare']), isNull);
      expect(parseReleaseCommand(const ['prepare', 'nightly']), isNull);
      expect(parseReleaseCommand(const ['prepare', 'minor', '--push']), isNull);
      expect(parseReleaseCommand(const ['finalize', '--push']), isNull);
    });
  });

  group('release worktree resolution', () {
    test('finds the worktree holding the release branch', () async {
      final git = _FakeGit(worktreeListing: _listing);

      final worktree = await locateBranchWorktree(
        repoRoot: _featureWorktree,
        branch: 'main',
        git: git,
      );

      expect(worktree, _mainWorktree);
    });

    test('reports clearly when no worktree holds the release branch', () async {
      final git = _FakeGit(
        worktreeListing:
            'worktree $_featureWorktree\n'
            'HEAD 1111111111111111111111111111111111111111\n'
            'branch refs/heads/feature\n',
      );

      await expectLater(
        locateBranchWorktree(
          repoRoot: _featureWorktree,
          branch: 'main',
          git: git,
        ),
        throwsA(
          isA<ShipworldException>().having(
            (error) => error.code,
            'code',
            'branch_worktree_missing',
          ),
        ),
      );
    });
  });

  group('release prepare', () {
    late String repoRoot;

    setUp(() async {
      var root = Directory.current;
      while (!File(p.join(root.path, 'shipworld.yaml')).existsSync()) {
        final parent = root.parent;
        if (parent.path == root.path) {
          fail('Could not locate shipworld.yaml');
        }
        root = parent;
      }
      repoRoot = root.path;
    });

    test('refuses to prepare from a dirty release worktree', () async {
      final git = _FakeGit(
        worktreeListing: _listing,
        status: ' M pubspec.yaml',
      );
      final executor = _RecordingExecutor();

      await expectLater(
        prepareRelease(
          repoRoot: repoRoot,
          bump: 'minor',
          git: git,
          executor: executor,
          log: (_) {},
        ),
        throwsA(
          isA<ShipworldException>().having(
            (error) => error.code,
            'code',
            'worktree_dirty',
          ),
        ),
      );
      expect(executor.calls, isEmpty);
    });

    test(
      'refuses to prepare when the release branch lags the remote',
      () async {
        final git = _FakeGit(worktreeListing: _listing, synced: false);
        final executor = _RecordingExecutor();

        await expectLater(
          prepareRelease(
            repoRoot: repoRoot,
            bump: 'minor',
            git: git,
            executor: executor,
            log: (_) {},
          ),
          throwsA(
            isA<ShipworldException>().having(
              (error) => error.code,
              'code',
              'worktree_behind',
            ),
          ),
        );
        expect(executor.calls, isEmpty);
      },
    );

    test('a dry run neither pushes nor resets', () async {
      final git = _FakeGit(worktreeListing: _listing);
      final executor = _RecordingExecutor();

      await prepareRelease(
        repoRoot: repoRoot,
        bump: 'minor',
        dryRun: true,
        git: git,
        executor: executor,
        log: (_) {},
      );

      expect(executor.calls, [
        [
          'run',
          'shipworld:shipworld',
          'release',
          'prepare',
          'dotweave=minor',
          '--dry-run',
        ],
      ]);
      expect(
        git.calls.where(
          (call) => call.first == 'push' || call.first == 'reset',
        ),
        isEmpty,
      );
    });
  });
}
