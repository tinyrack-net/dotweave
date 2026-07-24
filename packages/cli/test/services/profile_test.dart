import 'dart:convert';

import 'package:dotweave/src/config/global_config.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:test/test.dart';

/// Mirror of the vitest `formatGlobalDotweaveConfig` mock:
/// `JSON.stringify(config, null, 2)`.
String jsonStringifyPretty(Map<String, Object?> value) {
  return const JsonEncoder.withIndent('  ').convert(value);
}

/// Stands in for the vitest `vi.hoisted` mock registry: mutable seams with
/// the same default behaviors, plus recorded calls for the spied writers.
class MockedProfileSeams {
  MockedProfileSeams();

  final List<ResolvedSyncConfig> buildSyncConfigDocumentCalls = [];
  final List<GlobalDotweaveConfig> formatGlobalDotweaveConfigCalls = [];
  final List<String> requireGitRepositoryCalls = [];
  final List<(String, String)> writeTextFileAtomicallyCalls = [];
  final List<(String, RawSyncConfig)> writeValidatedSyncConfigCalls = [];

  final RawSyncConfig buildSyncConfigDocumentResult = const RawSyncConfig(
    version: 8,
    profiles: [],
    entries: [],
  );

  Future<GlobalDotweaveConfig?> Function(String filePath)
  readGlobalDotweaveConfig = (filePath) async => null;
  Future<ResolvedSyncConfig> Function(
    String syncDirectory,
    SyncConfigResolutionContext context,
  )
  readSyncConfig = (syncDirectory, context) =>
      throw StateError('readSyncConfig was not mocked');
  ResolvedSyncConfigEntry? Function(
    String target,
    List<ResolvedSyncConfigEntry> entries,
    String cwd,
    String homeDirectory,
  )
  resolveTrackedEntry = (target, entries, cwd, homeDirectory) => null;

  RawSyncConfig buildSyncConfigDocument(ResolvedSyncConfig config) {
    buildSyncConfigDocumentCalls.add(config);
    return buildSyncConfigDocumentResult;
  }

  Future<void> requireGitRepository(String syncDirectory) async {
    requireGitRepositoryCalls.add(syncDirectory);
  }

  String formatGlobalDotweaveConfig(GlobalDotweaveConfig config) {
    formatGlobalDotweaveConfigCalls.add(config);
    return jsonStringifyPretty(config.toJson());
  }

  String normalizeSyncProfileName(String profile) {
    return profile.trim();
  }

  ActiveProfileSelection resolveActiveProfileSelection(
    GlobalDotweaveConfig? config,
  ) {
    final activeProfile = config?.activeProfile;
    return activeProfile == null
        ? const ActiveProfileSelection.none()
        : ActiveProfileSelection.single(activeProfile);
  }

  bool isProfileActive(ActiveProfileSelection selection, String? profile) {
    return selection.mode == 'single' && profile != null
        ? selection.profile == profile
        : false;
  }

  SyncConfigResolutionContext resolveSyncConfigResolutionContext() {
    return SyncConfigResolutionContext(
      homeDirectory: '/tmp/home',
      platformKey: 'linux',
      readEnv: (name) => null,
      xdgConfigHome: '/tmp/home/.config',
    );
  }

  SyncPaths resolveSyncPaths() {
    return const SyncPaths(
      configPath: '/tmp/dotweave/manifest.jsonc',
      homeDirectory: '/tmp/home',
      globalConfigPath: '/tmp/dotweave/global.json',
      syncDirectory: '/tmp/dotweave',
    );
  }

