import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/services/track.dart';
import 'package:test/test.dart';

String userPath(String posixPath) {
  return Platform.isWindows
      ? 'C:${posixPath.replaceAll('/', r'\')}'
      : posixPath;
}

const PathStats fileStats = PathStats(
  isFile: true,
  isDirectory: false,
  isSymbolicLink: false,
  mode: 0,
);

const PathStats directoryStats = PathStats(
  isFile: false,
  isDirectory: true,
  isSymbolicLink: false,
  mode: 0,
);

const PathStats symlinkStats = PathStats(
  isFile: false,
  isDirectory: false,
  isSymbolicLink: true,
  mode: 0,
);

const PathStats socketStats = PathStats(
  isFile: false,
  isDirectory: false,
  isSymbolicLink: false,
  mode: 0,
);

/// Stands in for the vitest `vi.hoisted` mock registry: mutable seams with
/// the same default behaviors, plus recorded calls for the spied config-file
/// writers.
class MockedTrackSeams {
  MockedTrackSeams();

  final String bashrcPath = userPath('/home/user/.bashrc');
  final String homeDirectory = userPath('/home/user');

  final List<ResolvedSyncConfig> buildSyncConfigDocumentCalls = [];
  final List<(String, RawSyncConfig)> writeValidatedSyncConfigCalls = [];

  Future<PathStats?> Function(String path) getPathStats = (path) async => null;
  Future<void> Function(String syncDirectory) requireGitRepository =
      (syncDirectory) async {};
  Future<ResolvedSyncConfig> Function(
    String syncDirectory,
    SyncConfigResolutionContext context,
  )
  readSyncConfig = (syncDirectory, context) =>
      throw StateError('readSyncConfig was not mocked');
  PlatformSyncMode Function(SyncMode mode) buildDefaultPlatformMode = (mode) =>
      PlatformSyncMode(defaultValue: mode);
  bool Function(String leftPath, String rightPath) doPathsOverlap =
      (leftPath, rightPath) => false;
  String Function(String value) normalizeSyncProfileName = (value) => value;
  String Function(String value) normalizeSyncRepoPath = (value) => value;
  String Function(String dotweaveHomeDirectory) resolveDefaultIdentityFile =
      (dotweaveHomeDirectory) => userPath('/home/user/.ssh/id_rsa');
  String Function() resolveDotweaveHomeDirectory = () =>
      '/home/user/.config/dotweave';

