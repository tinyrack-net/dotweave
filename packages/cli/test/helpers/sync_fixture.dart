import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/util/env.dart';
import 'package:dotweave/src/util/path_util.dart';
import 'package:dotweave_age/dotweave_age.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Port of `../test/helpers/sync-fixture.ts` plus the shared suite scaffolding
// from `sync.service.test.ts` (lines 1-110): the vitest `mockEnv` module mock,
// the `detectCurrentPlatformKey` spy, temporary workspace bookkeeping, and the
// symlink-artifact assertion helpers. Shared by the sync service test parts
// and the sync scenarios / dry-run suites.

const String _identityFileName = 'keys.txt';

/// Mirror of the TS `gitTestEnvironment` from `sync-fixture.ts`.
final Map<String, String> gitTestEnvironment = {
  'GIT_AUTHOR_EMAIL': 'test@example.com',
  'GIT_AUTHOR_NAME': 'Test User',
  'GIT_COMMITTER_EMAIL': 'test@example.com',
  'GIT_COMMITTER_NAME': 'Test User',
  'GIT_CONFIG_COUNT': '1',
  'GIT_CONFIG_KEY_0': 'commit.gpgsign',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_VALUE_0': 'false',
  'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
};

/// Mirror of the TS `createTemporaryDirectory` (mkdtemp under tmpdir).
Future<String> createTemporaryDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);

  return directory.path;
}

/// Mirror of the TS `createAgeKeyPair`. Uses the real Dart age
/// implementation: `generateIdentity` is synchronous and
/// `identityToRecipient` is async.
Future<({String identity, String recipient})> createAgeKeyPair() async {
  final identity = generateIdentity();

  return (identity: identity, recipient: await identityToRecipient(identity));
}

/// Mirror of the TS `writeIdentityFile`.
Future<String> writeIdentityFile(String xdgConfigHome, String identity) async {
  final dotweaveHomeDirectory = p.join(
    xdgConfigHome,
    AppConstants.xdg.appDirectoryName,
  );
  final identityFile = p.join(dotweaveHomeDirectory, _identityFileName);

  await Directory(p.dirname(identityFile)).create(recursive: true);
  await File(identityFile).writeAsString('$identity\n');

  return identityFile;
}

/// Mirror of the TS `runGit` (execFile of the real git binary with the
/// isolated [gitTestEnvironment]); throws on a non-zero exit code like
/// `execFileAsync`.
Future<({String stdout, String stderr})> runGit(
  List<String> args, [
  String? cwd,
]) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: cwd,
    runInShell: false,
    environment: {...Platform.environment, ...gitTestEnvironment},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  if (result.exitCode != 0) {
    throw Exception(
      'git ${args.join(' ')} failed with code ${result.exitCode}: '
      '${result.stderr}',
    );
  }

  return (stdout: result.stdout as String, stderr: result.stderr as String);
}

final RegExp _ansiPattern = RegExp('\x1b\\[[0-9;]*m');

/// Mirror of the TS `stripAnsi`.
String stripAnsi(String value) => value.replaceAll(_ansiPattern, '');

/// Mirror of `JSON.stringify(value, null, 2)`.
String jsonStringify(Object? value) {
  return const JsonEncoder.withIndent('  ').convert(value);
}

/// Mirror of the TS `writeJsonFile`.
Future<void> writeJsonFile(String path, Object? value) async {
  await Directory(p.dirname(path)).create(recursive: true);
  await File(path).writeAsString('${jsonStringify(value)}\n');
}

// --- `mock-factories.ts` manifest/settings JSON helpers -------------------

/// Mirror of the TS `readManifestJson` from `mock-factories.ts`.
({List<Object?> entries, List<Object?> profiles, int version}) readManifestJson(
  String text,
) {
  final Object? raw = jsonDecode(text);
  final manifest = raw is Map<String, Object?> ? raw : <String, Object?>{};
  final rawEntries = manifest['entries'];
  final rawProfiles = manifest['profiles'];
  final rawVersion = manifest['version'];

  return (
    entries: rawEntries is List<Object?> ? rawEntries : <Object?>[],
    profiles: rawProfiles is List<Object?> ? rawProfiles : <Object?>[],
    version: rawVersion is int ? rawVersion : 0,
  );
}

/// Mirror of the TS `parseManifestEntries` from `mock-factories.ts`. The TS
/// helper wraps each raw entry in a getter object whose `toEqual` behavior is
/// identical to comparing the raw parsed JSON maps, so the Dart port returns
/// the raw entry maps directly.
List<Map<String, Object?>> parseManifestEntries(String text) {
  return [
    for (final entry in readManifestJson(text).entries)
      entry is Map<String, Object?> ? entry : <String, Object?>{},
  ];
}

/// Mirror of the TS `readSettingsJson` from `mock-factories.ts`.
Map<String, Object?> readSettingsJson(String text) {
  final Object? raw = jsonDecode(text);
  final settings = raw is Map<String, Object?> ? raw : <String, Object?>{};
  final activeProfile = settings['activeProfile'];
  final version = settings['version'];

  return {
    if (activeProfile is String) 'activeProfile': activeProfile,
    if (version is int) 'version': version,
  };
}

