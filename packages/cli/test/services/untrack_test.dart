import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/services/repo_artifacts.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/services/untrack.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Stands in for the vitest `vi.hoisted` mock registry used by
/// `untrack.test.ts`: mutable seams with the same default behaviors, plus
/// recorded calls for the spied config-file writers and git seam.
class MockedUntrackSeams {
  MockedUntrackSeams();

  int requireGitRepositoryCalls = 0;
  final List<ResolvedSyncConfig> buildSyncConfigDocumentCalls = [];
  final List<RawSyncConfig> buildSyncConfigDocumentResults = [];
  final List<(String, RawSyncConfig)> writeValidatedSyncConfigCalls = [];

  Future<void> Function(String syncDirectory) requireGitRepository =
      (syncDirectory) async {};
  Future<ResolvedSyncConfig> Function(
    String syncDirectory,
    SyncConfigResolutionContext context,
  )
  readSyncConfig = (syncDirectory, context) =>
      throw StateError('readSyncConfig was not mocked');
  SyncPaths Function() resolveSyncPaths = () =>
      throw StateError('resolveSyncPaths was not mocked');
  ResolvedSyncConfigEntry? Function(
    String target,
    List<ResolvedSyncConfigEntry> entries,
    String cwd,
    String homeDirectory,
  )
  resolveTrackedEntry = (target, entries, cwd, homeDirectory) => null;

  SyncConfigResolutionContext resolveSyncConfigResolutionContext() {
    return SyncConfigResolutionContext(
      homeDirectory: '/tmp/home',
      platformKey: 'linux',
      readEnv: (name) => null,
      xdgConfigHome: '/tmp/home/.config',
    );
  }

