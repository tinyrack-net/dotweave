import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:test/test.dart';

const SyncPaths mockResolveSyncPaths = SyncPaths(
  configPath: '/tmp/dotweave-sync/manifest.jsonc',
  globalConfigPath: '/home/test/.config/dotweave/settings.jsonc',
  homeDirectory: '/home/test',
  syncDirectory: '/tmp/dotweave-sync',
);

final SyncConfigResolutionContext mockContext = SyncConfigResolutionContext(
  homeDirectory: '/home/test',
  platformKey: PlatformKey.linux,
  readEnv: (name) => null,
  xdgConfigHome: '/home/test/.config',
);

/// Stands in for the vitest module mocks: overrides the path/context
/// resolvers and the git/read seams used by `loadWritableSyncConfig`.
SyncContextDependencies mockDependencies({
  Future<ResolvedSyncConfig> Function(
    String syncDirectory,
    SyncConfigResolutionContext context,
  )?
  readSyncConfig,
  Future<void> Function(String syncDirectory)? requireGitRepository,
}) {
  return SyncContextDependencies(
    readSyncConfig: readSyncConfig,
    requireGitRepository: requireGitRepository,
    resolveSyncConfigResolutionContext: () => mockContext,
    resolveSyncPaths: () => mockResolveSyncPaths,
  );
}

void main() {
  group('sync-context (loadWritableSyncConfig)', () {
    test('returns a mutable sync config on the happy path', () async {
      const mockConfig = ResolvedSyncConfig(entries: [], version: 7);

      final result = await loadWritableSyncConfig(
        mockDependencies(
          readSyncConfig: (syncDirectory, context) async => mockConfig,
          requireGitRepository: (syncDirectory) async {},
        ),
      );

      expect(result.config, same(mockConfig));
      expect(result.configPath, mockResolveSyncPaths.configPath);
      expect(result.context, same(mockContext));
      expect(result.syncDirectory, mockResolveSyncPaths.syncDirectory);
    });

    test('propagates errors from requireGitRepository', () async {
      final error = Exception('not a git repo');

      await expectLater(
        loadWritableSyncConfig(
          mockDependencies(
            readSyncConfig: (syncDirectory, context) async =>
                const ResolvedSyncConfig(entries: [], version: 7),
            requireGitRepository: (syncDirectory) async => throw error,
          ),
        ),
        throwsA(predicate((e) => e.toString().contains('not a git repo'))),
      );
    });

    test('propagates errors from readSyncConfig', () async {
      final error = Exception('invalid config');

      await expectLater(
        loadWritableSyncConfig(
          mockDependencies(
            readSyncConfig: (syncDirectory, context) async => throw error,
            requireGitRepository: (syncDirectory) async {},
          ),
        ),
        throwsA(predicate((e) => e.toString().contains('invalid config'))),
      );
    });

    test('loadWritableSyncConfig resolves context and paths', () async {
      const mockConfig = ResolvedSyncConfig(entries: [], version: 7);

      final result = await loadWritableSyncConfig(
        mockDependencies(
          readSyncConfig: (syncDirectory, context) async => mockConfig,
          requireGitRepository: (syncDirectory) async {},
        ),
      );

      expect(result.context, same(mockContext));
      expect(result.syncDirectory, mockResolveSyncPaths.syncDirectory);
      expect(result.configPath, mockResolveSyncPaths.configPath);
    });

    test(
      'loadWritableSyncConfig returns the parsed config from readSyncConfig',
      () async {
        const mockConfig = ResolvedSyncConfig(entries: [], version: 7);

        final result = await loadWritableSyncConfig(
          mockDependencies(
            readSyncConfig: (syncDirectory, context) async => mockConfig,
            requireGitRepository: (syncDirectory) async {},
          ),
        );

        expect(result.config, same(mockConfig));
      },
    );
  });
}
