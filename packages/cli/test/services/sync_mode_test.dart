import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/services/sync_mode.dart';
import 'package:test/test.dart';

String nativePath(String value) {
  return Platform.isWindows ? 'C:${value.replaceAll('/', r'\')}' : value;
}

SyncConfigResolutionContext mockResolutionContext() {
  return SyncConfigResolutionContext(
    homeDirectory: Platform.isWindows ? r'C:\tmp\home' : '/tmp/home',
    platformKey: PlatformKey.linux,
    readEnv: (name) => null,
    xdgConfigHome: Platform.isWindows
        ? r'C:\tmp\home\.config'
        : '/tmp/home/.config',
  );
}

/// Stands in for the vitest `vi.hoisted` mock registry: mutable seams with
/// the same default behaviors, plus recorded calls for the spied config-file
/// writers.
class MockedSyncModeSeams {
  MockedSyncModeSeams();

  final List<ResolvedSyncConfig> buildSyncConfigDocumentCalls = [];
  final List<(String, RawSyncConfig)> writeValidatedSyncConfigCalls = [];

  PlatformSyncMode Function(SyncMode mode) buildDefaultPlatformMode = (mode) =>
      PlatformSyncMode(defaultValue: mode);
  PlatformStringValue Function(String repoPath) buildConfiguredHomeLocalPath =
      (repoPath) => PlatformStringValue(defaultValue: '~/$repoPath');
  String Function(String absolutePath, String rootPath, String description)
  buildRepoPathWithinRoot = (absolutePath, rootPath, description) =>
      throw StateError('buildRepoPathWithinRoot was not mocked');
  Future<void> Function(String syncDirectory) requireGitRepository =
      (syncDirectory) =>
          throw StateError('requireGitRepository was not mocked');
  String Function(String value, String? home) expandHomePath = (value, home) =>
      throw StateError('expandHomePath was not mocked');
  ResolvedSyncConfigEntry? Function(ResolvedSyncConfig config, String repoPath)
  findOwningSyncEntry = (config, repoPath) => null;
  Future<PathStats?> Function(String path) getPathStats = (path) async => null;
  bool Function(PlatformSyncMode configuredMode)
  hasPlatformSpecificModeOverride = (configuredMode) => false;
  bool Function(String target) isExplicitLocalPath = (target) => false;
  String Function(String value) normalizeSyncRepoPath = (value) => value;
  Future<ResolvedSyncConfig> Function(
    String syncDirectory,
    SyncConfigResolutionContext context,
  )
  readSyncConfig = (syncDirectory, context) =>
      throw StateError('readSyncConfig was not mocked');
  String? Function(ResolvedSyncConfigEntry entry, String repoPath)
  resolveEntryRelativeRepoPath = (entry, repoPath) => null;
  SyncConfigResolutionContext Function() resolveSyncConfigResolutionContext =
      mockResolutionContext;
  SyncPaths Function() resolveSyncPaths = () => const SyncPaths(
    configPath: '/tmp/dotweave/manifest.jsonc',
    globalConfigPath: '/tmp/home/.config/dotweave/settings.jsonc',
    homeDirectory: '/tmp/home',
    syncDirectory: '/tmp/dotweave',
  );
  String? Function(String absolutePath, String rootPath, String description)
  tryBuildRepoPathWithinRoot = (absolutePath, rootPath, description) => null;
  String? Function(String value) tryNormalizeRepoPathInput = (value) => null;

  RawSyncConfig buildSyncConfigDocument(ResolvedSyncConfig config) {
    buildSyncConfigDocumentCalls.add(config);
    return const RawSyncConfig(version: 8, profiles: [], entries: []);
  }

  Future<void> writeValidatedSyncConfig(
    String syncDirectory,
    RawSyncConfig config,
  ) async {
    writeValidatedSyncConfigCalls.add((syncDirectory, config));
  }