  /// Mirrors the vitest mock `(config) => ({ document: config })`: records the
  /// input and returns a fresh sentinel document per call so the write seam
  /// can be asserted against the exact returned instance.
  RawSyncConfig buildSyncConfigDocument(ResolvedSyncConfig config) {
    buildSyncConfigDocumentCalls.add(config);
    final document = RawSyncConfig(
      version: config.version,
      profiles: const [],
      entries: const [],
    );
    buildSyncConfigDocumentResults.add(document);
    return document;
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
    requireGitRepositoryCalls += 1;
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

  UntrackDependencies get dependencies {
    return UntrackDependencies(
      buildSyncConfigDocument: buildSyncConfigDocument,
      loadWritableSyncConfig: loadWritableSyncConfig,
      resolveTrackedEntry: (target, entries, cwd, homeDirectory) =>
          resolveTrackedEntry(target, entries, cwd, homeDirectory),
      writeValidatedSyncConfig: writeValidatedSyncConfig,
    );
  }
}

ResolvedSyncConfigEntry createEntry({
  required String kind,
  required String localPath,
  required List<String> profiles,
  required String repoPath,
}) {
  return ResolvedSyncConfigEntry(
    configuredLocalPath: PlatformStringValue(defaultValue: '~/$repoPath'),
    configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
    kind: kind,
    localPath: localPath,
    mode: 'normal',
    modeExplicit: false,
    permissionExplicit: false,
    profiles: profiles,
    profilesExplicit: false,
    repoPath: repoPath,
  );
}

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createWorkspace() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-untrack-',
    );

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  Future<void> writeArtifactFile(
    String path, [
    String contents = 'value\n',
  ]) async {
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsString(contents);
  }

  String artifactPathFor(
    String workspace, {
    required String category,
    required String profile,
    required String repoPath,
  }) {
    return p.joinAll([
      workspace,
      ...resolveArtifactRelativePath(
        category: category,
        profile: profile,
        repoPath: repoPath,
      ).split('/'),
    ]);
  }

  SyncPaths syncPathsFor(String workspace) {
    return SyncPaths(
      configPath: p.join(workspace, 'manifest.jsonc'),
      globalConfigPath: '/tmp/home/.config/dotweave/settings.jsonc',
      homeDirectory: '/tmp/home',
      syncDirectory: workspace,
    );
  }

  tearDown(() async {
    while (temporaryDirectories.isNotEmpty) {
      final directory = temporaryDirectories.removeLast();

      if (await Directory(directory).exists()) {
        await Directory(directory).delete(recursive: true);
      }
    }
  });

  group('untrack service', () {
    test('rejects blank targets without touching the repository', () async {
      final mocked = MockedUntrackSeams();

      await expectLater(
        untrackTarget(
          const UntrackRequest(target: '   '),
          '/tmp/cwd',
          mocked.dependencies,
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains('Target path is required.'),
          ),
        ),
      );
      expect(mocked.requireGitRepositoryCalls, 0);
    });

    test('rejects targets that are not currently tracked', () async {
      final mocked = MockedUntrackSeams();
      final workspace = await createWorkspace();

      mocked.resolveSyncPaths = () => syncPathsFor(workspace);
      mocked.requireGitRepository = (syncDirectory) async {};
      mocked.readSyncConfig = (syncDirectory, context) async =>
          const ResolvedSyncConfig(entries: [], version: 7);
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          null;

      await expectLater(
        untrackTarget(
          const UntrackRequest(target: '~/.gitconfig'),
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

    test('removes tracked file artifacts across namespaces and prunes empty '
        'parents', () async {
      final mocked = MockedUntrackSeams();
      final workspace = await createWorkspace();
      final entry = createEntry(
        kind: 'file',
        localPath: '/tmp/home/.config/tool/token.txt',
        profiles: ['work'],
        repoPath: '.config/tool/token.txt',
      );
      final siblingEntry = createEntry(
        kind: 'file',
        localPath: '/tmp/home/.gitconfig',
        profiles: [],
        repoPath: '.gitconfig',
      );
      final defaultPlainPath = artifactPathFor(
        workspace,
        category: 'plain',
        profile: 'default',
        repoPath: entry.repoPath,
      );
      final workPlainPath = artifactPathFor(
        workspace,
        category: 'plain',
        profile: 'work',
        repoPath: entry.repoPath,
      );
      final defaultSecretPath = artifactPathFor(
        workspace,
        category: 'secret',
        profile: 'default',
        repoPath: entry.repoPath,
      );
      final workSecretPath = artifactPathFor(
        workspace,
        category: 'secret',
        profile: 'work',
        repoPath: entry.repoPath,
      );

      await writeArtifactFile(defaultPlainPath);
      await writeArtifactFile(workPlainPath);
      await writeArtifactFile(defaultSecretPath, 'secret-default\n');
      await writeArtifactFile(workSecretPath, 'secret-work\n');

      mocked.resolveSyncPaths = () => syncPathsFor(workspace);
      mocked.requireGitRepository = (syncDirectory) async {};
      mocked.readSyncConfig = (syncDirectory, context) async =>
          ResolvedSyncConfig(entries: [entry, siblingEntry], version: 7);
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          entry;

      final result = await untrackTarget(
        const UntrackRequest(target: '~/.config/tool/token.txt'),
        '/tmp/cwd',
        mocked.dependencies,
      );

      expect(
        result,
        equals(
          UntrackResult(
            localPath: entry.localPath,
            plainArtifactCount: 2,
            repoPath: entry.repoPath,
            secretArtifactCount: 2,
          ),
        ),
      );
      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, equals([siblingEntry]));
      expect(document.entries.single, same(siblingEntry));
      expect(document.version, 7);
      expect(mocked.writeValidatedSyncConfigCalls, hasLength(1));
      expect(mocked.writeValidatedSyncConfigCalls.single.$1, workspace);
      expect(
        mocked.writeValidatedSyncConfigCalls.single.$2,
        same(mocked.buildSyncConfigDocumentResults.single),
      );
      expect(await pathExists(defaultPlainPath), isFalse);
      expect(await pathExists(workPlainPath), isFalse);
      expect(await pathExists(defaultSecretPath), isFalse);
      expect(await pathExists(workSecretPath), isFalse);
    });

    test('counts and removes directory artifacts while leaving unrelated '
        'siblings intact', () async {
      final mocked = MockedUntrackSeams();
      final workspace = await createWorkspace();
      final entry = createEntry(
        kind: 'directory',
        localPath: '/tmp/home/.config/app',
        profiles: ['work'],
        repoPath: '.config/app',
      );
      final plainRoot = artifactPathFor(
        workspace,
        category: 'plain',
        profile: 'default',
        repoPath: entry.repoPath,
      );
      final siblingPath = p.join(workspace, 'default', '.config', 'keep.txt');

      await Directory(p.join(plainRoot, 'nested')).create(recursive: true);
      await File(p.join(plainRoot, 'settings.json')).writeAsString('{}\n');
      await File(
        p.join(plainRoot, 'nested', 'value.txt'),
      ).writeAsString('hello\n');
      await writeArtifactFile(siblingPath, 'keep\n');

      mocked.resolveSyncPaths = () => syncPathsFor(workspace);
      mocked.requireGitRepository = (syncDirectory) async {};
      mocked.readSyncConfig = (syncDirectory, context) async =>
          ResolvedSyncConfig(entries: [entry], version: 7);
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          entry;

      final result = await untrackTarget(
        const UntrackRequest(target: '~/.config/app'),
        '/tmp/cwd',
        mocked.dependencies,
      );

      expect(
        result,
        equals(
          UntrackResult(
            localPath: entry.localPath,
            plainArtifactCount: 4,
            repoPath: entry.repoPath,
            secretArtifactCount: 0,
          ),
        ),
      );
      expect(await pathExists(plainRoot), isFalse);
      expect(await pathExists(siblingPath), isTrue);
    });

    test(
      'removes secret artifacts for file entries with secret mode',
      () async {
        final mocked = MockedUntrackSeams();
        final workspace = await createWorkspace();
        final entry = createEntry(
          kind: 'file',
          localPath: '/tmp/home/.env',
          profiles: [],
          repoPath: '.env',
        );
        final defaultSecretPath = artifactPathFor(
          workspace,
          category: 'secret',
          profile: 'default',
          repoPath: entry.repoPath,
        );

        await writeArtifactFile(defaultSecretPath, 'secret-key=value\n');

        mocked.resolveSyncPaths = () => syncPathsFor(workspace);
        mocked.requireGitRepository = (syncDirectory) async {};
        mocked.readSyncConfig = (syncDirectory, context) async =>
            ResolvedSyncConfig(entries: [entry], version: 7);
        mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
            entry;

        final result = await untrackTarget(
          const UntrackRequest(target: '~/.env'),
          '/tmp/cwd',
          mocked.dependencies,
        );

        expect(result.secretArtifactCount, greaterThan(0));
        expect(await pathExists(defaultSecretPath), isFalse);
      },
    );

    test('handles untracking the last entry in the config', () async {
      final mocked = MockedUntrackSeams();
      final workspace = await createWorkspace();
      final entry = createEntry(
        kind: 'file',
        localPath: '/tmp/home/.gitconfig',
        profiles: [],
        repoPath: '.gitconfig',
      );

      mocked.resolveSyncPaths = () => syncPathsFor(workspace);
      mocked.requireGitRepository = (syncDirectory) async {};
      mocked.readSyncConfig = (syncDirectory, context) async =>
          ResolvedSyncConfig(entries: [entry], version: 7);
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          entry;

      await untrackTarget(
        const UntrackRequest(target: '~/.gitconfig'),
        '/tmp/cwd',
        mocked.dependencies,
      );

      expect(mocked.buildSyncConfigDocumentCalls, hasLength(1));
      final document = mocked.buildSyncConfigDocumentCalls.single;
      expect(document.entries, isEmpty);
      expect(document.version, 7);
    });

    test(
      'counts artifacts correctly for entries with multiple profiles',
      () async {
        final mocked = MockedUntrackSeams();
        final workspace = await createWorkspace();
        final entry = createEntry(
          kind: 'file',
          localPath: '/tmp/home/.gitconfig',
          profiles: ['work', 'personal'],
          repoPath: '.gitconfig',
        );
        final defaultPlainPath = artifactPathFor(
          workspace,
          category: 'plain',
          profile: 'default',
          repoPath: entry.repoPath,
        );
        final workPlainPath = artifactPathFor(
          workspace,
          category: 'plain',
          profile: 'work',
          repoPath: entry.repoPath,
        );
        final personalPlainPath = artifactPathFor(
          workspace,
          category: 'plain',
          profile: 'personal',
          repoPath: entry.repoPath,
        );

        await writeArtifactFile(defaultPlainPath);
        await writeArtifactFile(workPlainPath);
        await writeArtifactFile(personalPlainPath);

        mocked.resolveSyncPaths = () => syncPathsFor(workspace);
        mocked.requireGitRepository = (syncDirectory) async {};
        mocked.readSyncConfig = (syncDirectory, context) async =>
            ResolvedSyncConfig(entries: [entry], version: 7);
        mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
            entry;

        final result = await untrackTarget(
          const UntrackRequest(target: '~/.gitconfig'),
          '/tmp/cwd',
          mocked.dependencies,
        );

        expect(result.plainArtifactCount, 3);
      },
    );

    test('prunes deeply nested empty parent directories after artifact '
        'removal', () async {
      final mocked = MockedUntrackSeams();
      final workspace = await createWorkspace();
      final entry = createEntry(
        kind: 'file',
        localPath: '/tmp/home/.config/deep/nested/path/file.txt',
        profiles: ['work'],
        repoPath: '.config/deep/nested/path/file.txt',
      );
      final artifactPath = artifactPathFor(
        workspace,
        category: 'plain',
        profile: 'work',
        repoPath: entry.repoPath,
      );

      await writeArtifactFile(artifactPath);

      mocked.resolveSyncPaths = () => syncPathsFor(workspace);
      mocked.requireGitRepository = (syncDirectory) async {};
      mocked.readSyncConfig = (syncDirectory, context) async =>
          ResolvedSyncConfig(entries: [entry], version: 7);
      mocked.resolveTrackedEntry = (target, entries, cwd, homeDirectory) =>
          entry;

      await untrackTarget(
        const UntrackRequest(target: '~/.config/deep/nested/path/file.txt'),
        '/tmp/cwd',
        mocked.dependencies,
      );

      expect(await pathExists(artifactPath), isFalse);
      expect(await pathExists(p.dirname(artifactPath)), isFalse);
      expect(
        await pathExists(p.dirname(p.dirname(p.dirname(artifactPath)))),
        isFalse,
      );
    });
  });
}
