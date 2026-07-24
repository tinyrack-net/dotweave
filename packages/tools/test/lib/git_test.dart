import 'dart:io';

import 'package:dotweave_tools/src/lib/git.dart';
import 'package:test/test.dart';

class RecordedCall {
  const RecordedCall(this.args, this.workingDirectory);

  final List<String> args;
  final String workingDirectory;
}

void main() {
  final calls = <RecordedCall>[];

  void mockGitSuccess(String stdout) {
    gitRunner = (args, workingDirectory) async {
      calls.add(RecordedCall(args, workingDirectory));
      return ProcessResult(0, 0, stdout, '');
    };
  }

  void mockGitFailure(String stderr) {
    gitRunner = (args, workingDirectory) async {
      calls.add(RecordedCall(args, workingDirectory));
      return ProcessResult(0, 1, '', stderr);
    };
  }

  setUp(calls.clear);

  tearDown(() {
    gitRunner = defaultGitRunner;
  });

  group('getRepoRoot', () {
    test('passes rev-parse --show-toplevel to git', () async {
      mockGitSuccess('/repo/root\n');
      final result = await getRepoRoot('/some/cwd');

      expect(result, '/repo/root');
      expect(calls.single.args, ['rev-parse', '--show-toplevel']);
      expect(calls.single.workingDirectory, '/some/cwd');
    });

    test('trims stdout whitespace', () async {
      mockGitSuccess('  /repo/root  \n  ');
      final result = await getRepoRoot('/some/cwd');

      expect(result, '/repo/root');
    });
  });

  group('getWorktreeStatus', () {
    test('passes status --porcelain to git', () async {
      mockGitSuccess('M file.ts\n');
      final result = await getWorktreeStatus('/repo');

      expect(result, 'M file.ts');
      expect(calls.single.args, ['status', '--porcelain']);
      expect(calls.single.workingDirectory, '/repo');
    });

    test('returns empty string for clean worktree', () async {
      mockGitSuccess('');
      final result = await getWorktreeStatus('/repo');

      expect(result, '');
    });
  });

  group('hasTag', () {
    test('returns true when tag matches exactly', () async {
      mockGitSuccess('v1.0.0');

      expect(await hasTag('/repo', 'v1.0.0'), isTrue);
      expect(calls.single.args, ['tag', '--list', 'v1.0.0']);
    });

    test('returns false when tag list is empty', () async {
      mockGitSuccess('');

      expect(await hasTag('/repo', 'v1.0.0'), isFalse);
    });

    test('returns false when tag list contains different tag', () async {
      mockGitSuccess('v1.0.1');

      expect(await hasTag('/repo', 'v1.0.0'), isFalse);
    });
  });

  group('stageFiles', () {
    test('passes add with file paths to git', () async {
      mockGitSuccess('');
      await stageFiles('/repo', ['a.ts', 'b.ts']);

      expect(calls.single.args, ['add', 'a.ts', 'b.ts']);
      expect(calls.single.workingDirectory, '/repo');
    });
  });

  group('createCommit', () {
    test('passes commit -m with message to git', () async {
      mockGitSuccess('');
      await createCommit('/repo', 'release: v1.0.0');

      expect(calls.single.args, ['commit', '-m', 'release: v1.0.0']);
      expect(calls.single.workingDirectory, '/repo');
    });
  });

  group('createTag', () {
    test('uses -s (signed) by default when sign omitted', () async {
      mockGitSuccess('');
      await createTag('/repo', 'v1.0.0', 'release: v1.0.0');

      expect(calls.single.args, [
        'tag',
        '-s',
        'v1.0.0',
        '-m',
        'release: v1.0.0',
      ]);
    });

    test('uses -s when sign is true', () async {
      mockGitSuccess('');
      await createTag('/repo', 'v1.0.0', 'release: v1.0.0', sign: true);

      expect(calls.single.args, [
        'tag',
        '-s',
        'v1.0.0',
        '-m',
        'release: v1.0.0',
      ]);
    });

    test('uses -a (unsigned) when sign is false', () async {
      mockGitSuccess('');
      await createTag('/repo', 'v1.0.0', 'msg', sign: false);

      expect(calls.single.args, ['tag', '-a', 'v1.0.0', '-m', 'msg']);
    });
  });

  group('error formatting', () {
    test('includes stderr in the failure message', () async {
      mockGitFailure('fatal: not a repository');

      await expectLater(
        getRepoRoot('/bad'),
        throwsA(
          predicate(
            (Object? error) => '$error'.contains(
              'git rev-parse --show-toplevel failed: fatal: not a repository',
            ),
          ),
        ),
      );
    });

    test('falls back to generic message when stderr is empty', () async {
      mockGitFailure('');

      await expectLater(
        getRepoRoot('/bad'),
        throwsA(
          predicate(
            (Object? error) =>
                '$error' == 'git rev-parse --show-toplevel failed',
          ),
        ),
      );
    });
  });
}
