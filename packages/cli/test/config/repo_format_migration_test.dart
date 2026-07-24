import 'package:dotweave/src/config/repo_format_migration.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:test/test.dart';

ResolvedSyncConfig configWithFormat(int? repositoryFormat) {
  return ResolvedSyncConfig(
    entries: const [],
    profiles: const [],
    version: 8,
    repositoryFormat: repositoryFormat,
  );
}

RepoFormatMigrationRegistry registry(
  List<(int, RepoFormatMigrationFn)> entries,
) {
  return {for (final (format, fn) in entries) format: fn};
}

Matcher throwsDotweaveErrorMatching(String messagePart) {
  return throwsA(
    isA<DotweaveError>().having(
      (error) => error.message,
      'message',
      contains(messagePart),
    ),
  );
}

void main() {
  group('assertRepositoryFormatSupported', () {
    test('passes when the format is within range', () {
      expect(
        () => assertRepositoryFormatSupported(1, 1, 0, 'ctx'),
        returnsNormally,
      );
      expect(
        () => assertRepositoryFormatSupported(0, 1, 0, 'ctx'),
        returnsNormally,
      );
    });

    test('throws REPO_FORMAT_NEWER when the format is above the target', () {
      expect(
        () => assertRepositoryFormatSupported(2, 1, 0, 'ctx'),
        throwsDotweaveErrorMatching('newer than this CLI supports'),
      );
    });

    test('throws REPO_FORMAT_TOO_OLD when the format is below the floor', () {
      expect(
        () => assertRepositoryFormatSupported(0, 2, 1, 'ctx'),
        throwsDotweaveErrorMatching('older than this CLI supports'),
      );
    });
  });

  group('applyRepositoryFormatMigrations', () {
    test('treats an absent repositoryFormat as format 0', () async {
      var callCount = 0;
      final callArguments = <(String, ResolvedSyncConfig)>[];

      Future<void> step(
        String repositoryDirectory,
        ResolvedSyncConfig config,
      ) async {
        callCount += 1;
        callArguments.add((repositoryDirectory, config));
      }

      final result = await applyRepositoryFormatMigrations(
        '/repo',
        configWithFormat(null),
        registry([(0, step)]),
        1,
        0,
      );

      expect(result.fromFormat, 0);
      expect(result.migrated, isTrue);
      expect(callCount, 1);
      expect(callArguments.single.$1, '/repo');
    });

    test('is a no-op when already at the target format', () async {
      var callCount = 0;

      Future<void> step(
        String repositoryDirectory,
        ResolvedSyncConfig config,
      ) async {
        callCount += 1;
      }

      final result = await applyRepositoryFormatMigrations(
        '/repo',
        configWithFormat(1),
        registry([(0, step)]),
        1,
        0,
      );

      expect(result.fromFormat, 1);
      expect(result.migrated, isFalse);
      expect(callCount, 0);
    });

    test('runs each contiguous step in order up to the target', () async {
      final calls = <int>[];
      final result = await applyRepositoryFormatMigrations(
        '/repo',
        configWithFormat(0),
        registry([
          (0, (_, _) async => calls.add(0)),
          (1, (_, _) async => calls.add(1)),
        ]),
        2,
        0,
      );

      expect(result.fromFormat, 0);
      expect(result.migrated, isTrue);
      expect(calls, [0, 1]);
    });

    test('throws REPO_FORMAT_MIGRATION_NOT_FOUND for a missing step', () async {
      await expectLater(
        applyRepositoryFormatMigrations(
          '/repo',
          configWithFormat(0),
          registry([]),
          1,
          0,
        ),
        throwsDotweaveErrorMatching(
          'No repository format migration found for 0',
        ),
      );
    });

    test(
      'throws REPO_FORMAT_NEWER when the repository is newer than the target',
      () async {
        await expectLater(
          applyRepositoryFormatMigrations(
            '/repo',
            configWithFormat(5),
            registry([]),
            1,
            0,
          ),
          throwsDotweaveErrorMatching('newer than this CLI supports'),
        );
      },
    );

    test('wraps a DotweaveError from a step with migration context', () async {
      final failing = registry([
        (
          0,
          (_, _) async {
            throw DotweaveError('boom', code: 'X');
          },
        ),
      ]);

      await expectLater(
        applyRepositoryFormatMigrations(
          '/repo',
          configWithFormat(0),
          failing,
          1,
          0,
        ),
        throwsDotweaveErrorMatching('boom'),
      );
    });

    test(
      'wraps a non-DotweaveError from a step as REPO_FORMAT_MIGRATION_FAILED',
      () async {
        final failing = registry([
          (
            0,
            (_, _) async {
              throw Exception('raw failure');
            },
          ),
        ]);

        await expectLater(
          applyRepositoryFormatMigrations(
            '/repo',
            configWithFormat(0),
            failing,
            1,
            0,
          ),
          throwsDotweaveErrorMatching('Failed to migrate repository format 0'),
        );
      },
    );
  });
}