  /// Mirrors the vitest `./sync-context.ts` module mock, wiring the seams
  /// into a hand-built `loadWritableSyncConfig`.
  Future<WritableSyncConfig> loadWritableSyncConfig() async {
    final paths = resolveSyncPaths();
    await requireGitRepository(paths.syncDirectory);
    final config = await readSyncConfig(
      paths.syncDirectory,
      resolveSyncConfigResolutionContext(),
    );
    return WritableSyncConfig(
      config: config,
      configPath: paths.configPath,
      context: resolveSyncConfigResolutionContext(),
      syncDirectory: paths.syncDirectory,
    );
  }

  SyncModeDependencies get dependencies {
    return SyncModeDependencies(
      buildConfiguredHomeLocalPath: (repoPath) =>
          buildConfiguredHomeLocalPath(repoPath),
      buildDefaultPlatformMode: (mode) => buildDefaultPlatformMode(mode),
      buildRepoPathWithinRoot: (absolutePath, rootPath, description) =>
          buildRepoPathWithinRoot(absolutePath, rootPath, description),
      buildSyncConfigDocument: buildSyncConfigDocument,
      expandHomePath: (value, home) => expandHomePath(value, home),
      findOwningSyncEntry: (config, repoPath) =>
          findOwningSyncEntry(config, repoPath),
      getPathStats: (path) => getPathStats(path),
      hasPlatformSpecificModeOverride: (configuredMode) =>
          hasPlatformSpecificModeOverride(configuredMode),
      isExplicitLocalPath: (target) => isExplicitLocalPath(target),
      loadWritableSyncConfig: loadWritableSyncConfig,
      normalizeSyncRepoPath: (value) => normalizeSyncRepoPath(value),
      resolveEntryRelativeRepoPath: (entry, repoPath) =>
          resolveEntryRelativeRepoPath(entry, repoPath),
      tryBuildRepoPathWithinRoot: (absolutePath, rootPath, description) =>
          tryBuildRepoPathWithinRoot(absolutePath, rootPath, description),
      tryNormalizeRepoPathInput: (value) => tryNormalizeRepoPathInput(value),
      writeValidatedSyncConfig: writeValidatedSyncConfig,
    );
  }
}

ResolvedSyncConfig createConfig(List<ResolvedSyncConfigEntry> entries) {
  return ResolvedSyncConfig(entries: [...entries], version: 7);
}

ResolvedSyncConfigEntry directoryEntry({
  PlatformStringValue? configuredLocalPath,
  PlatformSyncMode? configuredMode,
  ConfiguredSyncRepoPath? configuredRepoPath,
  String? kind,
  String? localPath,
  String? mode,
  bool? modeExplicit,
  bool? permissionExplicit,
  List<String>? profiles,
  bool? profilesExplicit,
  String? repoPath,
}) {
  return ResolvedSyncConfigEntry(
    configuredLocalPath:
        configuredLocalPath ??
        const PlatformStringValue(defaultValue: '~/.config/app'),
    configuredMode:
        configuredMode ?? const PlatformSyncMode(defaultValue: 'normal'),
    configuredRepoPath: configuredRepoPath,
    kind: kind ?? 'directory',
    localPath: localPath ?? nativePath('/tmp/home/.config/app'),
    mode: mode ?? 'normal',
    modeExplicit: modeExplicit ?? false,
    permissionExplicit: permissionExplicit ?? false,
    profiles: profiles ?? const [],
    profilesExplicit: profilesExplicit ?? false,
    repoPath: repoPath ?? '.config/app',
  );
}

ResolvedSyncConfigEntry fileEntry({
  PlatformStringValue? configuredLocalPath,
  PlatformSyncMode? configuredMode,
  ConfiguredSyncRepoPath? configuredRepoPath,
  String? kind,
  String? localPath,
  String? mode,
  bool? modeExplicit,
  bool? permissionExplicit,
  List<String>? profiles,
  bool? profilesExplicit,
  String? repoPath,
}) {
  return ResolvedSyncConfigEntry(
    configuredLocalPath:
        configuredLocalPath ??
        const PlatformStringValue(defaultValue: '~/.gitconfig'),
    configuredMode:
        configuredMode ?? const PlatformSyncMode(defaultValue: 'secret'),
    configuredRepoPath: configuredRepoPath,
    kind: kind ?? 'file',
    localPath: localPath ?? nativePath('/tmp/home/.gitconfig'),
    mode: mode ?? 'secret',
    modeExplicit: modeExplicit ?? true,
    permissionExplicit: permissionExplicit ?? false,
    profiles: profiles ?? const [],
    profilesExplicit: profilesExplicit ?? false,
    repoPath: repoPath ?? '.gitconfig',
  );
}

