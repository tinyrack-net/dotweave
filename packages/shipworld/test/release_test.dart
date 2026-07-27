import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/release.dart';
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

final class FakeGitClient implements GitClient {
  FakeGitClient({this.failWhen});

  final bool Function(List<String> arguments)? failWhen;
  final calls = <List<String>>[];

  @override
  Future<String> run(
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    calls.add(List.of(arguments));
    if (failWhen?.call(arguments) == true) {
      throw const ShipworldException('injected git failure');
    }
    return switch (arguments) {
      ['diff', '--cached', '--name-only'] => '',
      ['status', '--porcelain'] => '',
      ['branch', '--show-current'] => 'main',
      ['tag', '--list', _] => '',
      ['ls-remote', ...] => '',
      ['rev-parse', 'HEAD'] => 'abc123',
      ['rev-parse', 'refs/remotes/origin/main'] => 'abc123',
      ['rev-list', '-n', '1', _] => 'abc123',
      _ => '',
    };
  }
}

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('shipworld-release-');
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<ShipworldConfig> createFixture({
    ShipworldTargetKind cliweaveKind = ShipworldTargetKind.pubPackage,
    String cliweaveVersion = '0.1.1',
  }) async {
    for (final entry in {
      'cliweave': cliweaveVersion,
      'dartage': '0.1.1',
    }.entries) {
      final root = p.join(temporary.path, 'packages', entry.key);
      await Directory(root).create(recursive: true);
      await File(
        p.join(root, 'pubspec.yaml'),
      ).writeAsString('name: ${entry.key}\nversion: ${entry.value}\n');
    }
    await File(
      p.join(temporary.path, 'packages', 'cliweave', 'CHANGELOG.md'),
    ).writeAsString(
      '# Changelog\n\n'
      '## ${cliweaveVersion == '1.2.3+41' ? '1.2.4' : '0.1.2'}\n\n'
      '- Patch.\n',
    );
    await File(
      p.join(temporary.path, 'packages', 'dartage', 'CHANGELOG.md'),
    ).writeAsString('# Changelog\n\n## 0.2.0\n\n- Minor.\n');
    final configFile = File(p.join(temporary.path, 'shipworld.yaml'));
    await configFile.writeAsString('''
schema: 1
remote: origin
batch-commit: "release: {targets}"
targets:
  cliweave:
    kind: ${cliweaveKind.yamlName}
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
''');
    return loadShipworldConfig(configFile.path);
  }

  test('plans independent package bumps without writes', () async {
    final config = await createFixture();
    final git = FakeGitClient();
    final result =
        await ReleaseService(
          config: config,
          context: ShipworldContext(git: git),
        ).prepare(
          bumps: {'cliweave': ReleaseType.patch, 'dartage': ReleaseType.minor},
          dryRun: true,
        );

    expect(result.targets.map((target) => '${target.name}:${target.version}'), [
      'cliweave:0.1.2',
      'dartage:0.2.0',
    ]);
    expect(result.commitMessage, 'release: cliweave 0.1.2, dartage 0.2.0');
    expect(git.calls.where((call) => call.first == 'commit'), isEmpty);
  });

  test('increments numeric build metadata only for Flutter targets', () async {
    final config = await createFixture(
      cliweaveKind: ShipworldTargetKind.flutterApplication,
      cliweaveVersion: '1.2.3+41',
    );
    final result = await ReleaseService(
      config: config,
      context: ShipworldContext(git: FakeGitClient()),
    ).prepare(bumps: {'cliweave': ReleaseType.patch}, dryRun: true);

    expect(result.targets.single.version, '1.2.4+42');
    expect(result.targets.single.tag, 'cliweave-v1.2.4');
  });

  test('restores version files when commit fails', () async {
    final config = await createFixture();
    final pubspec = File(
      p.join(temporary.path, 'packages', 'cliweave', 'pubspec.yaml'),
    );
    final original = await pubspec.readAsString();
    final git = FakeGitClient(
      failWhen: (arguments) => arguments.first == 'commit',
    );

    await expectLater(
      ReleaseService(
        config: config,
        context: ShipworldContext(git: git),
      ).prepare(bumps: {'cliweave': ReleaseType.patch}),
      throwsA(isA<ShipworldException>()),
    );

    expect(await pubspec.readAsString(), original);
    expect(
      git.calls.any(
        (call) =>
            call.length > 1 && call[0] == 'restore' && call[1] == '--staged',
      ),
      isTrue,
    );
  });

  test('finalizes signed tags at the same remote HEAD', () async {
    final config = await createFixture();
    for (final entry in const {
      'cliweave': '0.1.1',
      'dartage': '0.1.1',
    }.entries) {
      await File(
        p.join(temporary.path, 'packages', entry.key, 'CHANGELOG.md'),
      ).writeAsString(
        '# Changelog\n\n## ${entry.value}\n\n- Current release.\n',
      );
    }
    final git = FakeGitClient();
    final result = await ReleaseService(
      config: config,
      context: ShipworldContext(git: git),
    ).finalize(targetNames: const ['cliweave', 'dartage'], push: true);

    expect(result.tags, ['cliweave-v0.1.1', 'dartage-v0.1.1']);
    expect(result.head, 'abc123');
    expect(git.calls.last, [
      'push',
      '--atomic',
      'origin',
      'cliweave-v0.1.1',
      'dartage-v0.1.1',
    ]);
  });

  test('removes local tags when later tag creation fails', () async {
    final config = await createFixture();
    for (final entry in const {
      'cliweave': '0.1.1',
      'dartage': '0.1.1',
    }.entries) {
      await File(
        p.join(temporary.path, 'packages', entry.key, 'CHANGELOG.md'),
      ).writeAsString(
        '# Changelog\n\n## ${entry.value}\n\n- Current release.\n',
      );
    }
    final git = FakeGitClient(
      failWhen: (arguments) =>
          arguments.length > 2 &&
          arguments[0] == 'tag' &&
          arguments[1] == '-s' &&
          arguments[2] == 'dartage-v0.1.1',
    );

    await expectLater(
      ReleaseService(
        config: config,
        context: ShipworldContext(git: git),
      ).finalize(targetNames: const ['cliweave', 'dartage']),
      throwsA(isA<ShipworldException>()),
    );

    expect(git.calls, contains(equals(['tag', '-d', 'cliweave-v0.1.1'])));
  });
}