  Future<void> writeTextFileAtomically(
    String targetPath,
    String contents,
  ) async {
    writeTextFileAtomicallyCalls.add((targetPath, contents));
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

  ProfileDependencies get dependencies {
    return ProfileDependencies(
      buildSyncConfigDocument: buildSyncConfigDocument,
      formatGlobalDotweaveConfig: formatGlobalDotweaveConfig,
      isProfileActive: isProfileActive,
      loadWritableSyncConfig: loadWritableSyncConfig,
      normalizeSyncProfileName: normalizeSyncProfileName,
      readGlobalDotweaveConfig: (filePath) =>
          readGlobalDotweaveConfig(filePath),
      readSyncConfig: (syncDirectory, context) =>
          readSyncConfig(syncDirectory, context),
      requireGitRepository: requireGitRepository,
      resolveActiveProfileSelection: resolveActiveProfileSelection,
      resolveSyncConfigResolutionContext: resolveSyncConfigResolutionContext,
      resolveSyncPaths: resolveSyncPaths,
      resolveTrackedEntry: (target, entries, cwd, homeDirectory) =>
          resolveTrackedEntry(target, entries, cwd, homeDirectory),
      writeTextFileAtomically: writeTextFileAtomically,
      writeValidatedSyncConfig: writeValidatedSyncConfig,
    );
  }
}

/// Builds a resolved entry carrying only the fields the TS test literals
/// specify; the remaining required fields use inert defaults.
ResolvedSyncConfigEntry entry({
  String? localPath,
  List<String>? profiles,
  bool? profilesExplicit,
  String? repoPath,
}) {
  return ResolvedSyncConfigEntry(
    configuredLocalPath: const PlatformStringValue(defaultValue: '~/entry'),
    configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
    kind: 'file',
    localPath: localPath ?? '/tmp/home/entry',
    mode: 'normal',
    modeExplicit: false,
    permissionExplicit: false,
    profiles: profiles ?? const [],
    profilesExplicit: profilesExplicit ?? false,
    repoPath: repoPath ?? 'entry',
  );
}

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
  group('sync profiles service', () {
    test('lists sorted profile assignments and the active profile', () async {
      final mocked = MockedProfileSeams();
      mocked.readGlobalDotweaveConfig = (filePath) async =>
          const GlobalDotweaveConfig(activeProfile: 'work', version: 3);
      mocked.readSyncConfig = (syncDirectory, context) async =>
          ResolvedSyncConfig(
            profiles: ['work'],
            entries: [
              entry(
                localPath: '/tmp/home/.zshrc',
                profiles: ['work'],
                profilesExplicit: true,
                repoPath: '.zshrc',
              ),
              entry(
                localPath: '/tmp/home/.bashrc',
                profiles: [],
                profilesExplicit: false,
                repoPath: '.bashrc',
              ),
              entry(
                localPath: '/tmp/home/.gitconfig',
                profiles: ['default', 'work'],
                profilesExplicit: true,
                repoPath: '.gitconfig',
              ),
            ],
            version: 8,
          );

      await expectLater(
        listProfiles(mocked.dependencies),
        completion(
          equals(
            const ProfileListResult(
              activeProfile: 'work',
              activeProfileMode: 'single',
              assignments: [
                ProfileAssignment(
                  entryLocalPath: '/tmp/home/.gitconfig',
                  entryRepoPath: '.gitconfig',
                  profiles: ['default', 'work'],
                ),
                ProfileAssignment(
                  entryLocalPath: '/tmp/home/.zshrc',
                  entryRepoPath: '.zshrc',
                  profiles: ['work'],
                ),
              ],
              availableProfiles: ['default', 'work'],
              globalConfigExists: true,
              globalConfigPath: '/tmp/dotweave/global.json',
            ),
          ),
        ),
      );
      expect(mocked.requireGitRepositoryCalls, ['/tmp/dotweave']);
    });

    test('uses default as the effective active profile when the global config '
        'is absent', () async {
      final mocked = MockedProfileSeams();
      mocked.readGlobalDotweaveConfig = (filePath) async => null;
      mocked.readSyncConfig = (syncDirectory, context) async =>
          ResolvedSyncConfig(
            profiles: [],
            entries: [
              entry(
                localPath: '/tmp/home/.bashrc',
                profiles: [],
                profilesExplicit: false,
                repoPath: '.bashrc',
              ),
            ],
            version: 8,
          );

      final result = await listProfiles(mocked.dependencies);

      expect(result.activeProfile, 'default');
      expect(result.activeProfileMode, 'none');
      expect(result.availableProfiles, ['default']);
      expect(result.globalConfigExists, false);
      expect(result.assignments, isEmpty);
    });

    test('uses default as the effective active profile when activeProfile is '
        'omitted', () async {
      final mocked = MockedProfileSeams();
      mocked.readGlobalDotweaveConfig = (filePath) async =>
          const GlobalDotweaveConfig(version: 3);
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: [], entries: [], version: 8);

      final result = await listProfiles(mocked.dependencies);

      expect(result.activeProfile, 'default');
      expect(result.activeProfileMode, 'none');
      expect(result.globalConfigExists, true);
    });

    test('warns when the active profile is not registered', () async {
      final mocked = MockedProfileSeams();
      mocked.readGlobalDotweaveConfig = (filePath) async =>
          const GlobalDotweaveConfig(activeProfile: 'ghost', version: 3);
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: ['work'], entries: [], version: 8);

      final result = await listProfiles(mocked.dependencies);

      expect(result.activeProfile, 'ghost');
      expect(
        result.activeProfileWarning,
        "Active profile 'ghost' is not registered in manifest.jsonc.",
      );
    });