// --- `sync.service.test.ts` shared suite scaffolding ----------------------

/// Mirror of the vitest `mockEnv` hoisted object installed via
/// `vi.mock("#app/lib/env.ts")`: an [Env] whose reads resolve dynamically
/// against the mutable fields, so per-test mutations (e.g.
/// `mockEnv.wslDistroName = 'Ubuntu'`) are picked up by later env reads.
class MockSyncEnv extends Env {
  MockSyncEnv() : super(const {}, caseInsensitiveKeys: false);

  String appData = '';
  String home = '';
  String localAppData = '';
  String userProfile = '';
  String xdgConfigHome = '';
  String? wslDistroName;

  @override
  String? operator [](String key) {
    switch (key) {
      case 'APPDATA':
        return appData;
      case 'HOME':
        return home;
      case 'LOCALAPPDATA':
        return localAppData;
      case 'USERPROFILE':
        return userProfile;
      case 'XDG_CONFIG_HOME':
        return xdgConfigHome;
      case 'WSL_DISTRO_NAME':
        return wslDistroName;
      default:
        return null;
    }
  }
}

/// The shared `mockEnv` instance. Tests mutate it through [setEnvironment]
/// (and directly for `WSL_DISTRO_NAME`); [cleanUpSyncFixture] resets it.
final MockSyncEnv mockEnv = MockSyncEnv();

final List<String> _temporaryDirectories = [];

/// Mirror of the suite-local `createWorkspace`: a registered temporary
/// directory removed by [cleanUpSyncFixture].
Future<String> createWorkspace([String prefix = 'dotweave-sync-test-']) async {
  final directory = await createTemporaryDirectory(prefix);

  _temporaryDirectories.add(directory);

  return directory;
}

/// Mirror of the suite-local `setEnvironment`: routes all dotweave env reads
/// to the isolated workspace HOME / XDG config home.
void setEnvironment(String homeDirectory, String xdgConfigHome) {
  mockEnv
    ..appData = xdgConfigHome
    ..home = homeDirectory
    ..localAppData = p.join(homeDirectory, 'AppData', 'Local')
    ..userProfile = homeDirectory
    ..xdgConfigHome = xdgConfigHome;
  testEnvOverride = mockEnv;
}

/// Mirror of
/// `vi.spyOn(platformConfig, "detectCurrentPlatformKey").mockReturnValue(...)`.
/// Cleared by [cleanUpSyncFixture] (the `vi.restoreAllMocks()` equivalent).
void mockCurrentPlatformKey(PlatformKey key) {
  testPlatformKeyOverride = key;
}

Future<void> _removeTemporaryDirectory(String directory) async {
  final target = Directory(directory);

  if (!await target.exists()) {
    return;
  }

  try {
    await target.delete(recursive: true);
  } on FileSystemException {
    if (!Platform.isWindows) {
      rethrow;
    }

    // Git object files are read-only on Windows; clear attributes and retry.
    await Process.run('cmd', [
      '/c',
      'rmdir',
      '/s',
      '/q',
      directory,
    ], runInShell: false);
  }
}

/// Mirror of the suite `afterEach`: restores the env/platform mocks and
/// removes every registered temporary workspace. Call from `tearDown`.
Future<void> cleanUpSyncFixture() async {
  testPlatformKeyOverride = null;
  testEnvOverride = null;
  mockEnv
    ..appData = ''
    ..home = ''
    ..localAppData = ''
    ..userProfile = ''
    ..xdgConfigHome = ''
    ..wslDistroName = null;

  while (_temporaryDirectories.isNotEmpty) {
    final directory = _temporaryDirectories.removeLast();

    await _removeTemporaryDirectory(directory);
  }
}

/// Mirror of the suite-local `symlinkArtifactPath`: symlinks are stored as
/// regular metadata files suffixed with `.dotweave.symlink`, whose contents
/// are the POSIX-normalized link target.
String symlinkArtifactPath(String plainArtifactPath) {
  return '$plainArtifactPath${AppConstants.sync.symlinkArtifactSuffix}';
}

/// Mirror of the suite-local `expectSymlinkArtifact`.
Future<void> expectSymlinkArtifact(
  String plainArtifactPath,
  String target,
) async {
  final metaPath = symlinkArtifactPath(plainArtifactPath);
  final type = FileSystemEntity.typeSync(metaPath, followLinks: false);

  expect(type, FileSystemEntityType.file);
  expect(await File(metaPath).readAsString(), toPosixLinkTarget(target));
}

/// Mirror of `await expect(lstat(path)).rejects.toThrow()`: the path must not
/// exist (not even as a broken symlink).
void expectPathAbsent(String path) {
  expect(
    FileSystemEntity.typeSync(path, followLinks: false),
    FileSystemEntityType.notFound,
  );
}