const PathStats directoryStats = PathStats(
  isFile: false,
  isDirectory: true,
  isSymbolicLink: false,
  mode: 0,
);

const PathStats fileStats = PathStats(
  isFile: true,
  isDirectory: false,
  isSymbolicLink: false,
  mode: 0,
);

void expectEntryFieldsEqual(
  ResolvedSyncConfigEntry actual,
  ResolvedSyncConfigEntry expected,
) {
  expect(actual.configuredLocalPath, expected.configuredLocalPath);
  expect(actual.configuredMode, expected.configuredMode);
  expect(actual.configuredPermission, expected.configuredPermission);
  expect(actual.configuredRepoPath, expected.configuredRepoPath);
  expect(actual.kind, expected.kind);
  expect(actual.localPath, expected.localPath);
  expect(actual.mode, expected.mode);
  expect(actual.modeExplicit, expected.modeExplicit);
  expect(actual.permission, expected.permission);
  expect(actual.permissionExplicit, expected.permissionExplicit);
  expect(actual.profiles, expected.profiles);
  expect(actual.profilesExplicit, expected.profilesExplicit);
  expect(actual.repoPath, expected.repoPath);
}

void main() {
  group('sync set service', () {
    test('rejects blank set targets', () async {
      final mocked = MockedSyncModeSeams();

      await expectLater(
        resolveSetTarget(
          '   ',
          createConfig([]),
          nativePath('/tmp/cwd'),
          nativePath('/tmp/home'),
          mocked.dependencies,
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains('Target path is required.'),
          ),
        ),
      );
    });

    test('rejects missing explicit local targets', () async {
      final mocked = MockedSyncModeSeams();
      mocked.isExplicitLocalPath = (target) => true;
      mocked.expandHomePath = (value, home) =>
          nativePath('/tmp/home/.ssh/id_ed25519');
      mocked.buildRepoPathWithinRoot = (absolutePath, rootPath, description) =>
          '.ssh/id_ed25519';
      mocked.getPathStats = (path) async => null;

      await expectLater(
        resolveSetTarget(
          nativePath('/tmp/home/.ssh/id_ed25519'),
          createConfig([]),
          nativePath('/tmp/cwd'),
          nativePath('/tmp/home'),
          mocked.dependencies,
        ),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('Sync set target does not exist.'),
          ),
        ),
      );
    });

    test('resolves explicit child paths inside tracked directories', () async {
      final mocked = MockedSyncModeSeams();
      final entry = directoryEntry();

      mocked.isExplicitLocalPath = (target) => true;
      mocked.expandHomePath = (value, home) =>
          nativePath('/tmp/home/.config/app/config.json');
      mocked.buildRepoPathWithinRoot = (absolutePath, rootPath, description) =>
          '.config/app/config.json';
      mocked.getPathStats = (path) async => fileStats;
      mocked.findOwningSyncEntry = (config, repoPath) => entry;
      mocked.resolveEntryRelativeRepoPath = (entry, repoPath) => 'config.json';

      await expectLater(
        resolveSetTarget(
          nativePath('/tmp/home/.config/app/config.json'),
          createConfig([entry]),
          nativePath('/tmp/cwd'),
          nativePath('/tmp/home'),
          mocked.dependencies,
        ),
        completion(
          equals((
            entry: entry,
            localPath: nativePath('/tmp/home/.config/app/config.json'),
            relativePath: 'config.json',
            repoPath: '.config/app/config.json',
            stats: fileStats,
          )),
        ),
      );
    });

    test('resolves explicit child paths inside tracked directories with '
        'explicit repo paths', () async {
      final mocked = MockedSyncModeSeams();
      final entry = directoryEntry(
        configuredRepoPath: const PlatformStringValue(
          defaultValue: 'profiles/shared/app',
        ),
        repoPath: 'profiles/shared/app',
      );

      mocked.isExplicitLocalPath = (target) => true;
      mocked.expandHomePath = (value, home) =>
          nativePath('/tmp/home/.config/app/config.json');
      mocked.buildRepoPathWithinRoot = (absolutePath, rootPath, description) =>
          '.config/app/config.json';
      mocked.getPathStats = (path) async => fileStats;
      mocked.findOwningSyncEntry = (config, repoPath) => null;

      await expectLater(
        resolveSetTarget(
          nativePath('/tmp/home/.config/app/config.json'),
          createConfig([entry]),
          nativePath('/tmp/cwd'),
          nativePath('/tmp/home'),
          mocked.dependencies,
        ),
        completion(
          equals((
            entry: entry,
            localPath: nativePath('/tmp/home/.config/app/config.json'),
            relativePath: 'config.json',
            repoPath: 'profiles/shared/app/config.json',
            stats: fileStats,
          )),
        ),
      );
    });

    test(
      'rejects explicit local targets outside tracked directories',
      () async {
        final mocked = MockedSyncModeSeams();
        mocked.isExplicitLocalPath = (target) => true;
        mocked.expandHomePath = (value, home) =>
            nativePath('/tmp/home/.config/other/file');
        mocked.buildRepoPathWithinRoot =
            (absolutePath, rootPath, description) => '.config/other/file';
        mocked.getPathStats = (path) async => fileStats;
        mocked.findOwningSyncEntry = (config, repoPath) => null;

        await expectLater(
          resolveSetTarget(
            nativePath('/tmp/home/.config/other/file'),
            createConfig([directoryEntry()]),
            nativePath('/tmp/cwd'),
            nativePath('/tmp/home'),
            mocked.dependencies,
          ),
          throwsA(
            predicate(
              (error) => error.toString().contains(
                'Local set target is not inside a tracked directory entry.',
              ),
            ),
          ),
        );
      },
    );

    test('rejects invalid repository-style targets', () async {
      final mocked = MockedSyncModeSeams();
      mocked.isExplicitLocalPath = (target) => false;
      mocked.expandHomePath = (value, home) => '../outside';
      mocked.tryBuildRepoPathWithinRoot =
          (absolutePath, rootPath, description) => null;
      mocked.tryNormalizeRepoPathInput = (value) => null;

      await expectLater(
        resolveSetTarget(
          '../outside',
          createConfig([]),
          nativePath('/tmp/cwd'),
          nativePath('/tmp/home'),
          mocked.dependencies,
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              'Sync set target is not a valid local or repository path.',
            ),
          ),
        ),
      );
    });

    test(
      'resolves exact repository entries without changing the local path',
      () async {
        final mocked = MockedSyncModeSeams();
        final entry = fileEntry();

        mocked.isExplicitLocalPath = (target) => false;
        mocked.expandHomePath = (value, home) => '.gitconfig';
        mocked.tryBuildRepoPathWithinRoot =
            (absolutePath, rootPath, description) => null;
        mocked.tryNormalizeRepoPathInput = (value) => '.gitconfig';
        mocked.resolveEntryRelativeRepoPath = (entry, repoPath) => null;
        mocked.getPathStats = (path) async => fileStats;

        await expectLater(
          resolveSetTarget(
            '.gitconfig',
            createConfig([entry]),
            nativePath('/tmp/cwd'),
            nativePath('/tmp/home'),
            mocked.dependencies,
          ),
          completion(
            equals((
              entry: entry,
              localPath: nativePath('/tmp/home/.gitconfig'),
              relativePath: '',
              repoPath: '.gitconfig',
              stats: fileStats,
            )),
          ),
        );
      },
    );

    test(
      'resolves nested repository targets under tracked directories',
      () async {
        final mocked = MockedSyncModeSeams();
        final entry = directoryEntry();

        mocked.isExplicitLocalPath = (target) => false;
        mocked.expandHomePath = (value, home) =>
            '.config/app/nested/config.json';
        mocked.tryBuildRepoPathWithinRoot =
            (absolutePath, rootPath, description) => null;
        mocked.tryNormalizeRepoPathInput = (value) =>
            '.config/app/nested/config.json';
        mocked.findOwningSyncEntry = (config, repoPath) => entry;
        mocked.resolveEntryRelativeRepoPath = (entry, repoPath) =>
            'nested/config.json';
        mocked.getPathStats = (path) async => fileStats;

        await expectLater(
          resolveSetTarget(
            '.config/app/nested/config.json',
            createConfig([entry]),
            nativePath('/tmp/cwd'),
            nativePath('/tmp/home'),
            mocked.dependencies,
          ),
          completion(
            equals((
              entry: entry,
              localPath: nativePath('/tmp/home/.config/app/nested/config.json'),
              relativePath: 'nested/config.json',
              repoPath: '.config/app/nested/config.json',
              stats: fileStats,
            )),
          ),
        );
      },
    );

    test('rejects repository targets that are not tracked', () async {
      final mocked = MockedSyncModeSeams();
      mocked.isExplicitLocalPath = (target) => false;
      mocked.expandHomePath = (value, home) => '.config/other/file';
      mocked.tryBuildRepoPathWithinRoot =
          (absolutePath, rootPath, description) => null;
      mocked.tryNormalizeRepoPathInput = (value) => '.config/other/file';
      mocked.findOwningSyncEntry = (config, repoPath) => null;

      await expectLater(
        resolveSetTarget(
          '.config/other/file',
          createConfig([directoryEntry()]),
          nativePath('/tmp/cwd'),
          nativePath('/tmp/home'),
          mocked.dependencies,
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              'Repository set target is not inside a tracked directory entry.',
            ),
          ),
        ),
      );
    });

    test('returns unchanged for exact entries that already use the requested '
        'mode', () async {
      final mocked = MockedSyncModeSeams();
      final entry = fileEntry();
      final config = createConfig([entry]);

      mocked.requireGitRepository = (syncDirectory) async {};
      mocked.readSyncConfig = (syncDirectory, context) async => config;
      mocked.isExplicitLocalPath = (target) => false;
      mocked.expandHomePath = (value, home) => '.gitconfig';
      mocked.tryBuildRepoPathWithinRoot =
          (absolutePath, rootPath, description) => null;
      mocked.tryNormalizeRepoPathInput = (value) => '.gitconfig';
      mocked.resolveEntryRelativeRepoPath = (entry, repoPath) => null;
      mocked.getPathStats = (path) async => fileStats;

      await expectLater(
        setTargetMode(
          const SetModeRequest(mode: 'secret', target: '.gitconfig'),
          nativePath('/tmp/cwd'),
          mocked.dependencies,
        ),
        completion(
          equals(
            SetModeResult(
              action: 'unchanged',
              entryRepoPath: '.gitconfig',
              localPath: nativePath('/tmp/home/.gitconfig'),
              mode: 'secret',
              repoPath: '.gitconfig',
            ),
          ),
        ),
      );
      expect(mocked.writeValidatedSyncConfigCalls, isEmpty);
    });

    test('rewrites exact entries when platform-specific overrides should be '
        'cleared', () async {
      final mocked = MockedSyncModeSeams();
      final entry = fileEntry(
        configuredMode: const PlatformSyncMode(
          defaultValue: 'secret',
          linux: 'ignore',
        ),
      );
      final config = createConfig([entry]);

      mocked.requireGitRepository = (syncDirectory) async {};
      mocked.readSyncConfig = (syncDirectory, context) async => config;
      mocked.isExplicitLocalPath = (target) => false;
      mocked.expandHomePath = (value, home) => '.gitconfig';
      mocked.tryBuildRepoPathWithinRoot =
          (absolutePath, rootPath, description) => null;
      mocked.tryNormalizeRepoPathInput = (value) => '.gitconfig';
      mocked.resolveEntryRelativeRepoPath = (entry, repoPath) => null;
      mocked.getPathStats = (path) async => fileStats;
      mocked.hasPlatformSpecificModeOverride = (configuredMode) => true;

      final result = await setTargetMode(
        const SetModeRequest(mode: 'secret', target: '.gitconfig'),
        nativePath('/tmp/cwd'),
        mocked.dependencies,
      );

      expect(result.action, 'updated');
      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.age, config.age);
      expect(document.profiles, config.profiles);
      expect(document.repositoryFormat, config.repositoryFormat);
      expect(document.version, config.version);
      expect(document.entries, hasLength(1));
      expectEntryFieldsEqual(
        document.entries.single,
        fileEntry(
          configuredMode: const PlatformSyncMode(defaultValue: 'secret'),
          mode: 'secret',
        ),
      );
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
    });

    test(
      'adds a child override when a nested target needs a different mode',
      () async {
        final mocked = MockedSyncModeSeams();
        final entry = directoryEntry();
        final config = createConfig([entry]);

        mocked.requireGitRepository = (syncDirectory) async {};
        mocked.readSyncConfig = (syncDirectory, context) async => config;
        mocked.isExplicitLocalPath = (target) => false;
        mocked.expandHomePath = (value, home) => '.config/app/private.txt';
        mocked.tryBuildRepoPathWithinRoot =
            (absolutePath, rootPath, description) => null;
        mocked.tryNormalizeRepoPathInput = (value) => '.config/app/private.txt';
        mocked.findOwningSyncEntry = (config, repoPath) => entry;
        mocked.resolveEntryRelativeRepoPath = (entry, repoPath) =>
            'private.txt';
        mocked.getPathStats = (path) async => fileStats;

        final result = await setTargetMode(
          const SetModeRequest(
            mode: 'secret',
            target: '.config/app/private.txt',
          ),
          nativePath('/tmp/cwd'),
          mocked.dependencies,
        );

        expect(
          result,
          equals(
            SetModeResult(
              action: 'added',
              entryRepoPath: '.config/app',
              localPath: nativePath('/tmp/home/.config/app/private.txt'),
              mode: 'secret',
              repoPath: '.config/app/private.txt',
            ),
          ),
        );
        expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
        final document = mocked.buildSyncConfigDocumentCalls.single;
        expect(document.age, config.age);
        expect(document.profiles, config.profiles);
        expect(document.repositoryFormat, config.repositoryFormat);
        expect(document.version, config.version);
        expect(document.entries, hasLength(2));
        expect(document.entries[0], same(entry));
        expectEntryFieldsEqual(
          document.entries[1],
          ResolvedSyncConfigEntry(
            configuredLocalPath: const PlatformStringValue(
              defaultValue: '~/.config/app/private.txt',
            ),
            configuredMode: const PlatformSyncMode(defaultValue: 'secret'),
            kind: 'file',
            localPath: nativePath('/tmp/home/.config/app/private.txt'),
            mode: 'secret',
            modeExplicit: true,
            permissionExplicit: false,
            profiles: const [],
            profilesExplicit: false,
            repoPath: '.config/app/private.txt',
          ),
        );
      },
    );

    test(
      'keeps nested targets unchanged when they inherit the parent mode',
      () async {
        final mocked = MockedSyncModeSeams();
        final entry = directoryEntry();
        final config = createConfig([entry]);

        mocked.requireGitRepository = (syncDirectory) async {};
        mocked.readSyncConfig = (syncDirectory, context) async => config;
        mocked.isExplicitLocalPath = (target) => false;
        mocked.expandHomePath = (value, home) => '.config/app/notes.txt';
        mocked.tryBuildRepoPathWithinRoot =
            (absolutePath, rootPath, description) => null;
        mocked.tryNormalizeRepoPathInput = (value) => '.config/app/notes.txt';
        mocked.findOwningSyncEntry = (config, repoPath) => entry;
        mocked.resolveEntryRelativeRepoPath = (entry, repoPath) => 'notes.txt';
        mocked.getPathStats = (path) async => directoryStats;

        await expectLater(
          setTargetMode(
            const SetModeRequest(
              mode: 'normal',
              target: '.config/app/notes.txt',
            ),
            nativePath('/tmp/cwd'),
            mocked.dependencies,
          ),
          completion(
            equals(
              SetModeResult(
                action: 'unchanged',
                entryRepoPath: '.config/app',
                localPath: nativePath('/tmp/home/.config/app/notes.txt'),
                mode: 'normal',
                repoPath: '.config/app/notes.txt',
              ),
            ),
          ),
        );
        expect(mocked.writeValidatedSyncConfigCalls, isEmpty);
      },
    );
  });
}