    test('writes a trimmed active profile without changing case when it '
        'exists', () async {
      final mocked = MockedProfileSeams();
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: ['Work'], entries: [], version: 8);

      await expectLater(
        setActiveProfile(' Work ', mocked.dependencies),
        completion(
          equals(
            const ProfileUpdateResult(
              action: 'use',
              activeProfile: 'Work',
              globalConfigPath: '/tmp/dotweave/global.json',
              profile: 'Work',
            ),
          ),
        ),
      );
      expect(mocked.formatGlobalDotweaveConfigCalls, hasLength(1));
      final formatted = mocked.formatGlobalDotweaveConfigCalls.single;
      expect(formatted.activeProfile, 'Work');
      expect(formatted.version, 3);
      expect(mocked.writeTextFileAtomicallyCalls, [
        (
          '/tmp/dotweave/global.json',
          jsonStringifyPretty({'activeProfile': 'Work', 'version': 3}),
        ),
      ]);
    });

    test('rejects activating an unknown profile', () async {
      final mocked = MockedProfileSeams();
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: [], entries: [], version: 8);

      await expectLater(
        setActiveProfile('work', mocked.dependencies),
        throwsA(
          predicate(
            (error) => error.toString().contains("Unknown profile 'work'."),
          ),
        ),
      );
    });

    test('adds a trimmed profile to the manifest registry without changing '
        'case', () async {
      final mocked = MockedProfileSeams();
      const config = ResolvedSyncConfig(
        profiles: <String>[],
        entries: [],
        version: 8,
      );
      mocked.readSyncConfig = (syncDirectory, context) async => config;

      await expectLater(
        addProfile(' Work ', mocked.dependencies),
        completion(
          equals(
            const ProfileRegistryUpdateResult(action: 'added', profile: 'Work'),
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.age, config.age);
      expect(document.entries, same(config.entries));
      expect(document.repositoryFormat, config.repositoryFormat);
      expect(document.version, config.version);
      expect(document.profiles, ['Work']);
    });

    test('sorts the manifest registry when adding a profile', () async {
      final mocked = MockedProfileSeams();
      const config = ResolvedSyncConfig(
        profiles: ['work'],
        entries: [],
        version: 8,
      );
      mocked.readSyncConfig = (syncDirectory, context) async => config;

      await expectLater(
        addProfile('alpha', mocked.dependencies),
        completion(
          equals(
            const ProfileRegistryUpdateResult(
              action: 'added',
              profile: 'alpha',
            ),
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.age, config.age);
      expect(document.entries, same(config.entries));
      expect(document.repositoryFormat, config.repositoryFormat);
      expect(document.version, config.version);
      expect(document.profiles, ['alpha', 'work']);
    });

    test('rejects duplicate profile additions', () async {
      final mocked = MockedProfileSeams();
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: ['work'], entries: [], version: 8);

      await expectLater(
        addProfile('work', mocked.dependencies),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains("Profile 'work' already exists."),
          ),
        ),
      );
    });

    test('rejects removing the active profile', () async {
      final mocked = MockedProfileSeams();
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: ['work'], entries: [], version: 8);
      mocked.readGlobalDotweaveConfig = (filePath) async =>
          const GlobalDotweaveConfig(activeProfile: 'work', version: 3);

      await expectLater(
        removeProfile('work', mocked.dependencies),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              "Cannot remove active profile 'work'.",
            ),
          ),
        ),
      );
    });

    test('removes an unused profile from the manifest registry', () async {
      final mocked = MockedProfileSeams();
      final trackedEntry = entry(
        profiles: ['personal'],
        profilesExplicit: true,
        repoPath: '.gitconfig',
      );
      final config = ResolvedSyncConfig(
        profiles: const ['work', 'personal'],
        entries: [trackedEntry],
        version: 8,
      );
      mocked.readSyncConfig = (syncDirectory, context) async => config;
      mocked.readGlobalDotweaveConfig = (filePath) async => null;

      await expectLater(
        removeProfile('work', mocked.dependencies),
        completion(
          equals(
            const ProfileRegistryUpdateResult(
              action: 'removed',
              profile: 'work',
            ),
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.age, config.age);
      expect(document.entries, same(config.entries));
      expect(document.repositoryFormat, config.repositoryFormat);
      expect(document.version, config.version);
      expect(document.profiles, ['personal']);
    });

    test('rejects removing a profile that is still referenced by '
        'entries', () async {
      final mocked = MockedProfileSeams();
      final config = ResolvedSyncConfig(
        profiles: const ['work', 'personal'],
        entries: [
          entry(
            profiles: ['work'],
            profilesExplicit: true,
            repoPath: '.config/workapp',
          ),
          entry(
            profiles: ['personal'],
            profilesExplicit: true,
            repoPath: '.gitconfig',
          ),
        ],
        version: 8,
      );
      mocked.readSyncConfig = (syncDirectory, context) async => config;
      mocked.readGlobalDotweaveConfig = (filePath) async => null;

      await expectLater(
        removeProfile('work', mocked.dependencies),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              "Cannot remove profile 'work' because it is still referenced "
              'by 1 sync entry.',
            ),
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, isEmpty);
    });

    test('rejects removing a profile inherited by child entries', () async {
      final mocked = MockedProfileSeams();
      final config = ResolvedSyncConfig(
        profiles: const ['work'],
        entries: [
          entry(
            profiles: ['work'],
            profilesExplicit: false,
            repoPath: '.config/workapp/config.toml',
          ),
        ],
        version: 8,
      );
      mocked.readSyncConfig = (syncDirectory, context) async => config;
      mocked.readGlobalDotweaveConfig = (filePath) async => null;

      await expectLater(
        removeProfile('work', mocked.dependencies),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              "Cannot remove profile 'work' because it is still referenced "
              'by 1 sync entry.',
            ),
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, isEmpty);
    });

    test('validates requested profiles without writing assignments', () async {
      final mocked = MockedProfileSeams();
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: ['Work'], entries: [], version: 8);

      await expectLater(
        validateProfilesExist([' Work '], mocked.dependencies),
        completion(equals(['Work'])),
      );
      expect(mocked.buildSyncConfigDocumentCalls, isEmpty);
      expect(mocked.writeValidatedSyncConfigCalls, isEmpty);
    });

    test('rejects unknown profiles during validation without writing '
        'assignments', () async {
      final mocked = MockedProfileSeams();
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: [], entries: [], version: 8);

      await expectLater(
        validateProfilesExist(['ghost'], mocked.dependencies),
        throwsA(
          predicate(
            (error) => error.toString().contains("Unknown profile 'ghost'."),
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, isEmpty);
      expect(mocked.writeValidatedSyncConfigCalls, isEmpty);
    });

    test('clears the active profile from the global config', () async {
      final mocked = MockedProfileSeams();

      await expectLater(
        clearActiveProfile(mocked.dependencies),
        completion(
          equals(
            const ProfileUpdateResult(
              action: 'clear',
              globalConfigPath: '/tmp/dotweave/global.json',
            ),
          ),
        ),
      );
      expect(mocked.formatGlobalDotweaveConfigCalls, hasLength(1));
      final formatted = mocked.formatGlobalDotweaveConfigCalls.single;
      expect(formatted.activeProfile, isNull);
      expect(formatted.version, 3);
    });

    test('rejects blank assignment targets before touching the '
        'repository', () async {
      final mocked = MockedProfileSeams();

      await expectLater(
        assignProfiles(
          const AssignProfilesRequest(profiles: ['work'], target: '   '),
          '/tmp/cwd',
          mocked.dependencies,
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains('Target path is required.'),
          ),
        ),
      );
      expect(mocked.requireGitRepositoryCalls, isEmpty);
    });

    test('rejects assignments for untracked targets', () async {
      final mocked = MockedProfileSeams();
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(profiles: [], entries: [], version: 8);
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          null;

      await expectLater(
        assignProfiles(
          const AssignProfilesRequest(
            profiles: ['work'],
            target: '~/.gitconfig',
          ),
          '/tmp/cwd',
          mocked.dependencies,
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              'No tracked sync entry matches: ~/.gitconfig',
            ),
          ),
        ),
      );
    });

    test('returns unchanged when the trimmed profiles already match', () async {
      final mocked = MockedProfileSeams();
      final trackedEntry = entry(
        profiles: ['default', 'work'],
        repoPath: '.gitconfig',
      );

      mocked.readSyncConfig = (syncDirectory, context) async =>
          ResolvedSyncConfig(
            profiles: const ['work'],
            entries: [trackedEntry],
            version: 8,
          );
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          trackedEntry;

      await expectLater(
        assignProfiles(
          const AssignProfilesRequest(
            profiles: [' work ', 'default'],
            target: '~/.gitconfig',
          ),
          '/tmp/cwd',
          mocked.dependencies,
        ),
        completion(
          equals(
            const AssignProfilesResult(
              action: 'unchanged',
              entryRepoPath: '.gitconfig',
              profiles: ['work', 'default'],
            ),
          ),
        ),
      );
      expect(mocked.writeValidatedSyncConfigCalls, isEmpty);
    });

    test('updates tracked profiles and marks them explicit when profiles are '
        'supplied', () async {
      final mocked = MockedProfileSeams();
      final trackedEntry = entry(
        profiles: ['default'],
        profilesExplicit: true,
        repoPath: '.gitconfig',
      );
      final config = ResolvedSyncConfig(
        profiles: const ['work'],
        entries: [trackedEntry],
        version: 8,
      );

      mocked.readSyncConfig = (syncDirectory, context) async => config;
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          trackedEntry;

      final result = await assignProfiles(
        const AssignProfilesRequest(profiles: ['work'], target: '~/.gitconfig'),
        '/tmp/cwd',
        mocked.dependencies,
      );

      expect(
        result,
        equals(
          const AssignProfilesResult(
            action: 'assigned',
            entryRepoPath: '.gitconfig',
            profiles: ['work'],
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.age, config.age);
      expect(document.profiles, config.profiles);
      expect(document.repositoryFormat, config.repositoryFormat);
      expect(document.version, config.version);
      expect(document.entries, hasLength(1));
      expectEntryFieldsEqual(
        document.entries.single,
        entry(
          profiles: ['work'],
          profilesExplicit: true,
          repoPath: '.gitconfig',
        ),
      );
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      final written = mocked.writeValidatedSyncConfigCalls.single;
      expect(written.$1, '/tmp/dotweave');
      expect(written.$2, same(mocked.buildSyncConfigDocumentResult));
    });

    test('clears explicit profiles when assigning an empty profile '
        'list', () async {
      final mocked = MockedProfileSeams();
      final trackedEntry = entry(
        profiles: ['work'],
        profilesExplicit: true,
        repoPath: '.gitconfig',
      );
      final config = ResolvedSyncConfig(
        profiles: const ['work'],
        entries: [trackedEntry],
        version: 8,
      );

      mocked.readSyncConfig = (syncDirectory, context) async => config;
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          trackedEntry;

      await assignProfiles(
        const AssignProfilesRequest(profiles: [], target: '~/.gitconfig'),
        '/tmp/cwd',
        mocked.dependencies,
      );

      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.age, config.age);
      expect(document.profiles, config.profiles);
      expect(document.repositoryFormat, config.repositoryFormat);
      expect(document.version, config.version);
      expect(document.entries, hasLength(1));
      expectEntryFieldsEqual(
        document.entries.single,
        entry(profiles: [], profilesExplicit: false, repoPath: '.gitconfig'),
      );
    });
  });
}