  late String Function(String absolutePath, String rootPath, String description)
  buildRepoPathWithinRoot = (absolutePath, rootPath, description) =>
      absolutePath.substring(rootPath.length + 1).replaceAll(r'\', '/');
  PlatformStringValue Function(String repoPath) buildConfiguredHomeLocalPath =
      (repoPath) => PlatformStringValue(defaultValue: '~/$repoPath');

  String? readEnvValue(String key) {
    if (key == 'HOME') {
      return userPath('/home/user');
    }
    if (key == 'XDG_CONFIG_HOME') {
      return userPath('/home/user/.config');
    }
    return null;
  }

  SyncPaths resolveSyncPaths() {
    return const SyncPaths(
      configPath: '/tmp/dotweave/manifest.jsonc',
      globalConfigPath: '/tmp/dotweave/settings.jsonc',
      homeDirectory: '/tmp/dotweave',
      syncDirectory: '/tmp/dotweave',
    );
  }

  SyncConfigResolutionContext resolveSyncConfigResolutionContext() {
    return SyncConfigResolutionContext(
      homeDirectory: homeDirectory,
      platformKey: 'linux',
      readEnv: readEnvValue,
      xdgConfigHome: userPath('/home/user/.config'),
    );
  }

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

  TrackDependencies get dependencies {
    return TrackDependencies(
      buildConfiguredHomeLocalPath: (repoPath) =>
          buildConfiguredHomeLocalPath(repoPath),
      buildDefaultPlatformMode: (mode) => buildDefaultPlatformMode(mode),
      buildRepoPathWithinRoot: (absolutePath, rootPath, description) =>
          buildRepoPathWithinRoot(absolutePath, rootPath, description),
      buildSyncConfigDocument: buildSyncConfigDocument,
      doPathsOverlap: (leftPath, rightPath) =>
          doPathsOverlap(leftPath, rightPath),
      getPathStats: (path) => getPathStats(path),
      loadWritableSyncConfig: loadWritableSyncConfig,
      normalizeSyncProfileName: (value) => normalizeSyncProfileName(value),
      normalizeSyncRepoPath: (value) => normalizeSyncRepoPath(value),
      resolveDefaultIdentityFile: (dotweaveHomeDirectory) =>
          resolveDefaultIdentityFile(dotweaveHomeDirectory),
      resolveDotweaveHomeDirectoryFromEnv: () => resolveDotweaveHomeDirectory(),
      writeValidatedSyncConfig: writeValidatedSyncConfig,
    );
  }
}

/// Builds the resolved-config stand-in for the TS `readSyncConfig` mock
/// results (`{entries, age, profiles?}`).
ResolvedSyncConfig mockSyncConfig({
  List<ResolvedSyncConfigEntry> entries = const [],
  AgeConfig? age = const AgeConfig(recipients: []),
  List<String>? profiles,
}) {
  return ResolvedSyncConfig(
    entries: entries,
    age: age,
    profiles: profiles,
    version: 8,
  );
}

/// Builds a resolved entry mirroring the partial entry literals used by the
/// TS test. The TS entries omit `repoPath`/`configuredLocalPath` and the
/// explicit flags; the Dart schema requires them, so callers supply a
/// `repoPath` consistent with the mocked `buildRepoPathWithinRoot` output.
ResolvedSyncConfigEntry mockEntry({
  required String localPath,
  SyncConfigEntryKind kind = 'file',
  SyncMode mode = 'normal',
  List<String> profiles = const [],
  PlatformSyncMode configuredMode = const PlatformSyncMode(
    defaultValue: 'normal',
  ),
  required String repoPath,
  ConfiguredSyncRepoPath? configuredRepoPath,
  PlatformPermission? configuredPermission,
  int? permission,
  bool permissionExplicit = false,
}) {
  return ResolvedSyncConfigEntry(
    configuredLocalPath: PlatformStringValue(defaultValue: '~/$repoPath'),
    configuredMode: configuredMode,
    configuredPermission: configuredPermission,
    configuredRepoPath: configuredRepoPath,
    kind: kind,
    localPath: localPath,
    profiles: profiles,
    profilesExplicit: false,
    mode: mode,
    modeExplicit: false,
    permission: permission,
    permissionExplicit: permissionExplicit,
    repoPath: repoPath,
  );
}

void main() {
  group('track service', () {
    late MockedTrackSeams mocked;

    setUp(() {
      mocked = MockedTrackSeams();
    });

    test('successfully tracks a new file', () async {
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig(profiles: const ['work', 'personal']);

      final result = await trackTarget(
        TrackRequest(
          target: mocked.bashrcPath,
          mode: const TrackModeValue('normal'),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, false);
      expect(result.changed, true);
      expect(result.localPath, mocked.bashrcPath);
      expect(mocked.writeValidatedSyncConfigCalls, isNotEmpty);
    });

    test(
      'throws TARGET_KIND_REQUIRED for missing target without kind',
      () async {
        mocked.getPathStats = (path) async => null;
        mocked.readSyncConfig = (syncDirectory, context) async =>
            mockSyncConfig();

        DotweaveError? thrownError;

        try {
          await trackTarget(
            TrackRequest(
              target: userPath('/home/user/missing'),
              mode: const TrackModeValue('normal'),
            ),
            mocked.homeDirectory,
            mocked.dependencies,
          );
        } on DotweaveError catch (error) {
          thrownError = error;
        }

        expect(thrownError, isA<DotweaveError>());
        expect(thrownError?.code, 'TARGET_KIND_REQUIRED');
      },
    );

    test('tracks a missing target as a file when kind is explicit', () async {
      final missingPath = userPath('/home/user/future.toml');
      mocked.getPathStats = (path) async => null;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      final result = await trackTarget(
        TrackRequest(
          target: missingPath,
          mode: const TrackModeValue('normal'),
          kind: 'file',
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, false);
      expect(result.changed, true);
      expect(result.kind, 'file');
      expect(result.localPath, missingPath);
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(document.entries.single.kind, 'file');
    });

    test(
      'tracks a missing target as a directory when kind is explicit',
      () async {
        final missingPath = userPath('/home/user/.config/future');
        mocked.getPathStats = (path) async => null;
        mocked.readSyncConfig = (syncDirectory, context) async =>
            mockSyncConfig();

        final result = await trackTarget(
          TrackRequest(
            target: missingPath,
            mode: const TrackModeValue('normal'),
            kind: 'directory',
          ),
          mocked.homeDirectory,
          mocked.dependencies,
        );

        expect(result.alreadyTracked, false);
        expect(result.changed, true);
        expect(result.kind, 'directory');
        expect(result.localPath, missingPath);
        expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
        expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
        final document = mocked.buildSyncConfigDocumentCalls.single;
        expect(document.entries, hasLength(1));
        expect(document.entries.single.kind, 'directory');
      },
    );

    test('throws TARGET_KIND_MISMATCH when an existing file is requested as a '
        'directory', () async {
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      DotweaveError? thrownError;

      try {
        await trackTarget(
          TrackRequest(
            target: mocked.bashrcPath,
            mode: const TrackModeValue('normal'),
            kind: 'directory',
          ),
          mocked.homeDirectory,
          mocked.dependencies,
        );
      } on DotweaveError catch (error) {
        thrownError = error;
      }

      expect(thrownError, isA<DotweaveError>());
      expect(thrownError?.code, 'TARGET_KIND_MISMATCH');
    });

    test('throws TARGET_KIND_MISMATCH when an existing directory is requested '
        'as a file', () async {
      final dirPath = userPath('/home/user/.config/app');
      mocked.getPathStats = (path) async => directoryStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      DotweaveError? thrownError;

      try {
        await trackTarget(
          TrackRequest(
            target: dirPath,
            mode: const TrackModeValue('normal'),
            kind: 'file',
          ),
          mocked.homeDirectory,
          mocked.dependencies,
        );
      } on DotweaveError catch (error) {
        thrownError = error;
      }

      expect(thrownError, isA<DotweaveError>());
      expect(thrownError?.code, 'TARGET_KIND_MISMATCH');
    });

    test('detects when a target is already tracked', () async {
      final localPath = mocked.bashrcPath;
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async => mockSyncConfig(
        entries: [mockEntry(localPath: localPath, repoPath: '.bashrc')],
      );

      final result = await trackTarget(
        TrackRequest(target: localPath, mode: const TrackModeValue('normal')),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, true);
      expect(result.changed, false);
    });

    test('updates existing entry if mode changes', () async {
      final localPath = mocked.bashrcPath;
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async => mockSyncConfig(
        entries: [mockEntry(localPath: localPath, repoPath: '.bashrc')],
      );

      final result = await trackTarget(
        TrackRequest(target: localPath, mode: const TrackModeValue('secret')),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, true);
      expect(result.changed, true);
      expect(result.mode, 'secret');
    });

    test('tracks a new file with explicit permission', () async {
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig(profiles: const ['work', 'personal']);

      final result = await trackTarget(
        TrackRequest(
          target: mocked.bashrcPath,
          mode: const TrackModeValue('normal'),
          permission: const PlatformPermission(defaultValue: '0600'),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(
        result.configuredPermission,
        const PlatformPermission(defaultValue: '0600'),
      );
      expect(result.permission, 384); // 0o600
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(
        document.entries.single.configuredPermission,
        const PlatformPermission(defaultValue: '0600'),
      );
      expect(document.entries.single.permission, 384); // 0o600
      expect(document.entries.single.permissionExplicit, true);
    });

    test('updates existing entry permission when requested', () async {
      final localPath = mocked.bashrcPath;
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async => mockSyncConfig(
        entries: [
          mockEntry(
            localPath: localPath,
            repoPath: '.bashrc',
            configuredPermission: const PlatformPermission(
              defaultValue: '0644',
            ),
            permission: 420, // 0o644
            permissionExplicit: true,
          ),
        ],
      );

      final result = await trackTarget(
        TrackRequest(
          target: localPath,
          mode: const TrackModeValue('normal'),
          permission: const PlatformPermission(defaultValue: '0600'),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, true);
      expect(result.changed, true);
      expect(
        result.configuredPermission,
        const PlatformPermission(defaultValue: '0600'),
      );
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(
        document.entries.single.configuredPermission,
        const PlatformPermission(defaultValue: '0600'),
      );
      expect(document.entries.single.permission, 384); // 0o600
      expect(document.entries.single.permissionExplicit, true);
    });

    test('preserves existing permission when permission is omitted', () async {
      final localPath = mocked.bashrcPath;
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async => mockSyncConfig(
        entries: [
          mockEntry(
            localPath: localPath,
            repoPath: '.bashrc',
            configuredPermission: const PlatformPermission(
              defaultValue: '0600',
            ),
            permission: 384, // 0o600
            permissionExplicit: true,
          ),
        ],
      );

      final result = await trackTarget(
        TrackRequest(target: localPath, mode: const TrackModeValue('normal')),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, true);
      expect(result.changed, false);
      expect(
        result.configuredPermission,
        const PlatformPermission(defaultValue: '0600'),
      );
      expect(mocked.writeValidatedSyncConfigCalls, isEmpty);
    });

    test('successfully tracks a new directory', () async {
      final dirPath = userPath('/home/user/.config/app');
      mocked.getPathStats = (path) async => directoryStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig(profiles: const ['work', 'personal']);

      final result = await trackTarget(
        TrackRequest(target: dirPath, mode: const TrackModeValue('normal')),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, false);
      expect(result.changed, true);
      expect(result.kind, 'directory');
      expect(result.localPath, dirPath);
      expect(mocked.writeValidatedSyncConfigCalls, isNotEmpty);
    });

    test('successfully tracks a symlink as a file entry', () async {
      final linkPath = userPath('/home/user/.local/bin/app');
      mocked.getPathStats = (path) async => symlinkStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      final result = await trackTarget(
        TrackRequest(
          target: linkPath,
          mode: const TrackModeValue('normal'),
          kind: 'file',
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, false);
      expect(result.changed, true);
      expect(result.kind, 'file');
      expect(result.localPath, linkPath);
    });

    test('throws TARGET_UNSUPPORTED_TYPE for socket files', () async {
      mocked.getPathStats = (path) async => socketStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      DotweaveError? thrownError;

      try {
        await trackTarget(
          TrackRequest(
            target: mocked.bashrcPath,
            mode: const TrackModeValue('normal'),
          ),
          mocked.homeDirectory,
          mocked.dependencies,
        );
      } on DotweaveError catch (error) {
        thrownError = error;
      }

      expect(thrownError, isA<DotweaveError>());
      expect(thrownError?.code, 'TARGET_UNSUPPORTED_TYPE');
    });

    test('throws TARGET_OVERLAPS_SYNC_DIR when target overlaps the sync '
        'directory', () async {
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();
      mocked.doPathsOverlap = (leftPath, rightPath) => true;

      DotweaveError? thrownError;

      try {
        await trackTarget(
          TrackRequest(
            target: mocked.bashrcPath,
            mode: const TrackModeValue('normal'),
          ),
          mocked.homeDirectory,
          mocked.dependencies,
        );
      } on DotweaveError catch (error) {
        thrownError = error;
      }

      expect(thrownError, isA<DotweaveError>());
      expect(thrownError?.code, 'TARGET_OVERLAPS_SYNC_DIR');
    });

    test('throws TARGET_OVERLAPS_IDENTITY when target overlaps the identity '
        'file', () async {
      final identityFile = userPath('/home/user/.ssh/id_rsa');
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig(age: const AgeConfig(recipients: ['age1test']));
      mocked.doPathsOverlap = (target, other) {
        if (other == '/tmp/dotweave') {
          return false;
        }
        return target == other;
      };

      DotweaveError? thrownError;

      try {
        await trackTarget(
          TrackRequest(
            target: identityFile,
            mode: const TrackModeValue('normal'),
          ),
          mocked.homeDirectory,
          mocked.dependencies,
        );
      } on DotweaveError catch (error) {
        thrownError = error;
      }

      expect(thrownError, isA<DotweaveError>());
      expect(thrownError?.code, 'TARGET_OVERLAPS_IDENTITY');
    });

    test('assigns normalized profiles during track', () async {
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig(profiles: const ['work', 'personal']);

      final result = await trackTarget(
        TrackRequest(
          target: mocked.bashrcPath,
          mode: const TrackModeValue('normal'),
          profiles: const ['work', 'personal'],
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.profiles, ['work', 'personal']);
    });

    test('clears profiles when profiles is empty string array', () async {
      final localPath = mocked.bashrcPath;
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async => mockSyncConfig(
        entries: [
          mockEntry(
            localPath: localPath,
            repoPath: '.bashrc',
            profiles: const ['work'],
          ),
        ],
      );

      final result = await trackTarget(
        TrackRequest(
          target: localPath,
          mode: const TrackModeValue('normal'),
          profiles: const [''],
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.alreadyTracked, true);
      expect(result.changed, true);
      expect(result.profiles, <String>[]);
    });

    test(
      'updates existing entry repoPath when re-tracking with --repo',
      () async {
        final localPath = mocked.bashrcPath;
        mocked.getPathStats = (path) async => fileStats;
        mocked.readSyncConfig = (syncDirectory, context) async =>
            mockSyncConfig(
              entries: [
                mockEntry(
                  localPath: localPath,
                  repoPath: '.bashrc',
                  configuredRepoPath: const PlatformStringValue(
                    defaultValue: '.bashrc',
                  ),
                ),
              ],
            );

        final result = await trackTarget(
          TrackRequest(
            target: localPath,
            mode: const TrackModeValue('normal'),
            repoPath: const PartialPlatformStringValue(
              defaultValue: 'dotfiles/bashrc',
            ),
          ),
          mocked.homeDirectory,
          mocked.dependencies,
        );

        expect(result.alreadyTracked, true);
        expect(result.changed, true);
        expect(result.repoPath, 'dotfiles/bashrc');
      },
    );

    test('tracks a new entry with repo platform overrides', () async {
      final dirPath = userPath('/home/user/.config/app');
      mocked.getPathStats = (path) async => directoryStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      final result = await trackTarget(
        TrackRequest(
          target: dirPath,
          mode: const PartialPlatformSyncMode(defaultValue: 'normal'),
          repoPath: const PartialPlatformStringValue(
            defaultValue: '.config/app',
            win: 'AppData/Roaming/App',
          ),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(
        result.configuredRepoPath,
        const PlatformStringValue(
          defaultValue: '.config/app',
          win: 'AppData/Roaming/App',
        ),
      );
      expect(result.repoPath, '.config/app');
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(
        document.entries.single.configuredRepoPath,
        const PlatformStringValue(
          defaultValue: '.config/app',
          win: 'AppData/Roaming/App',
        ),
      );
    });

    test('merges repo platform overrides into existing entries', () async {
      final localPath = mocked.bashrcPath;
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async => mockSyncConfig(
        entries: [
          mockEntry(
            localPath: localPath,
            repoPath: '.bashrc',
            configuredRepoPath: const PlatformStringValue(
              defaultValue: '.bashrc',
              mac: 'dotfiles/bashrc',
            ),
          ),
        ],
      );

      final result = await trackTarget(
        TrackRequest(
          target: localPath,
          mode: const PartialPlatformSyncMode(defaultValue: 'normal'),
          repoPath: const PartialPlatformStringValue(win: 'Documents/bashrc'),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.changed, true);
      expect(
        result.configuredRepoPath,
        const PlatformStringValue(
          defaultValue: '.bashrc',
          mac: 'dotfiles/bashrc',
          win: 'Documents/bashrc',
        ),
      );
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(
        document.entries.single.configuredRepoPath,
        const PlatformStringValue(
          defaultValue: '.bashrc',
          mac: 'dotfiles/bashrc',
          win: 'Documents/bashrc',
        ),
      );
    });

    test('tracks a new entry with mode platform overrides', () async {
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      final result = await trackTarget(
        TrackRequest(
          target: mocked.bashrcPath,
          mode: const PartialPlatformSyncMode(
            defaultValue: 'normal',
            win: 'ignore',
          ),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(
        result.configuredMode,
        const PlatformSyncMode(defaultValue: 'normal', win: 'ignore'),
      );
      expect(result.mode, 'normal');
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(
        document.entries.single.configuredMode,
        const PlatformSyncMode(defaultValue: 'normal', win: 'ignore'),
      );
    });

    test('merges mode platform overrides into existing entries', () async {
      final localPath = mocked.bashrcPath;
      mocked.getPathStats = (path) async => fileStats;
      mocked.readSyncConfig = (syncDirectory, context) async => mockSyncConfig(
        entries: [
          mockEntry(
            localPath: localPath,
            repoPath: '.bashrc',
            mode: 'secret',
            configuredMode: const PlatformSyncMode(
              defaultValue: 'secret',
              mac: 'ignore',
            ),
          ),
        ],
      );

      final result = await trackTarget(
        TrackRequest(
          target: localPath,
          mode: const PartialPlatformSyncMode(win: 'ignore'),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(result.changed, true);
      expect(
        result.configuredMode,
        const PlatformSyncMode(
          defaultValue: 'secret',
          mac: 'ignore',
          win: 'ignore',
        ),
      );
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(
        document.entries.single.configuredMode,
        const PlatformSyncMode(
          defaultValue: 'secret',
          mac: 'ignore',
          win: 'ignore',
        ),
      );
    });

    test('tracks a new entry with local platform overrides', () async {
      final dirPath = userPath('/home/user/.config/app');
      mocked.getPathStats = (path) async => directoryStats;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          mockSyncConfig();

      final result = await trackTarget(
        TrackRequest(
          target: dirPath,
          mode: const PartialPlatformSyncMode(defaultValue: 'normal'),
          localPathOverrides: const PartialPlatformStringValue(
            win: '%APPDATA%/App',
          ),
        ),
        mocked.homeDirectory,
        mocked.dependencies,
      );

      expect(
        result.configuredLocalPath,
        const PlatformStringValue(
          defaultValue: '~/.config/app',
          win: '%APPDATA%/App',
        ),
      );
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, '/tmp/dotweave');
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, hasLength(1));
      expect(
        document.entries.single.configuredLocalPath,
        const PlatformStringValue(
          defaultValue: '~/.config/app',
          win: '%APPDATA%/App',
        ),
      );
    });

    test(
      'detects duplicate repo paths using platform-resolved repo overrides',
      () async {
        final dirPath = userPath('/home/user/.config/app');
        mocked.getPathStats = (path) async => directoryStats;
        mocked.readSyncConfig = (syncDirectory, context) async =>
            mockSyncConfig(
              entries: [
                mockEntry(
                  localPath: userPath('/home/user/.config/other'),
                  kind: 'directory',
                  repoPath: '.config/app-linux',
                ),
              ],
            );

        await expectLater(
          trackTarget(
            TrackRequest(
              target: dirPath,
              mode: const PartialPlatformSyncMode(defaultValue: 'normal'),
              repoPath: const PartialPlatformStringValue(
                defaultValue: '.config/app',
                linux: '.config/app-linux',
              ),
            ),
            mocked.homeDirectory,
            mocked.dependencies,
          ),
          throwsA(
            isA<DotweaveError>().having(
              (error) => error.code,
              'code',
              'TARGET_CONFLICT',
            ),
          ),
        );
      },
    );
  });
}
