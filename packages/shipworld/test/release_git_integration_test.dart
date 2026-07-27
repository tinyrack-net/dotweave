import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/release.dart';
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prepares and pushes multiple verified signed tags in a real repository',
    () async {
      if (Platform.isWindows || !await _available('gpg')) {
        markTestSkipped('requires gpg on a Unix runner');
        return;
      }

      final temporary = await Directory.systemTemp.createTemp(
        'shipworld-git-integration-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final remote = p.join(temporary.path, 'remote.git');
      final work = p.join(temporary.path, 'work');
      final gnupg = p.join(temporary.path, 'gnupg');
      await Directory(gnupg).create();
      await _run('chmod', ['700', gnupg], temporary.path);
      final environment = {...Platform.environment, 'GNUPGHOME': gnupg};
      await _run(
        'gpg',
        [
          '--batch',
          '--passphrase',
          '',
          '--quick-generate-key',
          'Shipworld CI <shipworld@example.invalid>',
          'default',
          'default',
          'never',
        ],
        temporary.path,
        environment: environment,
      );
      final keys = await _run(
        'gpg',
        ['--batch', '--with-colons', '--list-secret-keys'],
        temporary.path,
        environment: environment,
      );
      final fingerprint = keys
          .split('\n')
          .firstWhere((line) => line.startsWith('fpr:'))
          .split(':')[9];

      await _run('git', ['init', '--bare', remote], temporary.path);
      await Directory(work).create();
      await _run('git', ['init', '-b', 'main'], work);
      await _run('git', ['config', 'user.name', 'Shipworld CI'], work);
      await _run('git', [
        'config',
        'user.email',
        'shipworld@example.invalid',
      ], work);
      await _run('git', ['config', 'user.signingkey', fingerprint], work);
      await _run('git', ['remote', 'add', 'origin', remote], work);

      for (final name in const ['cliweave', 'dartage']) {
        final root = p.join(work, 'packages', name);
        await Directory(root).create(recursive: true);
        await File(
          p.join(root, 'pubspec.yaml'),
        ).writeAsString('name: $name\nversion: 0.1.1\n');
        await File(
          p.join(root, 'CHANGELOG.md'),
        ).writeAsString('# Changelog\n\n## 0.1.1\n\n- Initial.\n');
      }
      final configFile = File(p.join(work, 'shipworld.yaml'));
      await configFile.writeAsString(_config);
      await _run('git', ['add', '.'], work);
      await _run('git', ['commit', '-m', 'initial'], work);
      await _run('git', ['push', '-u', 'origin', 'main'], work);

      await File(
        p.join(work, 'packages', 'cliweave', 'CHANGELOG.md'),
      ).writeAsString('# Changelog\n\n## 0.1.2\n\n- Patch.\n');
      await File(
        p.join(work, 'packages', 'dartage', 'CHANGELOG.md'),
      ).writeAsString('# Changelog\n\n## 0.2.0\n\n- Minor.\n');
      final config = await loadShipworldConfig(configFile.path);
      final service = ReleaseService(
        config: config,
        context: ShipworldContext(
          git: IoGitClient(environment: environment),
          environment: environment,
        ),
      );
      await service.prepare(
        bumps: {'cliweave': ReleaseType.patch, 'dartage': ReleaseType.minor},
      );
      await _run(
        'git',
        ['push', 'origin', 'main'],
        work,
        environment: environment,
      );
      final finalized = await service.finalize(
        targetNames: const ['cliweave', 'dartage'],
        push: true,
      );

      expect(finalized.tags, ['cliweave-v0.1.2', 'dartage-v0.2.0']);
      final refs = await _run('git', [
        '--git-dir',
        remote,
        'show-ref',
        '--tags',
      ], temporary.path);
      expect(refs, contains('refs/tags/cliweave-v0.1.2'));
      expect(refs, contains('refs/tags/dartage-v0.2.0'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<bool> _available(String executable) async {
  try {
    return (await Process.run(executable, const ['--version'])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<String> _run(
  String executable,
  List<String> arguments,
  String workingDirectory, {
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
  return (result.stdout as String).trim();
}

const _config = '''
schema: 1
remote: origin
batch-commit: "release: {targets}"
targets:
  cliweave:
    kind: pub-package
    root: packages/cliweave
    version:
      source: pubspec.yaml
    changelog: CHANGELOG.md
    tag: "cliweave-v{version}"
    commit: "release: cliweave {version}"
    branch: main
  dartage:
    kind: pub-package
    root: packages/dartage
    version:
      source: pubspec.yaml
    changelog: CHANGELOG.md
    tag: "dartage-v{version}"
    commit: "release: dartage {version}"
    branch: main
''';
