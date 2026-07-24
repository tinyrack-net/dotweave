import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/migration.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  Directory? tempDir;

  tearDown(() async {
    await tempDir?.delete(recursive: true);
    tempDir = null;
  });

  Future<String> createTempFile(Object? content) async {
    tempDir ??= await Directory.systemTemp.createTemp(
      'dotweave-migration-test-',
    );
    final filePath = p.join(tempDir!.path, 'config.json');
    await File(
      filePath,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(content));
    return filePath;
  }

  ConfigMigrationRegistry makeRegistry(List<(int, ConfigMigrationFn)> entries) {
    return {for (final (version, fn) in entries) version: fn};
  }

  group('runConfigMigrations', () {
    test(
      'returns the original config unchanged when version matches target',
      () async {
        final config = <String, Object?>{'version': 7, 'entries': <Object?>[]};
        final filePath = await createTempFile(config);

        final result = await runConfigMigrations(
          config,
          makeRegistry([]),
          7,
          filePath,
        );

        expect(result, equals(config));
      },
    );

    test(
      'returns non-object input unchanged (delegates to Zod validation)',
      () async {
        final filePath = await createTempFile(null);
        final result = await runConfigMigrations(
          null,
          makeRegistry([]),
          7,
          filePath,
        );
        expect(result, isNull);
      },
    );

    test('returns config unchanged when version field is missing', () async {
      final config = <String, Object?>{'entries': <Object?>[]};
      final filePath = await createTempFile(config);
      final result = await runConfigMigrations(
        config,
        makeRegistry([]),
        7,
        filePath,
      );
      expect(result, equals(config));
    });

    test(
      'returns config unchanged when version field is not a number',
      () async {
        final config = <String, Object?>{
          'version': '7',
          'entries': <Object?>[],
        };
        final filePath = await createTempFile(config);
        final result = await runConfigMigrations(
          config,
          makeRegistry([]),
          7,
          filePath,
        );
        expect(result, equals(config));
      },
    );

    test(
      'throws CONFIG_NEWER_VERSION when config version exceeds target',
      () async {
        final config = <String, Object?>{'version': 9, 'entries': <Object?>[]};
        final filePath = await createTempFile(config);

        await expectLater(
          runConfigMigrations(config, makeRegistry([]), 7, filePath),
          throwsA(
            isA<DotweaveError>().having(
              (error) => error.code,
              'code',
              'CONFIG_NEWER_VERSION',
            ),
          ),
        );
      },
    );

    test('applies a single migration step', () async {
      final config = <String, Object?>{
        'version': 2,
        'activeProfile': 'work',
        'age': {'key': 'x'},
      };
      final filePath = await createTempFile(config);

      Map<String, Object?> migrateFn(Map<String, Object?> c) {
        return {
          for (final entry in c.entries)
            if (entry.key != 'age') entry.key: entry.value,
          'version': 3,
        };
      }

      final result = await runConfigMigrations(
        config,
        makeRegistry([(2, migrateFn)]),
        3,
        filePath,
      );

      expect(result, equals({'version': 3, 'activeProfile': 'work'}));
    });

    test('applies multiple migration steps in sequence', () async {
      final config = <String, Object?>{'version': 1, 'value': 'a'};
      final filePath = await createTempFile(config);

      final registry = makeRegistry([
        (1, (c) => {...c, 'version': 2, 'step1': true}),
        (2, (c) => {...c, 'version': 3, 'step2': true}),
      ]);

      final result = await runConfigMigrations(config, registry, 3, filePath);

      expect(
        result,
        equals({'version': 3, 'value': 'a', 'step1': true, 'step2': true}),
      );
    });

    test('creates a backup file before migration', () async {
      final config = <String, Object?>{'version': 2, 'data': 'original'};
      final filePath = await createTempFile(config);

      await runConfigMigrations(
        config,
        makeRegistry([
          (2, (c) => {...c, 'version': 3}),
        ]),
        3,
        filePath,
      );

      final backupContent = await File('$filePath.v2.bak').readAsString();
      final backup = jsonDecode(backupContent);
      expect(backup, equals(config));
    });

    test(
      'backup contains original config even after multi-step migration',
      () async {
        final config = <String, Object?>{'version': 1, 'original': true};
        final filePath = await createTempFile(config);

        final registry = makeRegistry([
          (1, (c) => {...c, 'version': 2}),
          (2, (c) => {...c, 'version': 3}),
        ]);

        await runConfigMigrations(config, registry, 3, filePath);

        final backupContent = await File('$filePath.v1.bak').readAsString();
        final backup = jsonDecode(backupContent);
        expect(backup, equals(config));
      },
    );

    test('saves the migrated config to the file', () async {
      final config = <String, Object?>{'version': 2, 'name': 'test'};
      final filePath = await createTempFile(config);

      await runConfigMigrations(
        config,
        makeRegistry([
          (2, (c) => {...c, 'version': 3}),
        ]),
        3,
        filePath,
      );

      final saved = jsonDecode(await File(filePath).readAsString());
      expect(saved, equals({'version': 3, 'name': 'test'}));
    });

    test('throws CONFIG_MIGRATION_NOT_FOUND when registry has a gap', () async {
      final config = <String, Object?>{'version': 1};
      final filePath = await createTempFile(config);

      await expectLater(
        runConfigMigrations(config, makeRegistry([]), 3, filePath),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.code,
            'code',
            'CONFIG_MIGRATION_NOT_FOUND',
          ),
        ),
      );
    });

    test(
      'throws CONFIG_MIGRATION_FAILED when a migration function throws',
      () async {
        final config = <String, Object?>{'version': 2};
        final filePath = await createTempFile(config);

        Map<String, Object?> brokenFn(Map<String, Object?> c) {
          throw Exception('migration exploded');
        }

        await expectLater(
          runConfigMigrations(
            config,
            makeRegistry([(2, brokenFn)]),
            3,
            filePath,
          ),
          throwsA(
            isA<DotweaveError>().having(
              (error) => error.code,
              'code',
              'CONFIG_MIGRATION_FAILED',
            ),
          ),
        );
      },
    );

    test(
      'preserves DotweaveError details thrown by migration functions',
      () async {
        final config = <String, Object?>{'version': 2};
        final filePath = await createTempFile(config);

        Map<String, Object?> brokenFn(Map<String, Object?> c) {
          throw DotweaveError(
            'Profile name must be a string.',
            code: 'INVALID_PROFILE_NAME',
            hint: 'Fix the profile value.',
          );
        }

        Object? error;
        try {
          await runConfigMigrations(
            config,
            makeRegistry([(2, brokenFn)]),
            3,
            filePath,
          );
        } catch (caught) {
          error = caught;
        }

        expect(error, isA<DotweaveError>());
        final dotweaveError = error as DotweaveError;
        expect(dotweaveError.code, 'INVALID_PROFILE_NAME');
        expect(dotweaveError.hint, 'Fix the profile value.');
        expect(
          dotweaveError.details,
          containsAll(['Config file: $filePath', 'Migration: 2 → 3']),
        );
      },
    );

    test('throws a DotweaveError instance for all error cases', () async {
      final config = <String, Object?>{'version': 9};
      final filePath = await createTempFile(config);

      Object? error;
      try {
        await runConfigMigrations(config, makeRegistry([]), 7, filePath);
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<DotweaveError>());
    });
  });
}
